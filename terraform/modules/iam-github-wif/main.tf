##############################################################################
# modules/iam-github-wif 
#
# Replaces however GitHub Actions currently authenticates to OCIR (I still
# don't know whether that's a long-lived auth token in repo secrets or OIDC —
# if it's a token, this is a straight security upgrade).
#
# Workload Identity Federation means GitHub Actions gets short-lived
# credentials from its own OIDC token. No service account JSON key ever exists,
# so there is no key to leak, rotate, or accidentally commit — which matters
# given `shared_credentials_file = "../credential/file"` points inside the
# Infrastructure repo tree today.
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

resource "google_iam_workload_identity_pool" "github" {
  project                   = var.project_id
  workload_identity_pool_id = var.pool_id
  display_name              = "GitHub Actions"
  description               = "OIDC federation for github.com/${var.github_owner}"
}

resource "google_iam_workload_identity_pool_provider" "github" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-oidc"
  display_name                       = "GitHub OIDC"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
    "attribute.owner"      = "assertion.repository_owner"
  }

  # CRITICAL. Without this condition, ANY GitHub repository on the internet can
  # exchange a token against this pool. Restricting to your org is the single
  # most important line in this file.
  attribute_condition = "assertion.repository_owner == \"${var.github_owner}\""

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# ---------------------------------------------------------------------------
# CI service account. Deliberately minimal: push images and read secrets.
# It does NOT get GKE deploy permissions, because ArgoCD pulls from git rather
# than CI pushing to the cluster.
# ---------------------------------------------------------------------------
resource "google_service_account" "ci" {
  project      = var.project_id
  account_id   = var.ci_service_account_id
  display_name = "GitHub Actions CI"
}

# Bind only the specific repositories that should be able to impersonate it.
resource "google_service_account_iam_member" "ci_wif" {
  for_each = toset(var.allowed_repositories)

  service_account_id = google_service_account.ci.name
  role               = "roles/iam.workloadIdentityUser"
  member = join("", [
    "principalSet://iam.googleapis.com/",
    google_iam_workload_identity_pool.github.name,
    "/attribute.repository/${each.key}",
  ])
}

resource "google_project_iam_member" "ci" {
  for_each = toset(var.ci_roles)

  project = var.project_id
  role    = each.key
  member  = "serviceAccount:${google_service_account.ci.email}"
}
