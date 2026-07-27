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
  for_each = var.migrate ? toset(local.deployer_roles) : toset([])
  to       = google_project_iam_member.deployer[each.value]
  id       = "${var.project_id} ${each.value} serviceAccount:${local.deployer_sa_email}"
}

import {
  for_each = var.migrate ? toset(["this"]) : toset([])
  to       = google_project_iam_custom_role.vm_secret_manager
  id       = "projects/${var.project_id}/roles/cielaraVmSecretManager"
}

import {
  for_each = var.migrate ? toset(["this"]) : toset([])
  to       = google_project_iam_member.deployer_vm_secret_manager
  id       = "${var.project_id} projects/${var.project_id}/roles/cielaraVmSecretManager serviceAccount:${local.deployer_sa_email}"
}

import {
  for_each = var.migrate ? toset(["this"]) : toset([])
  to       = google_service_account_iam_member.deployer_self_user
  id       = "projects/${var.project_id}/serviceAccounts/${local.deployer_sa_email} roles/iam.serviceAccountUser serviceAccount:${local.deployer_sa_email}"
}

import {
  for_each = var.migrate ? toset(["this"]) : toset([])
  to       = google_service_account_iam_member.deployer_token_creator
  id       = "projects/${var.project_id}/serviceAccounts/${local.deployer_sa_email} roles/iam.serviceAccountTokenCreator serviceAccount:${local.deployer_sa_email}"
}

# JWT signing resources exist only for projects prepared with a script version
# carrying the JWT block (or by this module). Adopting an older project? Re-run
# the latest prepare-gcp.sh first, or these imports fail on the missing key.
import {
  for_each = var.migrate ? toset(["this"]) : toset([])
  to       = google_service_account.app
  id       = "projects/${var.project_id}/serviceAccounts/${local.app_sa_email}"
}

import {
  for_each = var.migrate ? toset(["this"]) : toset([])
  to       = google_kms_key_ring.jwt
  id       = "projects/${var.project_id}/locations/${var.region}/keyRings/cielara-jwt"
}

import {
  for_each = var.migrate ? toset(["this"]) : toset([])
  to       = google_kms_crypto_key.jwt_signing
  id       = "projects/${var.project_id}/locations/${var.region}/keyRings/cielara-jwt/cryptoKeys/jwt-signing"
}

import {
  for_each = var.migrate ? toset(["this"]) : toset([])
  to       = google_project_iam_custom_role.app_jwt_signer
  id       = "projects/${var.project_id}/roles/cielaraAppJwtSigner"
}

import {
  for_each = var.migrate ? toset(["this"]) : toset([])
  to       = google_kms_crypto_key_iam_member.app_jwt_signer
  id       = "projects/${var.project_id}/locations/${var.region}/keyRings/cielara-jwt/cryptoKeys/jwt-signing projects/${var.project_id}/roles/cielaraAppJwtSigner serviceAccount:${local.app_sa_email}"
}
