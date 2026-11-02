variable "hosts" {
  type        = any
  description = "Hosts to configure: a map of names to addresses, or to host objects with an address and optional host_key, user, port, private_key_file, jump_hosts or os."

  validation {
    condition     = alltrue([for h in var.hosts : contains(["debian", "ubuntu", "rocky", "almalinux", "rhel", "centos", "fedora"], try(h.os, "debian"))])
    error_message = "A host object's os must be one of debian, ubuntu, rocky, almalinux, rhel, centos or fedora."
  }
}

variable "ssh_user" {
  type        = string
  default     = "root"
  description = "User to log in as."
}

variable "ssh_port" {
  type        = number
  default     = 22
  description = "SSH port."
}

variable "ssh_private_key_file" {
  type        = string
  default     = null
  description = "Path to a private key. When null, Conn3x uses the SSH agent."
}

variable "ssh_known_hosts_file" {
  type        = string
  default     = null
  description = "known_hosts file to check host keys against. When null, ~/.ssh/known_hosts."
}

variable "ssh_become" {
  type        = bool
  default     = false
  description = "Run commands as root through sudo."
}

variable "jellyfin_version" {
  type        = string
  default     = "12.4"
  description = "Jellyfin release to run, such as \"12.4\". On Debian and Ubuntu it pins the jellyfin-server and jellyfin-web packages; on Rocky Linux and Fedora, the tag of the docker.io/jellyfin/jellyfin image."

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+(\\.[0-9]+)?$", var.jellyfin_version))
    error_message = "jellyfin_version must be a release number, such as \"12.4\"."
  }
}

variable "media_dirs" {
  type        = list(string)
  default     = []
  description = "Directories holding your media, such as [\"/srv/media/movies\"]. The circuit checks the jellyfin user can read each one and never changes them. On Rocky Linux and Fedora each is mounted read-only into the container at the same path."

  validation {
    condition     = alltrue([for d in var.media_dirs : can(regex("^/[^\\s:,'\"\\\\]*$", d))])
    error_message = "Each of media_dirs must be an absolute path without spaces, colons, commas, quotes or backslashes."
  }
}

variable "port" {
  type        = number
  default     = 8096
  description = "HTTP port Jellyfin listens on, on every address."

  validation {
    condition     = var.port >= 1 && var.port <= 65535 && floor(var.port) == var.port
    error_message = "port must be a port number from 1 to 65535."
  }

  # Jellyfin falls back to 8096 when the HTTP port is its HTTPS port.
  validation {
    condition     = var.port != 8920
    error_message = "port can't be 8920, which Jellyfin keeps for HTTPS."
  }
}

variable "data_dir" {
  type        = string
  default     = "/var/lib/jellyfin"
  description = "Directory for Jellyfin's database, metadata and plugins. On Rocky Linux and Fedora it also holds Jellyfin's configuration and logs, which Debian and Ubuntu keep in /etc/jellyfin and /var/log/jellyfin."

  validation {
    condition     = can(regex("^/[A-Za-z0-9._/-]+$", var.data_dir)) && var.data_dir != "/"
    error_message = "data_dir must be an absolute path of letters, digits, ., _, - and /, other than /."
  }
}

variable "cache_dir" {
  type        = string
  default     = "/var/cache/jellyfin"
  description = "Directory for Jellyfin's cache: transcodes, images and the like. It can grow large."

  validation {
    condition     = can(regex("^/[A-Za-z0-9._/-]+$", var.cache_dir)) && var.cache_dir != "/"
    error_message = "cache_dir must be an absolute path of letters, digits, ., _, - and /, other than /."
  }
}

variable "hardware_acceleration" {
  type        = bool
  default     = false
  description = "Let Jellyfin use the host's GPU for transcoding: adds the jellyfin user to the render and video groups and, in the container, passes /dev/dri through when the host has it. Pick the method in Jellyfin's dashboard afterwards."
}

variable "extra_groups" {
  type        = list(string)
  default     = []
  description = "More groups for the jellyfin user, such as [\"media\"], so it can read media owned by that group. The groups must exist. The circuit only adds groups, never removes one."

  validation {
    condition     = alltrue([for g in var.extra_groups : can(regex("^[a-z_][a-z0-9_-]*$", g))])
    error_message = "Each of extra_groups must be a group name, such as \"media\"."
  }
}

variable "admin_username" {
  type        = string
  default     = null
  description = "Name of the administrator to create in place of Jellyfin's setup wizard. When null, the wizard waits for whoever opens Jellyfin first."

  validation {
    condition     = var.admin_username == null || can(regex("^[A-Za-z0-9._@-]+$", coalesce(var.admin_username, "-")))
    error_message = "admin_username may use letters, digits, ., _, @ and -."
  }
}

variable "admin_password" {
  type        = string
  default     = null
  ephemeral   = true
  sensitive   = true
  description = "Password for admin_username. It reaches the host in a root-only file and never the plan or state."

  validation {
    condition     = var.admin_username == null || (var.admin_password != null && length(coalesce(var.admin_password, "")) >= 8 && !can(regex("[\"\\\\[:cntrl:]]", coalesce(var.admin_password, ""))))
    error_message = "With admin_username set, admin_password must be at least 8 characters, with no quotes, backslashes or control characters."
  }
}

variable "image_digest" {
  type        = string
  default     = "sha256:fea863d0cd9ec445985d9c75fc6ed64e38a1d2766cf0c250a33d553f4fc1b771"
  description = "Digest of the image for jellyfin_version, on hosts that run the image. Podman pulls by the digest, so change it with the version."

  validation {
    condition     = can(regex("^sha256:[a-f0-9]{64}$", var.image_digest))
    error_message = "image_digest must be a digest, such as \"sha256:45ed...\"."
  }
}
