variable "project_id" { type = string }
variable "network_name" { type = string }
variable "env" { type = string }

variable "region" { 
  type    = string
  default = "me-central2"
}

variable "node_cidr" {
  type        = string
  description = "Primary subnet range for GKE nodes."
}

variable "pod_cidr" {
  type        = string
  description = "Secondary range for pods. Use /14 — GKE pre-allocates a /24 per node."
}

variable "service_cidr" {
  type        = string
  description = "Secondary range for ClusterIP services."
}

variable "master_cidr" {
  type        = string
  default     = null
  description = "GKE control plane /28. Needed for the webhook firewall rule."
}

variable "proxy_only_cidr" {
  type        = string
  default     = null
  description = "Proxy-only subnet for a regional external ALB. Null to skip."
}

variable "psa_cidr" {
  type        = string
  default     = null
  description = "Private Service Access range for Cloud SQL private IP."
}

variable "nat_ip_count" {
  type        = number
  default     = 1
  description = "Static egress IPs to reserve. 1 is sufficient for this scale — provides 64,512 simultaneous connections. Submit this single IP to all partners for whitelisting."
}
