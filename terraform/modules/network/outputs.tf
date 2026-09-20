output "network_id" { value = google_compute_network.this.id }
output "network_name" { value = google_compute_network.this.name }
output "network_self_link" { value = google_compute_network.this.self_link }

output "nodes_subnet_id" { value = google_compute_subnetwork.nodes.id }
output "nodes_subnet_name" { value = google_compute_subnetwork.nodes.name }

output "pods_range_name" { value = "pods" }
output "services_range_name" { value = "services" }

output "nat_egress_ips" {
  value       = google_compute_address.nat[*].address
  description = "SEND THESE TO PARTNERS. Replaces OCI 144.24.209.5."
}
 