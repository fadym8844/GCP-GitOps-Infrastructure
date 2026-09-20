variable "project_id" {
  type        = string
  description = "core-platform-database-dr-prod - confirmed."
}

variable "instance_name" {
  type    = string
  default = "core-platform-mysql-prod"
}

variable "region" {
  type        = string
  default     = "me-central2"
  description = "Dammam, confirmed - not me-central1 (Doha), which is where the existing DR instance lives. This module always creates its own instance in Dammam regardless of that one."
}

variable "tier" { 
  type        = string
  default     = "db-custom-2-13312"
  description = "2 vCPU / 13GB - confirmed spec, matches the existing Doha instance exactly."
}

variable "disk_size_gb" {
  type    = number
  default = 300
}

variable "network_id" {
  type        = string
  description = "Self-link of the Shared VPC - from modules.network.network_id in envs/prod."
}
