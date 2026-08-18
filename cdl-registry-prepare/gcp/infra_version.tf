# Version marker for the control plane: records which prepare vintage this
# project ran and lets the deployer read it back. Module-only surface — the
# legacy prepare scripts are frozen and never create it, so everything here
# stays outside the parity-checked locals (apis, deployer_roles).

# Only consulted when migrate = true, so fresh prepares never shell out —
# customers running the module themselves need no gcloud CLI on that path.
data "external" "infra_version_marker" {
  count   = var.migrate ? 1 : 0
  program = ["bash", "${path.module}/check-version-marker.sh", "cielara-infra-version-${var.project_id}"]
}

locals {
  infra_version_marker_exists = try(data.external.infra_version_marker[0].result.exists, "false") == "true"
}

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
    revision        = local.prepare_revision
    channel         = local.release_channel
    module          = local.prepare_module
    provider        = "gcp"
    # The control plane compares this against the deploy form's region before
    # dispatching: the KMS keyring lives here and keyring locations are
    # immutable, so a mismatched deploy would only fail at the first JWKS call.
    region = var.region
  })
}

resource "google_storage_bucket_iam_member" "deployer_infra_version_read" {
  bucket = google_storage_bucket.infra_version.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.deployer.email}"
}

# An import block fails hard when the remote object does not exist, so
# adoption keys on the live existence check above instead of a flag.

import {
  for_each = local.infra_version_marker_exists ? toset(["this"]) : toset([])
  to       = google_storage_bucket.infra_version
  id       = "${var.project_id}/cielara-infra-version-${var.project_id}"
}

import {
  for_each = local.infra_version_marker_exists ? toset(["this"]) : toset([])
  to       = google_storage_bucket_iam_member.deployer_infra_version_read
  id       = "b/cielara-infra-version-${var.project_id} roles/storage.objectViewer serviceAccount:${local.deployer_sa_email}"
}
