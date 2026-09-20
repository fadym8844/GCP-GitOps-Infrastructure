##############################################################################
# modules/gke
#
# Sized from real, confirmed data, not a guess:
#   - Source shape: VM.Standard.E3.Flex, 4 OCPU / 16GB per node, 4 nodes,
#     single AD (Jeddah AD-1). Total capacity: 16 OCPU / 64GB.
#   - Actual current requests: 26 services at 200m/200Mi, portfolio-service
#     at 1200m request / 2 CPU limit (its own documented CPU-throttling
#     history), RabbitMQ at 3 CPU / 12Gi total across 3 pods - the single
#     heaviest workload in the cluster - MongoDB at 1.5 CPU / 3Gi total.
#   - Aggregate explicit requests: ~13 vCPU / 23GB, comfortably inside
#     today's 4-node capacity.
#
# Two decisions made here worth flagging rather than assuming silently:
#   1. REGIONAL cluster (control-plane HA across zones) - a real improvement
#      over the OCI source, which has zero AD redundancy today. Costs more
#      than zonal; if that's not wanted, this is the one line to change.
#   2. A dedicated, tainted node pool for stateful workloads (RabbitMQ,
#      MongoDB, Redis) - optional, off by default, given RabbitMQ's known
#      two-node bootstrap deadlock history. Worth considering given how
#      heavy it is relative to everything else, but not required.
##############################################################################

terraform {
  required_version = ">= 1.6"
  required_providers {
    google = { 
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

resource "google_container_cluster" "primary" {
  project  = var.project_id
  name     = var.cluster_name
  location = var.region # regional - see note above

  remove_default_node_pool = true
  initial_node_count       = 1

  network    = var.network_self_link
  subnetwork = var.node_subnet_self_link

  networking_mode = "VPC_NATIVE"
  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  private_cluster_config {
    enable_private_nodes = true
    # Not fully locking the control-plane endpoint to in-VPC only - matches
    # today's pattern of reaching the cluster via VPN/Twingate rather than
    # requiring a bastion inside this VPC specifically.
    enable_private_endpoint = false
    master_ipv4_cidr_block  = var.master_cidr
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  release_channel {
    channel = "REGULAR"
  }

  deletion_protection = true

  # This is a real production cluster on day one - don't let a careless
  # destroy take it out.
  lifecycle {
    prevent_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Main pool - general application workloads (the 27 services + platform
# components: ArgoCD, cert-manager, external-secrets, OTel operator, etc).
# ---------------------------------------------------------------------------
resource "google_container_node_pool" "main" {
  project  = var.project_id
  name     = "${var.cluster_name}-main"
  location = var.region
  cluster  = google_container_cluster.primary.name

  node_count     = var.main_node_count
  node_locations = var.main_node_zones

  node_config {
    machine_type = var.main_machine_type
    disk_size_gb = 80
    disk_type    = "pd-ssd"

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}

# ---------------------------------------------------------------------------
# Optional dedicated pool for stateful workloads (RabbitMQ, MongoDB, Redis).
# Off by default (create_stateful_pool = false) - a genuine option worth
# considering given RabbitMQ's documented bootstrap deadlock history and its
# resource footprint being the heaviest single workload in the cluster, but
# not required to run correctly.
# ---------------------------------------------------------------------------
resource "google_container_node_pool" "stateful" {
  count    = var.create_stateful_pool ? 1 : 0
  project  = var.project_id
  name     = "${var.cluster_name}-stateful"
  location = var.region
  cluster  = google_container_cluster.primary.name

  autoscaling {
    min_node_count = 1
    max_node_count = 3
  }

  node_config {
    machine_type = var.stateful_machine_type
    disk_size_gb = 100
    disk_type    = "pd-ssd"

    taint {
      key    = "workload"
      value  = "stateful"
      effect = "NO_SCHEDULE"
    }

    labels = {
      workload = "stateful"
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}
