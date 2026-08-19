# Customer-owned Key Vault EC key the data plane signs its JWTs with. The
# private key never leaves this subscription: Cielara signs through the signer
# identity below, and the deployer SP gets no vault role (its RBAC-admin grant
# cannot assign Key Vault Crypto roles). A dedicated vault, not the deployment's
# own, because that one is control-plane-created and dies with the deployment.
# Its name is derived from the client id, so the control plane recomputes it.
locals {
  jwt_rg_name = "cielara-jwt-${var.cielara_client_id}"
  # Must stay identical to azurerm_user_assigned_identity.jwt_signer.name below;
  # the probe needs a plan-time constant, the resource keeps the literal that
  # core's parity test pins.
  jwt_identity   = "cielara-jwt-signer"
  jwt_vault_name = "cielarajwt${substr(sha1(var.cielara_client_id), 0, 12)}"
}

resource "azurerm_resource_group" "jwt" {
  name     = local.jwt_rg_name
  location = var.location
}

resource "azurerm_key_vault" "jwt" {
  name                = local.jwt_vault_name
  location            = azurerm_resource_group.jwt.location
  resource_group_name = azurerm_resource_group.jwt.name
  tenant_id           = data.azuread_client_config.current.tenant_id
  sku_name            = "standard"

  # RBAC data-plane authorization: key access is Azure-role-driven, and the
  # only principal granted a crypto role is the signer identity below.
  rbac_authorization_enabled = true

  # A signing key must survive an accidental vault deletion long enough to
  # notice: purge protection makes soft-delete irreversible for the retention
  # window, so nothing can hard-delete key material in one step.
  purge_protection_enabled   = true
  soft_delete_retention_days = 90
}

# The identity APPLYING this module (you) needs data-plane rights to create
# the key — RBAC mode grants the vault creator nothing by itself.
resource "azurerm_role_assignment" "applier_jwt_crypto_officer" {
  scope                = azurerm_key_vault.jwt.id
  role_definition_name = "Key Vault Crypto Officer"
  principal_id         = data.azuread_client_config.current.object_id
}

resource "azurerm_key_vault_key" "jwt_signing" {
  name         = "jwt-signing"
  key_vault_id = azurerm_key_vault.jwt.id
  key_type     = "EC"
  curve        = "P-256"
  key_opts     = ["sign", "verify"]

  # Azure RBAC assignments propagate asynchronously; the azurerm provider
  # retries data-plane 403s for a while, and this dependency makes the
  # assignment exist before the first attempt.
  depends_on = [azurerm_role_assignment.applier_jwt_crypto_officer]

  # Opt-in scheduled rotation: a new version that many months after each
  # version's creation, no expiry — earlier versions stay enabled and keep
  # verifying, and the versionless key reference resolves to the newest.
  # On-demand rotation stays `az keyvault key rotate` (see the README).
  dynamic "rotation_policy" {
    for_each = var.jwt_key_auto_rotation_months > 0 ? [1] : []

    content {
      automatic {
        time_after_creation = "P${var.jwt_key_auto_rotation_months}M"
      }
    }
  }
}

# The runtime signing identity admin-backend federates as (Workload Identity).
# Customer-created here — not by the deploy terraform — because only you can
# grant it the crypto role below: the deployer SP's conditioned RBAC-admin
# grant cannot assign Key Vault Crypto User to anything, itself included.
resource "azurerm_user_assigned_identity" "jwt_signer" {
  name                = "cielara-jwt-signer"
  location            = azurerm_resource_group.jwt.location
  resource_group_name = azurerm_resource_group.jwt.name
}

# Sign + read-public-key only ("Key Vault Crypto User"); no key create/delete,
# so the runtime identity can never rotate or destroy its own key.
resource "azurerm_role_assignment" "jwt_signer_crypto_user" {
  scope                = azurerm_key_vault.jwt.id
  role_definition_name = "Key Vault Crypto User"
  principal_id         = azurerm_user_assigned_identity.jwt_signer.principal_id
}

# The deploy terraform (run by the deployer SP) binds each cluster's
# jwt-signer ServiceAccount to this identity with a federated identity
# credential — a management-plane write on the identity resource. Scoped to
# exactly this one identity: the deployer can bind pods it already controls to
# the signing identity (that is the product working), but gains nothing on the
# vault or the key.
resource "azurerm_role_assignment" "deployer_jwt_signer_mi_contributor" {
  scope                = azurerm_user_assigned_identity.jwt_signer.id
  role_definition_name = "Managed Identity Contributor"
  principal_id         = azuread_service_principal.deployer.object_id

  skip_service_principal_aad_check = true

  lifecycle {
    ignore_changes = [skip_service_principal_aad_check]
  }
}

# Which of the above already exist, so a lost-state re-adopt imports them
# instead of failing on create (the vault has purge protection, so a failed
# create/delete cycle is expensive). Only read when migrate = true; the frozen
# prepare scripts create none of these, so a script-prepared subscription takes
# the create path with no probe needed.
data "external" "jwt_resources" {
  count = var.migrate ? 1 : 0

  program = [
    # Literals and locals only: referencing the resources themselves would defer
    # this read past plan time, and the import ids below must be known at plan.
    "bash", "${path.module}/check-jwt-resources.sh",
    local.jwt_rg_name,
    local.jwt_vault_name,
    local.jwt_identity,
    data.azuread_client_config.current.object_id,
    var.cielara_client_id,
  ]
}

locals {
  jwt_found = {
    for k in ["rg_id", "vault_id", "key_id", "identity_id", "crypto_user_id", "applier_officer_id", "deployer_mi_id"] :
    k => try(data.external.jwt_resources[0].result[k], "")
  }
}
