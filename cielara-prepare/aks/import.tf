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
