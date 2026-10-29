# Facts give each host's distribution and release. Debian and Ubuntu get
# Jellyfin's own apt repository, which needs the release's codename. Jellyfin
# publishes no packages for the Red Hat family, so Rocky Linux and Fedora run
# its official image under Podman.
data "conn3x_host" "facts" {
  for_each = var.hosts

  ssh {
    host             = try(each.value.address, each.value)
    host_key         = try(each.value.host_key, null)
    user             = try(each.value.user, var.ssh_user)
    port             = try(each.value.port, var.ssh_port)
    private_key_file = try(each.value.private_key_file, var.ssh_private_key_file)
    jump_hosts       = try(each.value.jump_hosts, null)
    known_hosts_file = var.ssh_known_hosts_file
  }

  lifecycle {
    postcondition {
      condition     = try(each.value.os, self.os_id) == self.os_id
      error_message = "Host ${each.key} is ${self.os_id}, not the ${try(each.value.os, "")} its os says."
    }
  }
}

locals {
  # A host object's os stands in for the facts of a host created in the
  # same plan, which can't be read until it exists.
  os              = { for name, h in var.hosts : name => try(h.os, data.conn3x_host.facts[name].os_id) }
  debian          = { for name, o in local.os : name => contains(["debian", "ubuntu"], o) }
  deb_hosts       = { for name, h in var.hosts : name => h if local.debian[name] }
  container_hosts = { for name, h in var.hosts : name => h if !local.debian[name] }

  codename = { "22.04" = "jammy", "24.04" = "noble", "26.04" = "resolute", "12" = "bookworm", "13" = "trixie" }

  # Jellyfin's apt versions carry the release they were built for, such as
  # 12.4+ubu2404 or 12.4+deb13, and apt wants the whole thing.
  package_version = {
    for name, f in data.conn3x_host.facts : name =>
    f.os_id == "ubuntu" ? "${var.jellyfin_version}+ubu${replace(f.os_version, ".", "")}" : "${var.jellyfin_version}+deb${f.os_version}"
  }

  # The packages keep Jellyfin's settings in /etc/jellyfin. The image keeps
  # them in /config/config, which is data_dir on the host.
  config_dir = { for name in keys(var.hosts) : name => local.debian[name] ? "/etc/jellyfin" : "${var.data_dir}/config" }

  groups = distinct(concat(var.hardware_acceleration ? ["render", "video"] : [], var.extra_groups))

  # The groups the jellyfin user should be in. render and video are skipped
  # on a host without them, which has no GPU to share; a missing group from
  # extra_groups is an error.
  groups_wanted = join(" ", concat(
    [for g in(var.hardware_acceleration ? ["render", "video"] : []) : "! getent group ${g} >/dev/null || echo ${g};"],
    [for g in var.extra_groups : "getent group ${g} >/dev/null && echo ${g} || { echo 'Group ${g} does not exist on this host. Create it, or take it out of extra_groups.' >&2; exit 1; };"],
  ))

  # usermod -a keeps the groups the user has.
  groups_command = "w=$(${local.groups_wanted}) || exit 1; for g in $w; do usermod -aG \"$g\" jellyfin; done"
  groups_unless  = "w=$(${local.groups_wanted}) || exit 1; for g in $w; do id -nG jellyfin | tr ' ' '\\n' | grep -qx \"$g\" || exit 1; done"

  # Jellyfin keeps its port in network.xml, which it writes itself on its
  # first start and reads only at start. So the port is set in place with
  # Jellyfin stopped, and a host that hasn't started it yet gets a file
  # with only the port, which Jellyfin fills in with its defaults.
  port_command = { for name in keys(var.hosts) : name => <<-EOT
    set -e
    f=${local.config_dir[name]}/network.xml
    systemctl stop jellyfin 2>/dev/null || true
    if [ -f "$f" ]; then
      grep -q '<InternalHttpPort>' "$f" || { echo "$f has no InternalHttpPort to set." >&2; exit 1; }
      sed -i 's|<InternalHttpPort>[0-9]*</InternalHttpPort>|<InternalHttpPort>${var.port}</InternalHttpPort>|' "$f"
    else
      [ -d ${local.config_dir[name]} ] || install -d -o jellyfin -g jellyfin -m 0750 ${local.config_dir[name]}
      printf '<?xml version="1.0" encoding="utf-8"?>\n<NetworkConfiguration xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">\n  <InternalHttpPort>${var.port}</InternalHttpPort>\n</NetworkConfiguration>\n' > "$f"
      chown jellyfin:jellyfin "$f"
    fi
  EOT
  }
  port_unless = { for name in keys(var.hosts) : name => "grep -q '<InternalHttpPort>${var.port}</InternalHttpPort>' ${local.config_dir[name]}/network.xml" }

  # The container runs as the host's jellyfin user, with its groups, so it
  # reads media and the GPU as that user would. Quadlet wants numbers for
  # those, and they differ from host to host, so a drop-in is written on the
  # host from what id says.
  user_dropin = "/etc/containers/systemd/jellyfin.container.d/50-conn3x-user.conf"
  user_lines  = "g=$(id -g jellyfin); printf '# Written by Conn3x. Changes here are overwritten on the next apply.\\n[Container]\\nUser=%s:%s\\n' \"$(id -u jellyfin)\" \"$g\"; for x in $(id -G jellyfin); do [ \"$x\" = \"$g\" ] || echo \"GroupAdd=$x\"; done"

  url = "http://127.0.0.1:${var.port}"

  password_file = "/etc/conn3x/jellyfin/admin-password"
}

