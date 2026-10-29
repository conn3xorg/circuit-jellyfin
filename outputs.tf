output "url" {
  description = "Where Jellyfin answers on each host, such as http://203.0.113.10:8096."
  value       = { for name, h in var.hosts : name => "http://${try(h.address, h)}:${var.port}" }
}

output "service" {
  description = "The systemd service that runs Jellyfin on each host."
  value       = "jellyfin.service"
}
