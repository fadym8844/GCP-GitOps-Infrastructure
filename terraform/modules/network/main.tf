##############################################################################
# modules/network
#
# Replaces OCI `network` + `new_network` + `static_ip`. 
#
# Rough equivalences:
#   VCN                  -> google_compute_network
#   Subnet               -> google_compute_subnetwork
#   NAT Gateway          -> Cloud Router + Cloud NAT  (needs BOTH; OCI needs one)
#   Service Gateway      -> Private Google Access (a subnet flag, not a resource)
#   Security List / NSG  -> google_compute_firewall  (VPC-wide, target by tag)
#   Reserved public IP   -> google_compute_address
#
# The Local Peering Gateway from prod to dev/stg (`LPG-PROD`, 10.0.0.0/16) is
# intentionally NOT reproduced. If dev needs realistic data, that should be a
# masked dataset, not a live network path from production.
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

resource "google_compute_network" "this" {
  project                 = var.project_id
  name                    = var.network_name
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
  description             = "core-platform ${var.env} VPC — ${var.region}"
}

# ---------------------------------------------------------------------------
# Node subnet, with secondary ranges for GKE pods and services.
#
# Secondary ranges must exist before the cluster is created; GKE cannot add
# them later. Getting these wrong means rebuilding the cluster.
# ---------------------------------------------------------------------------
resource "google_compute_subnetwork" "nodes" {
  project       = var.project_id
  name          = "${var.network_name}-nodes"
  region        = var.region
  network       = google_compute_network.this.id
  ip_cidr_range = var.node_cidr

  # Equivalent of the OCI Service Gateway: lets private nodes reach Google
  # APIs (Artifact Registry, Secret Manager, Cloud SQL admin) without egressing
  # to the internet.
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pod_cidr
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.service_cidr
  }

  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# ---------------------------------------------------------------------------
# Proxy-only subnet — mandatory for a REGIONAL external Application LB.
# Reserved entirely for Google's proxies; no workload gets an IP here.
# ---------------------------------------------------------------------------
resource "google_compute_subnetwork" "proxy" {
  count = var.proxy_only_cidr == null ? 0 : 1

  project       = var.project_id
  name          = "${var.network_name}-proxy-only"
  region        = var.region
  network       = google_compute_network.this.id
  ip_cidr_range = var.proxy_only_cidr
  purpose       = "REGIONAL_MANAGED_PROXY"
  role          = "ACTIVE"
}

# ---------------------------------------------------------------------------
# Static egress IPs.
#
# On OCI you had exactly one NAT IP (144.24.209.5) and partners whitelist it.
# Reserve several here and get them ALL approved in one change request —
# adding one later means repeating every counterparty's 4–12 week cycle.
# ---------------------------------------------------------------------------
resource "google_compute_address" "nat" {
  count = var.nat_ip_count

  project      = var.project_id
  name         = "${var.network_name}-nat-${count.index + 1}"
  region       = var.region
  address_type = "EXTERNAL"

  # These addresses are the thing partners whitelist. Do not let Terraform
  # replace them casually.
  lifecycle {
    prevent_destroy = true
  }
}

resource "google_compute_router" "this" {
  project = var.project_id
  name    = "${var.network_name}-router"
  region  = var.region
  network = google_compute_network.this.id
}