# Debian and Ubuntu: Jellyfin's apt repository and packages.
circuit "native" {
  hosts = local.deb_hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  # One suite per release, at repo.jellyfin.org/debian or /ubuntu. The key
  # has no expiry date.
  step "repo" {
    repository {
      name   = "jellyfin"
      url    = "https://repo.jellyfin.org/${local.os[each.key]}"
      key    = file("${path.module}/files/jellyfin.asc")
      suites = [local.codename[data.conn3x_host.facts[each.key].os_version]]
    }
  }

  # The server and web interface are pinned first. The jellyfin package
  # after them depends on neither version, but pulls in the jellyfin-ffmpeg
  # this release wants.
  step "server" {
    package {
      name    = "jellyfin-server"
      version = local.package_version[each.key]
    }
  }

  step "web" {
    package {
      name    = "jellyfin-web"
      version = local.package_version[each.key]
    }
  }

  step "jellyfin" {
    package {
      name    = "jellyfin"
      version = local.package_version[each.key]
    }
  }

  step "data_dir" {
    directory {
      path  = var.data_dir
      owner = "jellyfin"
      group = "jellyfin"
      mode  = "0750"
    }
  }

  step "cache_dir" {
    directory {
      path  = var.cache_dir
      owner = "jellyfin"
      group = "jellyfin"
      mode  = "0750"
    }
  }

  # The package's unit reads its directories from /etc/default/jellyfin.
  # A second EnvironmentFile overrides the variables in the first, and
  # leaves the package's file alone for upgrades.
  step "env" {
    file {
      path    = "/etc/default/jellyfin-conn3x"
      content = "# Written by Conn3x. Changes here are overwritten on the next apply.\nJELLYFIN_DATA_DIR=${var.data_dir}\nJELLYFIN_CACHE_DIR=${var.cache_dir}\n"
    }
  }

  step "dropin" {
    file {
      path    = "/etc/systemd/system/jellyfin.service.d/conn3x.conf"
      content = "# Written by Conn3x. Changes here are overwritten on the next apply.\n[Service]\nEnvironmentFile=/etc/default/jellyfin-conn3x\nWorkingDirectory=${var.data_dir}\n"
    }
  }

  step "groups" {
    for_each = toset(length(local.groups) > 0 ? ["all"] : [])
    command {
      command = local.groups_command
      unless  = local.groups_unless
    }
  }

  step "port" {
    command {
      command = local.port_command[each.key]
      unless  = local.port_unless[each.key]
    }
  }

  step "running" {
    service {
      name    = "jellyfin"
      state   = "started"
      enabled = true
    }
  }
}

# Rocky Linux and Fedora: a jellyfin user and its directories for the
# container, which runs as that user.
circuit "container" {
  hosts = local.container_hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  step "user" {
    user {
      name   = "jellyfin"
      system = true
      home   = var.data_dir
      shell  = "/sbin/nologin"
    }
  }

  step "data_dir" {
    directory {
      path  = var.data_dir
      owner = "jellyfin"
      group = "jellyfin"
      mode  = "0750"
    }
  }

  step "cache_dir" {
    directory {
      path  = var.cache_dir
      owner = "jellyfin"
      group = "jellyfin"
      mode  = "0750"
    }
  }

  step "groups" {
    for_each = toset(length(local.groups) > 0 ? ["all"] : [])
    command {
      command = local.groups_command
      unless  = local.groups_unless
    }
  }

  # The check runs at plan time, before the groups step above adds any, so
  # a change there makes the apply look again.
  step "user_dropin" {
    command {
      command  = "mkdir -p ${dirname(local.user_dropin)} && { ${local.user_lines}; } > ${local.user_dropin}.new && mv ${local.user_dropin}.new ${local.user_dropin}"
      unless   = "[ \"$({ ${local.user_lines}; })\" = \"$(cat ${local.user_dropin} 2>/dev/null)\" ]"
      triggers = { groups = join(",", local.groups) }
    }
  }

  step "port" {
    command {
      command = local.port_command[each.key]
      unless  = local.port_unless[each.key]
    }
  }
}

