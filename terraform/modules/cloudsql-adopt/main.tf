##############################################################################
# modules/cloudsql-adopt
#
# Confirmed: core-platform-dr-db's Cloud SQL instance (built for the separate MySQL
# DR migration — OCI to Cloud SQL via DMS, CDC replication) becomes the
# PERMANENT production database once it's fully caught up with OCI data. So
# this module does NOT provision a new instance — it only references the one
# that already exists, via a data source. Applying this can never accidentally
# create, modify, or delete the database.
#
# GKE deliberately does NOT live in this same project — see the README and
# envs/prod/main.tf for why that's not actually required. This module's only
# job is: read the instance's connection details, and let specific service
# accounts connect to it.
#
# Once the team is ready to manage it via Terraform going forward (flip on
# regional HA, adjust flags, etc.), `terraform import` can bring the real
# resource under management — do that as a deliberate, separately-reviewed
# step, not as part of this apply.
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

data "google_sql_database_instance" "prod" {
  project = var.dr_db_project_id
  name    = var.instance_name
}

# Lets GKE workloads (via Workload Identity) connect without a second set of
# credentials living anywhere.
resource "google_project_iam_member" "gke_sql_client" {
  for_each = var.gke_service_accounts

  project = var.dr_db_project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${each.value}"
}
