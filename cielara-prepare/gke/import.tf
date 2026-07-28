# Adoption of an already-prepared project (migrate = true): imports the
# existing resources instead of creating them. The deployer key cannot be
# imported (create_key = false keeps the existing one working). After apply,
# `terraform plan` must show no changes.

import {
  for_each = var.migrate ? toset(local.apis) : toset([])
  to       = google_project_service.apis[each.value]
  id       = "${var.project_id}/${each.value}"
}

import {
  for_each = var.migrate ? toset(["this"]) : toset([])
  to       = google_service_account.deployer
  id       = "projects/${var.project_id}/serviceAccounts/${local.deployer_sa_email}"
}

import {
  for_each = var.migrate ? toset(["this"]) : toset([])
  to       = google_service_account.node
  id       = "projects/${var.project_id}/serviceAccounts/${local.node_sa_email}"
}

import {
  for_each = var.migrate ? toset(["this"]) : toset([])
  to       = google_service_account.app
  id       = "projects/${var.project_id}/serviceAccounts/${local.app_sa_email}"
}

import {
  for_each = var.migrate ? toset(local.deployer_roles) : toset([])
  to       = google_project_iam_member.deployer[each.value]
  id       = "${var.project_id} ${each.value} serviceAccount:${local.deployer_sa_email}"
}

import {
  for_each = var.migrate ? toset(local.node_roles) : toset([])
  to       = google_project_iam_member.node[each.value]
  id       = "${var.project_id} ${each.value} serviceAccount:${local.node_sa_email}"
}

import {
  for_each = var.migrate ? toset(["this"]) : toset([])
  to       = google_project_iam_custom_role.app_secret_manager
  id       = "projects/${var.project_id}/roles/cielaraAppSecretManager"
}

import {
  for_each = var.migrate ? toset(["this"]) : toset([])
  to       = google_project_iam_member.app_secret_manager
  id       = "${var.project_id} projects/${var.project_id}/roles/cielaraAppSecretManager serviceAccount:${local.app_sa_email}"
}

import {
  for_each = var.migrate ? toset(["this"]) : toset([])
  to       = google_project_iam_custom_role.filestore_sweep
  id       = "projects/${var.project_id}/roles/cielaraProvisionerFilestoreSweep"
}

import {
  for_each = var.migrate ? toset(["this"]) : toset([])
  to       = google_project_iam_member.deployer_filestore_sweep
  id       = "${var.project_id} projects/${var.project_id}/roles/cielaraProvisionerFilestoreSweep serviceAccount:${local.deployer_sa_email}"
}

import {
  for_each = var.migrate ? toset(["this"]) : toset([])
  to       = google_service_account_iam_member.deployer_token_creator
  id       = "projects/${var.project_id}/serviceAccounts/${local.deployer_sa_email} roles/iam.serviceAccountTokenCreator serviceAccount:${local.deployer_sa_email}"
}

# The infra-version bucket postdates the script era, so its adoption is gated
# on its own flag: migrate = true alone must keep working for pre-bucket
# vintages (an import block fails hard when the remote object does not exist).

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
