output "traefik_lb_ip" {
  value       = google_compute_address.traefik.address
  description = "The static IP for Traefik's LoadBalancer service. Point DNS here at cutover."
}

output "security_policy_id" {
  value = google_compute_security_policy.default.id
}
 