# Jellyfin's official image as a Quadlet unit, on the host's network so the
# port is the host's and firewalld sees it like any other service. Media is
# mounted read-only at the same path, so library paths read the same inside
# and out. SELinux labels are left off for the container rather than
# relabelling your media.
module "podman" {
  source = "github.com/conn3xorg/circuit-podman?ref=v0.1.0"

  depends_on = [conn3x_command.container__user_dropin, conn3x_command.container__port]

  hosts                = local.container_hosts
  ssh_user             = var.ssh_user
  ssh_port             = var.ssh_port
  ssh_private_key_file = var.ssh_private_key_file
  ssh_known_hosts_file = var.ssh_known_hosts_file
  ssh_become           = var.ssh_become

  containers = {
    jellyfin = {
      image   = "docker.io/jellyfin/jellyfin:${var.jellyfin_version}"
      volumes = concat(["${var.data_dir}:/config", "${var.cache_dir}:/cache"], [for d in var.media_dirs : "${d}:${d}:ro"])
      # The image's health check asks port 8096 unless told otherwise.
      environment = { HEALTHCHECK_URL = "http://localhost:${var.port}/health" }
      extra = concat(
        ["Network=host", "SecurityLabelDisable=true"],
        var.hardware_acceleration ? ["AddDevice=-/dev/dri"] : [],
      )
    }
  }
}

circuit "jellyfin" {
  hosts = var.hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  # The checks below and the admin step talk to Jellyfin with curl.
  step "curl" {
    depends_on = [conn3x_service.native__running, module.podman]
    package {
      name = "curl"
    }
  }

  # Fails the apply when the jellyfin user can't open a media directory,
  # which otherwise shows up later as an empty library.
  step "media" {
    for_each = toset(var.media_dirs)
    command {
      command = "setpriv --reuid=jellyfin --regid=jellyfin --init-groups test -r '${item.value}' -a -x '${item.value}' || { echo 'The jellyfin user cannot read ${item.value}. Give it read access, for example through a group in extra_groups.' >&2; exit 1; }"
      unless  = "setpriv --reuid=jellyfin --regid=jellyfin --init-groups test -r '${item.value}' -a -x '${item.value}'"
    }
  }

  # Jellyfin reads its directories, groups and port only at start.
  step "restart" {
    command {
      command = "systemctl daemon-reload && systemctl restart jellyfin"
      triggers = {
        package = try(conn3x_package.native__server[each.key].revision, null)
        env     = try(conn3x_file.native__env[each.key].revision, null)
        dropin  = try(conn3x_file.native__dropin[each.key].revision, null)
        groups  = try(conn3x_command.native__groups["${each.key}/all"].revision, conn3x_command.container__groups["${each.key}/all"].revision, null)
        user    = try(conn3x_command.container__user_dropin[each.key].revision, null)
        port    = try(conn3x_command.native__port[each.key].revision, conn3x_command.container__port[each.key].revision)
      }
    }
  }

  # A first start sets up the database before Jellyfin answers.
  step "ready" {
    command {
      command  = "for _ in $(seq 90); do [ \"$(curl -s ${local.url}/health)\" = Healthy ] && exit 0; sleep 2; done; echo 'Jellyfin did not answer on ${local.url}/health within three minutes. See journalctl -u jellyfin.' >&2; exit 1"
      triggers = { restart = conn3x_command.jellyfin__restart[each.key].revision }
    }
  }
}

# Creates the administrator through the API the setup wizard uses, then
# marks the wizard done. Jellyfin only allows that while the wizard is open,
# so this runs once; after that, change the password in Jellyfin.
circuit "admin" {
  hosts = var.admin_username == null ? {} : var.hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  step "dir" {
    depends_on = [conn3x_command.jellyfin__ready]
    directory {
      path = dirname(local.password_file)
      mode = "0700"
    }
  }

  # The password lands in a root-only file, never in state or the plan.
  step "password" {
    file {
      path       = local.password_file
      content_wo = var.admin_password
    }
  }

  # GET /Startup/User makes Jellyfin create its first user, which the POST
  # then names and gives the password. The password reaches curl on stdin,
  # so it never shows in ps.
  step "wizard" {
    command {
      command = <<-EOT
        set -e
        curl -sf -o /dev/null ${local.url}/Startup/User
        printf '{"Name":"%s","Password":"%s"}' '${var.admin_username}' "$(cat ${local.password_file})" | curl -sf -o /dev/null -H 'Content-Type: application/json' --data-binary @- ${local.url}/Startup/User
        curl -sf -o /dev/null -X POST ${local.url}/Startup/Complete
      EOT
      unless  = "grep -q '<IsStartupWizardCompleted>true</IsStartupWizardCompleted>' ${local.config_dir[each.key]}/system.xml"
    }
  }
}
