variable "project_id" { type = string }
variable "region" {
  type    = string
  default = "me-central2"
}
variable "cluster_name" {
  type    = string
  default = "core-platform-prod"
}

variable "network_self_link" { type = string }
variable "node_subnet_self_link" { type = string }
variable "pods_range_name" {
  type    = string
  default = "pods"
}
variable "services_range_name" {
  type    = string
  default = "services"
} 
variable "master_cidr" {
  type    = string
  default = "172.16.10.0/28"
}

variable "main_machine_type" {
  type        = string
  default     = "n2-standard-8"
  description = "8 vCPU / 32GB. Source OCI shape is 4 OCPU/16GB per node - N2 chosen over E2 for consistent (non-burstable) performance given this is a production financial workload with RabbitMQ and portfolio-service's known throttling history."
}

variable "main_min_nodes" {
  type    = number
  default = 3
}

variable "main_max_nodes" {
  type    = number
  default = 6
}

variable "create_stateful_pool" {
  type        = bool
  default     = false
  description = "Optional dedicated, tainted pool for RabbitMQ/MongoDB/Redis. Consider given RabbitMQ's documented bootstrap deadlock history - not required."
}

variable "stateful_machine_type" {
  type    = string
  default = "n2-standard-4"
}

# ---------------------------------------------------------------------------
# Fixed-size main pool. No autoscaler — matches OCI, where node count is
# changed deliberately and never by a controller.
# NOTE: node_count is PER ZONE. Total nodes = main_node_count * len(main_node_zones)
# ---------------------------------------------------------------------------
variable "main_node_count" {
  description = "Nodes PER ZONE in the main pool. Manual scaling only."
  type        = number
  default     = 2
}

variable "main_node_zones" {
  description = "Zones the main pool is pinned to. Length x main_node_count = total nodes."
  type        = list(string)
  default     = ["me-central2-a", "me-central2-b"]
}
