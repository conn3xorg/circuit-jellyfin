# Local example

Applies circuit-jellyfin to a throwaway Rocky Linux 10 container with systemd. You need Conn3x and Podman.

On Rocky Linux, Jellyfin runs under Podman inside that container, so the host container is privileged, which is simplest with rootful Podman. On a Mac, use the Podman machine's root connection. On Linux, use `sudo podman`:

```sh
export CONTAINER_CONNECTION=podman-machine-default-root   # macOS
export PODMAN="sudo podman"                               # Linux
./up.sh
conn3x init
conn3x apply
conn3x plan
```

The first apply takes a few minutes: it installs Podman and pulls Jellyfin's image. The second plan says `No changes.`

`up.sh` also makes two media directories, `/srv/media/movies` and `/srv/media/music`, readable only by a `media` group, the way a NAS share often is. The example adds the jellyfin user to that group with `extra_groups`, and the circuit checks it can read them. It moves Jellyfin to port 8097 and creates an administrator, `admin`, with the password `correct-horse-battery`, which you'd never keep on a real host. To ask the new server something:

```sh
ssh -p 2222 -i id_ed25519 -o UserKnownHostsFile=known_hosts root@127.0.0.1 \
  curl -s http://127.0.0.1:8097/System/Info/Public
```

`StartupWizardCompleted` is `true`: nobody else can claim the server through the wizard.

`up.sh` listens on `127.0.0.1:2222`. Set `PORT` to use another port, and pass the same port to Conn3x with `-var port=PORT`. Set `CONTAINERFILE` to test another distro, such as one of the images in Conn3x's `test/images`, which CI uses. On Debian and Ubuntu, Jellyfin installs from its apt repository instead, and no Podman is involved.

`./down.sh` removes the container, its volumes, the key and the state.
