##############################################################################
# modules/project
#
# Replaces the OCI `compartments` module. Note this is a genuinely different
# model, not a rename: OCI compartments are a nesting/IAM construct inside one
# tenancy, whereas GCP projects are hard billing + API + quota + IAM
# boundaries. That difference is the point — it's what makes "dev cannot reach
# prod" structural rather than conventional.
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

resource "google_project" "this" {
  name            = var.display_name
  project_id      = var.project_id
  billing_account = var.billing_account
  org_id          = var.folder_id == null ? var.org_id : null
  folder_id       = var.folder_id

  # Never create the default VPC — it has permissive firewall rules
  # (0.0.0.0/0 on 22/3389) that you do not want anywhere near production.
  auto_create_network = false

  labels = var.labels
}

resource "google_project_service" "this" {
  for_each = toset(var.activate_apis)

  project = google_project.this.project_id
  service = each.key

  # Leave APIs enabled on destroy: disabling them can cascade into deleting
  # resources in other projects that depend on them.
  disable_on_destroy         = false
  disable_dependent_services = false
}

# ---------------------------------------------------------------------------
# Shared VPC wiring
# ---------------------------------------------------------------------------
resource "google_compute_shared_vpc_host_project" "this" {
  count      = var.shared_vpc_host ? 1 : 0
  project    = google_project.this.project_id
  depends_on = [google_project_service.this]
}

resource "google_compute_shared_vpc_service_project" "this" {
  count           = var.shared_vpc_host_project == null ? 0 : 1
  host_project    = var.shared_vpc_host_project
  service_project = google_project.this.project_id
  depends_on      = [google_project_service.this]
}
