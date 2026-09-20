##############################################################################
# envs/prod — core-platform production landing zone, me-central2 (Dammam)
#
# Mirrors the shape of the old OCI `terraform/staging/` stack (which is what
# actually built production, hence every `-stg` name in the core-platform-prod
# compartment). This one is named for what it is.
##############################################################################

terraform {
  required_version = ">= 1.6"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }

  backend "gcs" {
    bucket = "core-platform-tfstate-me-central2"
    prefix = "envs/prod"
  }
}
 
provider "google" {
  region = var.region
}

locals {
  labels = {
    env        = "prod"
    managed_by = "terraform"
    owner      = "platform"
    residency  = "ksa"
  }

  # Enumerated rather than wildcarded so nothing gets enabled by accident.
  workload_apis = [
    "compute.googleapis.com",
    "container.googleapis.com",
    "sqladmin.googleapis.com",
    "artifactregistry.googleapis.com",
    "secretmanager.googleapis.com",
    "servicenetworking.googleapis.com",
    "cloudkms.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
    "monitoring.googleapis.com",
    "logging.googleapis.com",
    "cloudresourcemanager.googleapis.com",
  ]
}

# ---------------------------------------------------------------------------
# Shared VPC host project — owns networking only, never workloads.
# ---------------------------------------------------------------------------
module "network_project" {
  source = "../../modules/project"

  project_id      = var.network_project_id
  display_name    = "core-platform Network Prod"
  billing_account = var.billing_account
  org_id          = var.org_id
  folder_id       = var.folder_id
  labels          = local.labels

  activate_apis = [
    "compute.googleapis.com",
    "servicenetworking.googleapis.com",
    "dns.googleapis.com",
    "cloudresourcemanager.googleapis.com",
  ]

  shared_vpc_host = true
}

# ---------------------------------------------------------------------------
# Workload project — GKE, Artifact Registry, and GitHub WIF live here.
#
# Deliberately NOT the same project as core-platform-dr-db. Cloud SQL instances
# can't move between GCP projects, which is exactly why core-platform-dr-db stays
# put — but that's a reason to leave the database where it is, not a reason
# to build GKE there too. Project boundaries are IAM/billing/quota; reaching
# Cloud SQL privately is a Shared VPC + Private Service Access question,
# handled below regardless of which project the instance itself sits in.
# ---------------------------------------------------------------------------
module "workload_project" {
  source = "../../modules/project"

  project_id      = var.workload_project_id
  display_name    = "core-platform Workload Prod"
  billing_account = var.billing_account
  org_id          = var.org_id
  folder_id       = var.folder_id
  labels          = local.labels

  activate_apis           = local.workload_apis
  shared_vpc_host_project = module.network_project.project_id
}

# ---------------------------------------------------------------------------
# Production database. Confirmed decision: a fresh project (core-platform-database-dr-prod),
# not adopting the existing core-platform-dr-db (Doha, no regional HA, network I
# didn't control). New DMS pipeline, new instance, real HA from day one -
# see modules/cloudsql for the reasoning in full.
# ---------------------------------------------------------------------------
# Shared VPC attachment for workload-prod. db_project's own attachment
# happens inside modules/project via shared_vpc_host_project, no separate
# resource needed here.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Network. CIDRs chosen to avoid everything live on OCI:
#   10.10.0.0/16   prod VCN            (core-platform-vcn-stg)
#   10.0.0.0/16    dev/stg VCN x2      (oke-vcn-quick-*, overlapping)
#   10.20.0.0/16   dev/stg VCN         (core-platform-vcn)
#   10.244.0.0/16  OKE pods
#   10.96.0.0/16   OKE services
#
# Hence the 10.60.x–10.88.x band: clear of all of the above with margin, so a
# VPN between GCP and whatever OCI footprint remains needs no NAT translation.
# ---------------------------------------------------------------------------
module "network" {
  source = "../../modules/network"

  project_id   = module.network_project.project_id
  network_name = "core-platform-prod"
  env          = "prod"
  region       = var.region

  node_cidr    = "10.60.0.0/20"
  pod_cidr     = "10.64.0.0/14"
  service_cidr = "10.68.0.0/20"
  master_cidr  = "172.16.10.0/28"

  proxy_only_cidr = "10.63.0.0/24"
  psa_cidr        = "10.88.0.0/16"

