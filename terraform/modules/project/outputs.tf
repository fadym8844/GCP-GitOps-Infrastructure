output "project_id" {
  value = google_project.this.project_id
}

output "project_number" {
  value       = google_project.this.number
  description = "Needed for IAM member strings and service agent identities."
}
 