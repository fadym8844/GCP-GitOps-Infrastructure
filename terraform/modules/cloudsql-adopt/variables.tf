variable "dr_db_project_id" {
  type        = string
  description = "Project ID of core-platform-dr-db. Must be exact — confirm via gcloud, don't guess."
}

variable "instance_name" {
  type        = string
  description = "Name of the existing Cloud SQL instance inside core-platform-dr-db that's replicating from OCI."
}

variable "gke_service_accounts" {
  type        = set(string)
  default     = []
  description = "Full emails of GKE Workload Identity service accounts that need roles/cloudsql.client."
}
 