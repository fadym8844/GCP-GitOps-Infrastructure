##############################################################################
# modules/cloudsql
#
# Replaces modules/cloudsql-adopt. That module only ever read an existing
# instance in core-platform-dr-db (Doha/me-central1). Confirmed decision: fresh
# project, fresh instance, in Dammam/me-central2 - the fix this module
# actually delivers vs. the old one.
#
# Two separate things use the word "regional" - worth being precise:
#   - REGION (me-central2/Dammam): confirmed, always correct - the whole
#     point of this module existing instead of adopting the Doha instance.
#   - AVAILABILITY TYPE (HA on/off, a Cloud SQL zonal-vs-regional setting):
#     confirmed OFF, deliberately, for cost. Matches the existing Doha
#     instance's spec exactly, and matches the OCI source's own lack of HA.
#     This means the single-point-of-failure gap this migration was meant 
#     to close on the database specifically is NOT closed by this instance
#     as currently configured - a real, deliberate trade-off, not an
#     oversight. Flag this explicitly wherever this spec is referenced
#     elsewhere (e.g. the migration plan document).
#
# Confirmed spec: MySQL 8.0, Enterprise edition, single zone (no HA),
# db-custom-2-13312 (2 vCPU / 13GB - matches the existing Doha instance),
# 300GB SSD. Private IP only, via the PSA range already reserved in
# modules/network. Attached to the Shared VPC directly.
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

resource "google_sql_database_instance" "prod" {
  project             = var.project_id
  name                = var.instance_name
  database_version    = "MYSQL_8_0"
  region              = var.region
  deletion_protection = true

  settings {
    tier              = var.tier
    edition           = "ENTERPRISE"
    availability_type = "ZONAL" # HA off - confirmed, deliberate cost trade-off, see header note
    disk_size         = var.disk_size_gb
    disk_type         = "PD_SSD"
    disk_autoresize   = true

    backup_configuration {
      enabled                        = true
      binary_log_enabled             = true # required for DMS CDC replication; for MySQL this alone also enables point-in-time recovery - no separate flag exists
      transaction_log_retention_days = 7
    }

    ip_configuration {
      ipv4_enabled    = false # private IP only, no public exposure
      private_network = var.network_id
      # Requires the google_service_networking_connection in modules/network
      # to exist first - PSA must be set up before this can attach.
    }

    database_flags {
      name  = "log_bin_trust_function_creators"
      value = "on"
    }
  }

  # DMS creates the actual replication; this resource is the empty
  # destination instance it replicates into. Terraform doesn't manage the
  # migration job itself - that's console/gcloud DMS work, separate from
  # this module.
}
