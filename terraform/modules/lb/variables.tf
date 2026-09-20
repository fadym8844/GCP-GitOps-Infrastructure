variable "project_id" {
  type        = string
  description = "Workload project - same one GKE and Traefik live in."
}

variable "region" {
  type    = string
  default = "me-central2"
}
 