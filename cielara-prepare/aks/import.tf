# Adoption of an already-prepared subscription (migrate = true). Azure object
# ids are random — run ./discover-migrate.sh first; it writes them to
# migrate.auto.tfvars. The client secret cannot be imported (create_secret =
# false keeps the existing one working). After apply, `terraform plan` must
# show no changes.

import {
  for_each = var.migrate ? toset(["this"]) : toset([])
  to       = azuread_application.deployer
  id       = "/applications/${var.migrate_app_object_id}"
}

import {
  for_each = var.migrate ? toset(["this"]) : toset([])
  to       = azuread_service_principal.deployer
  id       = "/servicePrincipals/${var.migrate_sp_object_id}"
}

import {
  for_each = var.migrate ? toset(["this"]) : toset([])
  to       = azurerm_role_assignment.contributor
  id       = var.migrate_contributor_assignment_id
}

import {
  for_each = var.migrate ? toset(["this"]) : toset([])
  to       = azurerm_role_assignment.rbac_admin
  id       = var.migrate_rbac_admin_assignment_id
}

# JWT signing resources, keyed on the live probe in jwt.tf rather than on
# var.migrate: the frozen prepare scripts never created them, so only a
# lost-state re-adopt of a module-prepared subscription has anything to import.
# Skipping an absent one leaves it to create, which is the migration path.

import {
  for_each = local.jwt_found.rg_id != "" ? toset(["this"]) : toset([])
  to       = azurerm_resource_group.jwt
  id       = local.jwt_found.rg_id
}

import {
  for_each = local.jwt_found.vault_id != "" ? toset(["this"]) : toset([])
  to       = azurerm_key_vault.jwt
  id       = local.jwt_found.vault_id
}

import {
  for_each = local.jwt_found.key_id != "" ? toset(["this"]) : toset([])
  to       = azurerm_key_vault_key.jwt_signing
  id       = local.jwt_found.key_id
}

import {
  for_each = local.jwt_found.identity_id != "" ? toset(["this"]) : toset([])
  to       = azurerm_user_assigned_identity.jwt_signer
  id       = local.jwt_found.identity_id
}

import {
  for_each = local.jwt_found.applier_officer_id != "" ? toset(["this"]) : toset([])
  to       = azurerm_role_assignment.applier_jwt_crypto_officer
  id       = local.jwt_found.applier_officer_id
}

import {
  for_each = local.jwt_found.crypto_user_id != "" ? toset(["this"]) : toset([])
  to       = azurerm_role_assignment.jwt_signer_crypto_user
  id       = local.jwt_found.crypto_user_id
}

import {
  for_each = local.jwt_found.deployer_mi_id != "" ? toset(["this"]) : toset([])
  to       = azurerm_role_assignment.deployer_jwt_signer_mi_contributor
  id       = local.jwt_found.deployer_mi_id
}
