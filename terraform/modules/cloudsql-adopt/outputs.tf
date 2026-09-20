output "connection_name" {
  value       = data.google_sql_database_instance.prod.connection_name
  description = "Used by the Cloud SQL Auth Proxy / connector, if used."
}

output "private_ip_address" {
  value       = data.google_sql_database_instance.prod.private_ip_address
  description = "Private IP inside the VPC, via Private Service Access. Empty until PSA is confirmed/attached."
}

output "self_link" {
  value = data.google_sql_database_instance.prod.self_link
}
 