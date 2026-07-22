# Migration / re-adoption: set migrate = true to import resources that
# already exist — created by prepare-aks.sh, or by this module when the state
# was lost — instead of creating them.
#
# Unlike the GCP flavors, Azure object ids are not derivable from names:
# the app/SP object ids and role-assignment GUIDs are random. Run
# ./discover-migrate.sh first — it looks them up with the az CLI and writes
# migrate.auto.tfvars.
#
# The client secret is the one thing that cannot be imported; set
# create_secret = false to leave the existing secret untouched — the control
# plane already holds it.
#
# Acceptance gate: after `terraform apply` with migrate = true, a plain
# `terraform plan` must show no changes. (One known exception: a role
# assignment condition written by an older script vintage can differ in
# whitespace and show a one-time in-place update — that is cosmetic.)

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
