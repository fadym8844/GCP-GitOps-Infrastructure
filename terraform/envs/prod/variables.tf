variable "region" {
  type        = string
  default     = "me-central2"
  description = "Dammam. Required for NCA data residency."
}

variable "org_id" {
  type    = string
  default = null 
}

variable "folder_id" {
  type        = string
  default     = null
  description = "Parent folder. Takes precedence over org_id."
}

variable "billing_account" {
  type        = string
  description = "Billing account ID from CNTXT."
}

variable "network_project_id" {
  type    = string
  default = "network-prod"
}

variable "workload_project_id" {
  type    = string
  default = "workload-prod"
}

variable "db_project_id" {
  type        = string
  default     = "database-dr-prod"
  description = "Fresh project for the production database - confirmed decision, not adopting the existing Doha-based dr-db."
}

variable "github_owner" {
  type    = string
  default = ""
}

variable "allowed_repositories" {
  type        = list(string)
  description = "Repos permitted to impersonate the CI service account."
  default = [
    "Infrastructure",
  ]
}
