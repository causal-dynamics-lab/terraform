# Version marker for the control plane: records which prepare vintage this
# subscription ran and lets the deployer read it back. Module-only surface —
# the frozen prepare script never creates it; the Storage Blob Data Reader
# assignment is carved out of core's script<->module parity test.

locals {
  # Storage account names are 3-24 chars, lowercase alphanumeric, globally
  # unique — hence the hashed client id. Per-client (like the SP) so several
  # deployments can share one subscription.
  infra_version_rg_name      = "cielara-infra-version-${var.cielara_client_id}"
  infra_version_account_name = "cielarainfra${substr(sha1(var.cielara_client_id), 0, 12)}"
}

resource "azurerm_resource_group" "infra_version" {
  name     = local.infra_version_rg_name
  location = var.location
}

# Shared-key auth stays enabled (the default): the azurerm provider uploads
# the blob via ARM listKeys, so the applying identity only needs
# Owner/Contributor — disabling it would demand data-plane RBAC from every
# customer. The deployer's read uses Entra RBAC regardless.
resource "azurerm_storage_account" "infra_version" {
  name                            = local.infra_version_account_name
  resource_group_name             = azurerm_resource_group.infra_version.name
  location                        = azurerm_resource_group.infra_version.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
}

resource "azurerm_storage_container" "infra_version" {
  name                  = "infra-version"
  storage_account_id    = azurerm_storage_account.infra_version.id
  container_access_type = "private"
}

resource "azurerm_storage_blob" "infra_version" {
  name                 = "version.json"
  storage_container_id = azurerm_storage_container.infra_version.id
  type                 = "Block"
  content_type         = "application/json"

  source_content = jsonencode({
    prepare_version = local.prepare_version
    revision        = local.prepare_revision
    channel         = local.release_channel
    module          = local.prepare_module
    provider        = "aks"
    location        = var.location
  })
}

resource "azurerm_role_assignment" "deployer_infra_version_read" {
  scope                = azurerm_storage_account.infra_version.id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azuread_service_principal.deployer.object_id

  skip_service_principal_aad_check = true

  lifecycle {
    ignore_changes = [skip_service_principal_aad_check]
  }
}

# The version resources postdate the script era, so whether they exist
# depends on what prepared this subscription (script vs earlier module run).
# An import block fails hard when the remote object does not exist, so
# adoption keys on a live existence check instead of a flag. Only consulted
# when migrate = true, so fresh prepares never shell out. The role-assignment
# id is random and must be looked up, not derived — the check returns it.

data "external" "infra_version_marker" {
  count = var.migrate ? 1 : 0
  program = [
    "bash", "${path.module}/check-version-marker.sh",
    local.infra_version_rg_name,
    local.infra_version_account_name,
    var.migrate_sp_object_id,
    var.subscription_id,
  ]
}

locals {
  infra_version_marker_exists = try(data.external.infra_version_marker[0].result.exists, "false") == "true"
  infra_version_ra_id         = try(data.external.infra_version_marker[0].result.ra_id, "")
}
