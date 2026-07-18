# Migration / re-adoption: set migrate = true to import resources that
# already exist — created by prepare-gke.sh, or by this module when the state
# was lost — instead of creating them. Every GKE prepare resource has a
# deterministic id, so no discovery step is needed.
#
# The deployer key is the one thing that cannot be imported (the provider
# does not support google_service_account_key import); set create_key = false
# to leave the existing key untouched — the control plane already holds it.
#
# Acceptance gate: after `terraform apply` with migrate = true, a plain
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
