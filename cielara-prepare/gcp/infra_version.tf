# Version marker for the control plane: records which prepare vintage this
# project ran and lets the deployer read it back. Module-only surface — the
# legacy prepare scripts are frozen and never create it, so everything here
# stays outside the parity-checked locals (apis, deployer_roles).

resource "google_project_service" "infra_version_storage" {
  project = var.project_id
  service = "storage.googleapis.com"

  # Never switch a shared API off underneath your other workloads.
  disable_on_destroy = false
}

resource "google_storage_bucket" "infra_version" {
  name     = "cielara-infra-version-${var.project_id}"
  project  = var.project_id
  location = "US"

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = true

  depends_on = [google_project_service.infra_version_storage]
}

resource "google_storage_bucket_object" "infra_version" {
  bucket       = google_storage_bucket.infra_version.name
  name         = "version.json"
  content_type = "application/json"

  content = jsonencode({
    prepare_version = local.prepare_version
    channel         = local.release_channel
    module          = local.prepare_module
    provider        = "gcp"
  })
}

resource "google_storage_bucket_iam_member" "deployer_infra_version_read" {
  bucket = google_storage_bucket.infra_version.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.deployer.email}"
}

# The bucket postdates the script era, so adoption is gated on its own flag —
# an import block fails hard when the remote object does not exist.

import {
  for_each = var.migrate_version_resources ? toset(["this"]) : toset([])
  to       = google_storage_bucket.infra_version
  id       = "${var.project_id}/cielara-infra-version-${var.project_id}"
}

import {
  for_each = var.migrate_version_resources ? toset(["this"]) : toset([])
  to       = google_storage_bucket_iam_member.deployer_infra_version_read
  id       = "b/cielara-infra-version-${var.project_id} roles/storage.objectViewer serviceAccount:${local.deployer_sa_email}"
}