resource "google_compute_router_nat" "this" {
  project = var.project_id
  name    = "${var.network_name}-nat"
  region  = var.region
  router  = google_compute_router.this.name

  # MANUAL_ONLY pins egress to the reserved addresses above. With AUTO_ONLY,
  # Google picks ephemeral IPs that change — which would silently break every
  # partner whitelist.
  nat_ip_allocate_option = "MANUAL_ONLY"
  nat_ips                = google_compute_address.nat[*].self_link

  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  subnetwork {
    name = google_compute_subnetwork.nodes.id
    source_ip_ranges_to_nat = [
      "PRIMARY_IP_RANGE",
      "LIST_OF_SECONDARY_IP_RANGES",
    ]
    # Pods egress too — without this, pod traffic has no NAT path.
    secondary_ip_range_names = ["pods"]
  }

  # Dynamic port allocation avoids the classic failure where one busy service
  # exhausts source ports and partner calls start failing intermittently.
  enable_dynamic_port_allocation = true
  min_ports_per_vm               = 128
  max_ports_per_vm               = 8192

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# ---------------------------------------------------------------------------
# Private Service Access — gives Cloud SQL a private IP inside this VPC.
# Without it, Cloud SQL is reachable only over public IP or the auth proxy.
# ---------------------------------------------------------------------------
resource "google_compute_global_address" "psa" {
  count = var.psa_cidr == null ? 0 : 1

  project       = var.project_id
  name          = "${var.network_name}-psa"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = split("/", var.psa_cidr)[1]
  address       = split("/", var.psa_cidr)[0]
  network       = google_compute_network.this.id
}

resource "google_service_networking_connection" "psa" {
  count = var.psa_cidr == null ? 0 : 1

  network                 = google_compute_network.this.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.psa[0].name]
}

# ---------------------------------------------------------------------------
# Firewall. GCP has an implicit deny-all on ingress, so unlike OCI security
# lists you only write the allows.
# ---------------------------------------------------------------------------

# Health checks and LB proxies. Ranges are Google-owned and fixed.
resource "google_compute_firewall" "allow_health_checks" {
  project     = var.project_id
  name        = "${var.network_name}-allow-health-checks"
  network     = google_compute_network.this.name
  description = "GCP health check and LB proxy ranges"
  direction   = "INGRESS"
  priority    = 1000

  source_ranges = [
    "35.191.0.0/16",
    "130.211.0.0/22",
  ]

  allow {
    protocol = "tcp"
  }

  target_tags = ["gke-node"]
}

resource "google_compute_firewall" "allow_proxy_only" {
  count = var.proxy_only_cidr == null ? 0 : 1

  project       = var.project_id
  name          = "${var.network_name}-allow-proxy-only"
  network       = google_compute_network.this.name
  description   = "Regional ALB proxies to backends"
  direction     = "INGRESS"
  priority      = 1000
  source_ranges = [var.proxy_only_cidr]

  allow {
    protocol = "tcp"
    ports    = ["80", "443", "8080"]
  }

  target_tags = ["gke-node"]
}

# Intra-VPC traffic between nodes and pods.
resource "google_compute_firewall" "allow_internal" {
  project     = var.project_id
  name        = "${var.network_name}-allow-internal"
  network     = google_compute_network.this.name
  description = "Node and pod to node and pod"
  direction   = "INGRESS"
  priority    = 1100

  source_ranges = [var.node_cidr, var.pod_cidr]

  allow { protocol = "tcp" }
  allow { protocol = "udp" }
  allow { protocol = "icmp" }
}

# GKE control plane to webhooks. Without this, admission webhooks
# (cert-manager, ArgoCD) time out — the same class of failure as the orphaned
# ingress-nginx-admission webhook that previously blocked cert renewal.
resource "google_compute_firewall" "allow_master_webhooks" {
  count = var.master_cidr == null ? 0 : 1

  project       = var.project_id
  name          = "${var.network_name}-allow-master-webhooks"
  network       = google_compute_network.this.name
  description   = "GKE control plane to admission webhooks"
  direction     = "INGRESS"
  priority      = 1000
  source_ranges = [var.master_cidr]

  allow {
    protocol = "tcp"
    ports    = ["443", "8443", "9443", "10250", "15017"]
  }

  target_tags = ["gke-node"]
}

# Deny-all egress is NOT set here. Add it only after the discovery data tells
# us every outbound destination — locking egress down before then will break
# partner integrations in ways that are painful to diagnose.
