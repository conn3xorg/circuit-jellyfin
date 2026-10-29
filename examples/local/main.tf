variable "port" {
  type    = number
  default = 2222
}

variable "admin_password" {
  type      = string
  default   = "correct-horse-battery"
  ephemeral = true
}

module "jellyfin" {
  source = "../.."

  hosts                = { box = "127.0.0.1" }
  ssh_port             = var.port
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"

  # up.sh creates these, owned by a media group, as a NAS share would be.
  media_dirs   = ["/srv/media/movies", "/srv/media/music"]
  extra_groups = ["media"]

  port                  = 8097
  hardware_acceleration = true

  admin_username = "admin"
  admin_password = var.admin_password
}
