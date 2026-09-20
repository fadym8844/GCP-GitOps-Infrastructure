##############################################################################
# Bootstrap — run ONCE with local state, then migrate state into the bucket
# it creates.
#
#   terraform init && terraform apply
#   # uncomment the backend block below, then:
#   terraform init -migrate-state
##############################################################################

terraform {
  required_version = ">= 1.6"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0" # verify the current major before first use 
    }
  }

  # backend "gcs" {
  #   bucket = "core-platform-tfstate-me-central2"
  #   prefix = "bootstrap"
  # }
}

provider "google" {
  region = var.region
}

variable "org_id" {
  type        = string
  description = "GCP organisation ID."
}

variable "billing_account" {
  type        = string
  description = "Billing account ID from CNTXT."
}

variable "folder_id" {
  type        = string
  default     = null
  description = "Optional parent folder. If set, takes precedence over org_id."
}

variable "region" {
  type    = string
  default = "me-central2"
}

variable "state_project_id" {
  type    = string
  default = "core-platform-tfstate"
}

# ---------------------------------------------------------------------------
# State project — deliberately separate from every workload project so a
# workload-level problem can never lock you out of your own Terraform state.
# ---------------------------------------------------------------------------
resource "google_project" "tfstate" {
  name            = "core-platform Terraform State"
  project_id      = var.state_project_id
  billing_account = var.billing_account
  org_id          = var.folder_id == null ? var.org_id : null
  folder_id       = var.folder_id

  # Keeps the default network from being created; we never want one here.
  auto_create_network = false
}

resource "google_project_service" "tfstate" {
  for_each = toset([
    "storage.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "iam.googleapis.com",
    "serviceusage.googleapis.com",
  ])

  project            = google_project.tfstate.project_id
  service            = each.key
  disable_on_destroy = false
}

resource "google_storage_bucket" "tfstate" {
  project  = google_project.tfstate.project_id
  name     = "${var.state_project_id}-${var.region}"
  location = upper(var.region)

  # Versioning is the difference between "I broke state" and "I lost the
  # platform". Non-negotiable.
  versioning { enabled = true }

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  # Guard against terraform destroy taking your state with it.
  force_destroy = false

  lifecycle_rule {
    condition { num_newer_versions = 30 }
    action { type = "Delete" }
  }

  depends_on = [google_project_service.tfstate]
}

output "state_bucket" {
  value       = google_storage_bucket.tfstate.name
  description = "Put this in the gcs backend block of every stack."
}
