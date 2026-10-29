# circuit-jellyfin

A Conn3x circuit that runs [Jellyfin](https://jellyfin.org), the free media server, on a box that already holds your films, shows and music. You point it at your media directories, and you get a server your TVs, phones and browsers can stream from, without a setup wizard left open for whoever finds port 8096 first.

It installs Jellyfin the way the Jellyfin team supports on each distribution. Debian and Ubuntu get Jellyfin's own apt repository, with its signing key pinned in this circuit. Rocky Linux and Fedora have no package from the Jellyfin team, so they run Jellyfin's official image under Podman as a systemd service. On both, Jellyfin runs as a `jellyfin` user that reads your media and never changes it: the circuit doesn't chown, chmod or relabel anything you point it at. Give it an administrator name and password and it finishes the first-run wizard for you.

It fits next to [circuit-samba](https://github.com/conn3xorg/circuit-samba) or [circuit-nfs](https://github.com/conn3xorg/circuit-nfs) on a home NAS: they share the files, Jellyfin plays them.

## Usage

```hcl
variable "jellyfin_admin_password" {
  type      = string
  ephemeral = true
}

module "jellyfin" {
  source = "github.com/conn3xorg/circuit-jellyfin?ref=v0.1.0"

  hosts                = { nas = "192.168.1.20" }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  media_dirs   = ["/srv/media/movies", "/srv/media/shows", "/srv/media/music"]
  extra_groups = ["media"]

  hardware_acceleration = true

  admin_username = "james"
  admin_password = var.jellyfin_admin_password
}
```

Then run `conn3x init` and `TF_VAR_jellyfin_admin_password=... conn3x apply`. A second `conn3x plan` says `No changes.` Open `http://192.168.1.20:8096`, sign in, and add your libraries from the directories in `media_dirs`.

Jellyfin listens on every address. The circuit doesn't open a firewall port: on a host with firewalld or ufw, open `port` yourself, for example with [circuit-firewall](https://github.com/conn3xorg/circuit-firewall). Debian and Ubuntu cloud images usually have no firewall turned on, so check what yours has before you expose the server.

For hosts created in the same plan, pass host objects with the host key you generated, so Conn3x checks it without a known_hosts entry. Give each one's distribution in `os` too: the circuit picks between the apt repository and Podman by distribution, and Conn3x can't ask a host that doesn't exist yet. If `os` turns out not to match the host, Conn3x stops before configuring it. Set `os` as well when you put `depends_on` on this module: `depends_on` holds back reading the hosts until the apply, so without `os` the plan fails with `Invalid for_each argument`.

```hcl
hosts = {
  for name, d in digitalocean_droplet.media : name => {
    address  = d.ipv4_address
    host_key = tls_private_key.host[name].public_key_openssh
    os       = "ubuntu"
  }
}
```

To try it on a throwaway container first, see [examples/local](examples/local).

### Reading your media

Jellyfin needs to read every file in `media_dirs` as the `jellyfin` user. If the files are world-readable, there's nothing to do. If they belong to a group, such as `media` on a NAS share, put that group in `extra_groups` and the circuit adds the `jellyfin` user to it. Before Jellyfin restarts, the circuit checks that the `jellyfin` user can open each directory, and stops with a message if it can't, so you find out now and not from an empty library.

On Rocky Linux and Fedora, each directory is mounted into the container read-only, at the same path, so the paths you type into Jellyfin are the ones on the host. Jellyfin can't write artwork or `.nfo` files next to your media there; it keeps them in `data_dir`.

### The administrator and the setup wizard

Until someone finishes Jellyfin's setup wizard, anyone who can reach the port can finish it and become the administrator. Set `admin_username` and `admin_password` and the circuit closes that gap as soon as Jellyfin first answers: it creates the administrator through the same API calls the wizard makes (`/Startup/User`, then `/Startup/Complete`) and leaves the wizard done. `admin_password` is ephemeral and sensitive: it reaches the host in a root-only file, `/etc/conn3x/jellyfin/admin-password`, and never the plan or state. It reaches `curl` on stdin, so it doesn't show in `ps`.

Jellyfin only allows this while the wizard is open, so the circuit does it once. Changing `admin_password` afterwards does nothing to Jellyfin; change it in Jellyfin's dashboard. On a server whose wizard someone already finished, setting the two inputs does nothing either.

Leave `admin_username` null and the wizard is yours to finish in the browser. Do it before you open the port to anyone else. The wizard's language and metadata settings are left at Jellyfin's defaults when the circuit finishes it; change them under Dashboard, General.

### Hardware transcoding

`hardware_acceleration = true` adds the `jellyfin` user to the `render` and `video` groups, where the host has them, and on Rocky Linux and Fedora passes `/dev/dri` into the container when it exists. That covers Intel and AMD GPUs through VA-API or QSV. Then choose the method under Dashboard, Playback, Transcoding. NVIDIA cards need NVIDIA's driver and container toolkit, which this circuit doesn't install.

## What it does

On Debian and Ubuntu, in order:

1. Adds Jellyfin's apt repository, `https://repo.jellyfin.org/debian` or `/ubuntu`, suite set to the release's codename, with the Jellyfin Team's signing key from `files/jellyfin.asc`. The key, fingerprint `4918 AABC 486C A052 358D 778D 4902 3CD0 1DE2 1A7B`, has no expiry date.
2. Installs `jellyfin-server` and `jellyfin-web` at `jellyfin_version`, then the `jellyfin` package at the same version, which pulls in the `jellyfin-ffmpeg` that release wants. A higher version upgrades in place. The package creates the `jellyfin` user and starts Jellyfin.
3. Creates `data_dir` and `cache_dir`, owned by `jellyfin`, mode `0750`, and points the package's service at them with `/etc/default/jellyfin-conn3x` and a drop-in, `/etc/systemd/system/jellyfin.service.d/conn3x.conf`. The package's own `/etc/default/jellyfin` stays as it shipped. Settings stay in `/etc/jellyfin` and logs in `/var/log/jellyfin`.
4. Adds the `jellyfin` user to `extra_groups`, and to `render` and `video` with `hardware_acceleration`.
5. Sets `port` in `/etc/jellyfin/network.xml`, with Jellyfin stopped, since it reads the file only at start.
6. Starts Jellyfin now and at boot.

On Rocky Linux and Fedora, in order:

1. Creates a `jellyfin` system user, then `data_dir` and `cache_dir`, owned by it, mode `0750`.
2. Adds the user to `extra_groups`, and to `render` and `video` with `hardware_acceleration`.
3. Writes a Quadlet drop-in, `/etc/containers/systemd/jellyfin.container.d/50-conn3x-user.conf`, so the container runs as that user's UID with its groups. The numbers differ between hosts, so the circuit reads them with `id` on the host.
4. Sets `port` in `data_dir/config/network.xml`, or creates the file with only the port before the first start. Jellyfin fills in its defaults.
5. Through [circuit-podman](https://github.com/conn3xorg/circuit-podman), installs Podman and runs `docker.io/jellyfin/jellyfin:<jellyfin_version>` as `jellyfin.service`: `data_dir` at `/config`, `cache_dir` at `/cache`, each of `media_dirs` read-only at its own path, on the host's network. Quadlet services start at boot.

Then on every host:

1. Installs `curl`, and checks the `jellyfin` user can read each of `media_dirs`.
2. Restarts Jellyfin when its version, directories, groups or port changed, and waits up to three minutes for `/health` to answer `Healthy`.
3. With `admin_username` set, creates the administrator and finishes the wizard, as above.

The container runs on the host's network, so Jellyfin listens on the host's own port and sees clients' real addresses, and firewalld or ufw treat the port like any other service's.

The container runs with SELinux labelling off (`SecurityLabelDisable=true`), so it can read media in place without the circuit relabelling it. The rest of SELinux stays on. On a Rocky Linux 10 droplet with SELinux enforcing, the audit log had no denials.

Before the circuit runs, the `conn3x_host` data source reads each host's distribution and release over SSH, which picks the install route and the apt suite.

### Why not RPM Fusion on Fedora

[Jellyfin's Linux install page](https://jellyfin.org/docs/general/installation/linux) supports its own repository for Debian and Ubuntu and recommends containers for every other distribution. RPM Fusion packages Jellyfin for Fedora, but it's a community package the Jellyfin team doesn't support, and it trails the official releases. The official image is the same Jellyfin on Rocky Linux, AlmaLinux and Fedora.

### What it doesn't do

- It doesn't create libraries. Add them in the dashboard from `media_dirs`; Jellyfin's API for that needs an administrator's token, and libraries are the part you'll want to name and tune yourself.
- It doesn't set up HTTPS. Put a proxy in front, such as [circuit-caddy](https://github.com/conn3xorg/circuit-caddy), and keep Jellyfin's port to the LAN.
- It doesn't open firewall ports, install GPU drivers, or mount network shares.
- It doesn't move data. Changing `data_dir` or `cache_dir` on a server that already ran points Jellyfin at the new, empty directories. On Rocky Linux and Fedora that's a new, empty server; on Debian and Ubuntu, Jellyfin refuses to start, because `/etc/jellyfin` says it was set up before. Stop Jellyfin and move the contents first.
- It doesn't downgrade, and on Debian and Ubuntu it doesn't hold the packages: `apt upgrade` can move them past `jellyfin_version`, and the next plan then shows the difference. The image tag on Rocky Linux and Fedora doesn't move.
- Deleting the module leaves Jellyfin installed, or its container running, with your data.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `hosts` | any | Required | Hosts to configure, by name. Each value is an address, such as `"192.168.1.20"`, or a host object such as `{ address = "192.168.1.20", host_key = "ssh-ed25519 AAAA..." }`. A host object can also set `user`, `port`, `private_key_file`, `jump_hosts` and `os`, the distribution's ID, such as `ubuntu` or `rocky`, which a host created in the same plan needs. The two forms can be mixed. |
| `ssh_user` | string | `"root"` | User to log in as. |
| `ssh_port` | number | `22` | SSH port. |
| `ssh_private_key_file` | string | `null` | Path to a private key. When null, Conn3x uses the SSH agent. |
| `ssh_known_hosts_file` | string | `null` | known_hosts file to check host keys against. When null, `~/.ssh/known_hosts`. Not used for a host object with `host_key`. |
| `ssh_become` | bool | `false` | Run commands as root through sudo. Set it when `ssh_user` isn't root. |
| `jellyfin_version` | string | `"12.4"` | Jellyfin release. On Debian and Ubuntu it pins `jellyfin-server` and `jellyfin-web`; on Rocky Linux and Fedora it's the image tag. Raising it upgrades in place. |
| `media_dirs` | list(string) | `[]` | Directories holding your media, such as `["/srv/media/movies"]`. Checked for read access, never changed. Absolute paths without spaces, colons, commas, quotes or backslashes. |
| `port` | number | `8096` | HTTP port Jellyfin listens on, on every address. Not `8920`, which Jellyfin keeps for HTTPS. |
| `data_dir` | string | `"/var/lib/jellyfin"` | Jellyfin's database, metadata and plugins. On Rocky Linux and Fedora, also its settings and logs. |
| `cache_dir` | string | `"/var/cache/jellyfin"` | Jellyfin's cache, including transcodes. It can grow large. |
| `hardware_acceleration` | bool | `false` | Add the `jellyfin` user to `render` and `video`, and pass `/dev/dri` into the container. |
| `extra_groups` | list(string) | `[]` | More groups for the `jellyfin` user, such as `["media"]`. They must exist. Groups are only ever added. |
| `admin_username` | string | `null` | Administrator to create in place of the setup wizard. When null, the wizard waits in the browser. |
| `admin_password` | string | `null` | Password for `admin_username`. Ephemeral and sensitive: pass it with `-var` or `TF_VAR_`. At least 8 characters, with no quotes, backslashes or control characters. Used once, on the first run. |

## Outputs

| Name | Description |
| --- | --- |
| `url` | Where Jellyfin answers on each host, such as `{ nas = "http://192.168.1.20:8096" }`. |
| `service` | The systemd service that runs Jellyfin, `jellyfin.service`. |

## Requirements

Requires Conn3x v0.6.5 or later and systemd on each host, with a package mirror the host can reach. Debian and Ubuntu hosts need to reach `repo.jellyfin.org`, and Jellyfin's repository has suites for Debian 12 and 13 and Ubuntu 22.04, 24.04 and 26.04, on amd64, arm64 and armhf. Rocky Linux, AlmaLinux and Fedora hosts need Podman 5 or later, which the circuit installs from the distribution, and to reach Docker Hub; the image is amd64 and arm64. Jellyfin wants local storage for `data_dir` and `cache_dir`, not a network share.

## Tested on

Rocky Linux 10, Fedora 45, Ubuntu 24.04 and Debian 13. CI applies [examples/local](examples/local) to each on amd64 and checks that the second plan has no changes, that `/health` answers `Healthy`, that `/System/Info/Public` shows the wizard finished, that the administrator can sign in and a wrong password can't, and that all of it holds after Jellyfin restarts, with a plan that still has no changes.

By hand, in containers: a custom `data_dir`, `cache_dir` and `port` on a fresh Debian 13 host, and the same change on an existing Rocky Linux 10 host, which came up as a new server with the administrator created again.

On an Ubuntu 24.04 droplet and a Rocky Linux 10 droplet with SELinux enforcing, both with a `/dev/dri` device, the same checks passed with `hardware_acceleration` and a media directory readable only by a `media` group. On Rocky Linux the container ran as the host's `jellyfin` UID with the `video`, `render` and `media` groups, saw `/dev/dri`, and the audit log had no denials. Both came back after a reboot with the checks passing and no changes in the plan. Transcoding on the GPU itself wasn't tried.

## License

MPL-2.0. See [LICENSE](LICENSE). Jellyfin itself is GPL-2.0.
