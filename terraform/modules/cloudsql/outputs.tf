output "connection_name" {
  value = google_sql_database_instance.prod.connection_name
}

output "private_ip_address" {
  value = google_sql_database_instance.prod.private_ip_address
}

output "instance_name" {
  value = google_sql_database_instance.prod.name
}
 