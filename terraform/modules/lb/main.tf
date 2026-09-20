##############################################################################
# modules/lb
#
# With Traefik replacing Gateway API, this module is simpler:
# Traefik's LoadBalancer service gets its external IP automatically from GKE
# (a Google Cloud Network Load Balancer, provisioned automatically).
# No need to pre-reserve a static IP for a Gateway resource.
#
# This module now only provisions:
#   - A starting Cloud Armor policy (attached to the NLB via BackendConfig)
#   - Reserved static IP for Traefik's LoadBalancer service (optional but
#     recommended so the IP doesn't change on Traefik restarts)
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

# Static IP for Traefik's LoadBalancer service 
# Reference in Traefik service via:
#   service.spec.loadBalancerIP: <this IP>
# or annotation: networking.gke.io/load-balancer-ip-address: traefik-lb-ip
resource "google_compute_address" "traefik" {
  project      = var.project_id
  name         = "traefik-lb-ip"
  region       = var.region
  address_type = "EXTERNAL"

  lifecycle {
    prevent_destroy = true
  }
}

# Starting Cloud Armor policy - permissive placeholder
# No real rules to port from OCI (confirmed WAF was empty)
resource "google_compute_security_policy" "default" {
  project     = var.project_id
  name        = "traefik-armor-policy"
  description = "Starting policy - no rules, OCI WAF was empty"

  rule {
    action   = "allow"
    priority = "2147483647"
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    description = "Default allow"
  }
}
