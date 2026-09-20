output "workload_identity_provider" {
  value       = google_iam_workload_identity_pool_provider.github.name
  description = "Pass to google-github-actions/auth as workload_identity_provider."
}

output "ci_service_account_email" {
  value       = google_service_account.ci.email
  description = "Pass to google-github-actions/auth as service_account."
}
 