# Adoption of an already-prepared project (migrate = true): imports the
# existing resources instead of creating them. The deployer key cannot be
# imported (create_key = false keeps the existing one working). After apply,
# `terraform plan` must show no changes.

# API imports iterate the frozen migrate_apis list, not the live one: APIs the
# module started enabling after the script era are off on a project adopted
# earlier, and importing a disabled service fails the plan outright.
import {
  for_each = var.migrate ? toset(local.migrate_apis) : toset([])
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

# Role imports iterate the frozen migrate_* lists, not the live grant lists:
# roles added to the module after the script era are created (additive,
# idempotent), never imported — see the comment in main.tf.
import {
  for_each = var.migrate ? toset(local.migrate_deployer_roles) : toset([])
  to       = google_project_iam_member.deployer[each.value]
  id       = "${var.project_id} ${each.value} serviceAccount:${local.deployer_sa_email}"
}

import {
  for_each = var.migrate ? toset(local.migrate_node_roles) : toset([])
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

# The infra-version bucket postdates the script era, so whether it exists
# depends on what created this project (script vs earlier module run). An
# import block fails hard when the remote object does not exist, so adoption
# keys on a live existence check (infra_version.tf) instead of a flag.

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
# JWT signing resources: the frozen prepare scripts never create them, so a
# script-prepared project adopts by CREATING them here. Only projects prepared
# while the scripts briefly carried a JWT block have anything to import, and a
# partly-applied earlier run can have some and not others, so each import keys
# on its own live existence check (jwt_detect.tf) rather than on var.migrate.

import {
  for_each = local.jwt_existing.keyring ? toset(["this"]) : toset([])
  to       = google_kms_key_ring.jwt
  id       = "projects/${var.project_id}/locations/${var.region}/keyRings/cielara-jwt"
}

import {
  for_each = local.jwt_existing.key ? toset(["this"]) : toset([])
  to       = google_kms_crypto_key.jwt_signing
  id       = "projects/${var.project_id}/locations/${var.region}/keyRings/cielara-jwt/cryptoKeys/jwt-signing"
}

import {
  for_each = local.jwt_existing.role ? toset(["this"]) : toset([])
  to       = google_project_iam_custom_role.app_jwt_signer
  id       = "projects/${var.project_id}/roles/cielaraAppJwtSigner"
}

import {
  for_each = local.jwt_existing.signer_sa ? toset(["this"]) : toset([])
  to       = google_service_account.jwt_signer
  id       = "projects/${var.project_id}/serviceAccounts/${local.jwt_signer_sa_email}"
}

# google_kms_crypto_key_iam_member.jwt_signer is deliberately NOT imported, for
# the same reason as the Workload Identity binding below: creating an IAM member
# is a read-modify-write, so adopting an existing binding through create is safe
# and needs no existence probe.

# google_service_account_iam_member.jwt_signer_wi is deliberately NOT imported:
# the script's Workload Identity binding is best-effort (skipped when the WI
# pool did not exist yet), so it may be absent. Creating an IAM member is a
# read-modify-write — adopting an existing binding through create is safe.
