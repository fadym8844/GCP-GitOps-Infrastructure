variable "project_id" { type = string }

variable "pool_id" {
  type    = string
  default = "github-pool"
}

variable "github_owner" {
  type        = string
  description = "GitHub org — e.g. madkol. Used in attribute_condition."
}

variable "allowed_repositories" {
  type        = list(string)
  description = "Repos allowed to impersonate the CI SA, as owner/repo."
}

variable "ci_service_account_id" {
  type    = string
  default = "github-actions-ci"
}
 
variable "ci_roles" {
  type = list(string)
  default = [
    "roles/artifactregistry.writer",
    "roles/secretmanager.secretAccessor",
  ]
  description = "Least privilege. Deliberately excludes GKE access — ArgoCD pulls from git."
}