  # Four, not one. All whitelisted together in a single partner change request.
  nat_ip_count = 1
}

# ---------------------------------------------------------------------------
# Confirmed decision: fresh project, not adopting core-platform-dr-db (Doha, no HA).
# This project holds only the database - kept separate from workload_project
# for the same blast-radius reasoning as network-prod vs workload-prod.
# ---------------------------------------------------------------------------
module "db_project" {
  source = "../../modules/project"

  project_id      = var.db_project_id
  display_name    = "core-platform Production DR"
  billing_account = var.billing_account
  org_id          = var.org_id
  folder_id       = var.folder_id
  labels          = local.labels

  activate_apis = [
    "sqladmin.googleapis.com",
    "servicenetworking.googleapis.com",
    "cloudresourcemanager.googleapis.com",
  ]

  shared_vpc_host_project = module.network_project.project_id
}

module "cloudsql" {
  source = "../../modules/cloudsql"

  project_id = module.db_project.project_id
  region     = var.region
  network_id = module.network.network_id
}


# ---------------------------------------------------------------------------
# Artifact Registry — replaces OCIR.
#
# Also worth adding a second push target to GHCR in your GitHub Actions
# workflows, independently of this. During the current OCI suspension your
# images are unreachable, which means you cannot rebuild anywhere even if you
# wanted to. Two registries removes that.
# ---------------------------------------------------------------------------
resource "google_artifact_registry_repository" "docker" {
  project       = module.workload_project.project_id
  location      = var.region
  repository_id = "core-platform"
  format        = "DOCKER"
  description   = "Container images for all core-platform services"

  docker_config {
    immutable_tags = false # set true once CI uses immutable digests
  }

  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = 20
    }
  }
}

# ---------------------------------------------------------------------------
# GitHub Actions federation.
# ---------------------------------------------------------------------------
module "github_wif" {
  source = "../../modules/iam-github-wif"

  project_id           = module.workload_project.project_id
  github_owner         = var.github_owner
  allowed_repositories = var.allowed_repositories
}

# ---------------------------------------------------------------------------
# Static IP + starting Cloud Armor policy for the Gateway API resource
# (helm-charts/gateway-routes, GitOps-managed). Gateway API confirmed as the
# ingress decision - Traefik Hub's API-management features confirmed unused,
# nothing lost by the switch.
# ---------------------------------------------------------------------------
module "lb" {
  source = "../../modules/lb"

  project_id = module.workload_project.project_id
  region     = var.region
}

# ---------------------------------------------------------------------------
# GKE — sized from real, confirmed data: node shape/count from the OCI
# console, per-pod resource requests from the actual cluster, RabbitMQ's
# heavier footprint accounted for in the option to give it its own pool.
# ---------------------------------------------------------------------------
module "gke" {

  # OCI parity: 4 nodes x (8 vCPU / 16 GB). Manual scaling, no autoscaler.
  # VM.Standard.E3.Flex 4 OCPU == 8 vCPU (AMD EPYC, SMT on).
  main_machine_type = "n2-custom-8-16384"
  main_node_count   = 2 # per zone
  main_node_zones   = ["me-central2-a", "me-central2-b"]
  source            = "../../modules/gke"

  project_id            = module.workload_project.project_id
  region                = var.region
  network_self_link     = module.network.network_self_link
  node_subnet_self_link = module.network.nodes_subnet_id
  pods_range_name       = module.network.pods_range_name
  services_range_name   = module.network.services_range_name
}


output "nat_egress_ips" {
  value       = module.network.nat_egress_ips
  description = "1 static outbound IP. Submit this to ANB, HyperPay, Dow Jones as replacement for OCI's 144.24.209.5."
}

output "workload_identity_provider" {
  value = module.github_wif.workload_identity_provider
}

output "ci_service_account" {
  value = module.github_wif.ci_service_account_email
}

output "artifact_registry" {
  value = "${var.region}-docker.pkg.dev/${module.workload_project.project_id}/core-platform"
}

output "cloudsql_connection_name" {
  value = module.cloudsql.connection_name
}

output "cloudsql_private_ip" {
  value = module.cloudsql.private_ip_address
}

output "traefik_lb_ip" {
  value       = module.lb.traefik_lb_ip
  description = "Point all DNS A records here at cutover. This is Traefik's reserved external IP."
}
