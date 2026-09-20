variable "project_id" {
  type        = string
  description = "Globally unique project ID."
}

variable "display_name" {
  type        = string
  description = "Human-readable project name."
}

variable "billing_account" {
  type        = string
  description = "Billing account ID (from CNTXT)."
}

variable "org_id" { 
  type        = string
  default     = null
  description = "Organisation ID. Ignored when folder_id is set."
}

variable "folder_id" {
  type        = string
  default     = null
  description = "Parent folder ID. Takes precedence over org_id."
}

variable "activate_apis" {
  type        = list(string)
  default     = []
  description = "APIs to enable on this project."
}

variable "shared_vpc_host" {
  type        = bool
  default     = false
  description = "Make this project a Shared VPC host."
}

variable "shared_vpc_host_project" {
  type        = string
  default     = null
  description = "Attach this project as a service project to the named host."
}

variable "labels" {
  type    = map(string)
  default = {}
}
