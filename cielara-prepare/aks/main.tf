# Prepares a customer Azure subscription for a Cielara AKS deployment: the
# Entra service principal the Cielara control plane authenticates as, and its
# subscription-scoped role assignments. No Cielara identity is added to the
# tenant — the control plane holds only this SP's credential.
#
# The SP name embeds the Cielara client id on purpose: it is per-deployment,
# so resetting one deployment's secret never invalidates another deployment's
# stored credential. The resource set mirrors prepare-aks.sh (a parity test in
# the Cielara control plane keeps them in lockstep for as long as both ship).

locals {
  sp_name = "cielara_aks_deployer_${var.cielara_client_id}"

  # Pentest A9: an UNCONSTRAINED subscription-scoped "Role Based Access
  # Control Administrator" can self-escalate — it could assign Owner (or RBAC
  # Admin) to any principal, including itself. The ABAC condition below
  # allowlists exactly the built-in roles the AKS data-plane deploy assigns:
  # Contributor, Network Contributor, Reader, Key Vault Secrets Officer,
  # Key Vault Secrets User, Storage Account Contributor. Owner / User Access
  # Administrator / RBAC Administrator are NOT in the list, so the escalation
  # path is closed.
  rbac_admin_role_guids = [
    "b24988ac-6180-42a0-ab88-20f7382dd24c",
    "4d97b98b-1d4f-4787-a291-c67834d212e7",
    "acdd72a7-3385-48ef-bd42-f606fba81ae7",
    "b86a8fe4-44ce-4948-aee5-eccb2c155cd7",
    "4633458b-17de-408a-b874-0445c86b69e6",
    "17d1049b-9a84-46fb-8f53-869881c3d3ab",
  ]
  rbac_admin_guid_set  = "{${join(", ", local.rbac_admin_role_guids)}}"
  rbac_admin_condition = <<-EOT
    (
     (
      !(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})
     )
     OR
     (
      @Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals ${local.rbac_admin_guid_set}
     )
    )
    AND
    (
     (
      !(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})
     )
     OR
     (
      @Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals ${local.rbac_admin_guid_set}
     )
    )
  EOT

  # Resource providers the deploy needs registered on the subscription. The
  # module does NOT register them (most subscriptions already have them, and
  # Terraform cannot adopt an existing registration cleanly) — run the
  # command from the README, or let the first deploy surface
  # MissingSubscriptionRegistration for any stragglers.
  required_resource_providers = [
    "Microsoft.Network",
    "Microsoft.ContainerService",
    "Microsoft.Compute",
    "Microsoft.DBforPostgreSQL",
    "Microsoft.KeyVault",
    "Microsoft.Storage",
    "Microsoft.ManagedIdentity",
  ]

  subscription_scope = "/subscriptions/${var.subscription_id}"
}

data "azuread_client_config" "current" {}

resource "azuread_application" "deployer" {
  display_name = local.sp_name

  # Traceability tag mirroring the script; harmless if absent on adopted apps.
  tags = ["cielara-client:${var.cielara_client_id}"]
}

resource "azuread_service_principal" "deployer" {
  client_id = azuread_application.deployer.client_id
}

resource "azuread_application_password" "deployer" {
  count = var.create_secret ? 1 : 0

  application_id = azuread_application.deployer.id
  display_name   = "cielara-prepare"
}

# Contributor manages the deploy's resources (cluster, database, key vault,
# storage, gateway, network, identities).
resource "azurerm_role_assignment" "contributor" {
  scope                = local.subscription_scope
  role_definition_name = "Contributor"
  principal_id         = azuread_service_principal.deployer.object_id

  # A freshly created SP lags Entra replication; skipping the AAD check lets
  # the assignment succeed instead of failing on "principal not found".
  skip_service_principal_aad_check = true
}

# The deploy creates role assignments of its own, which Contributor alone
# cannot — constrained RBAC Admin instead of Owner (see condition rationale
# above).
resource "azurerm_role_assignment" "rbac_admin" {
  scope                = local.subscription_scope
  role_definition_name = "Role Based Access Control Administrator"
  principal_id         = azuread_service_principal.deployer.object_id
  condition            = local.rbac_admin_condition
  condition_version    = "2.0"

  skip_service_principal_aad_check = true
}

# The handback: upload this file in the Cielara deploy form (or paste its
# four values). The secret also lives in the Terraform state — protect the
# state like a credential (see README / backend.tf).
resource "local_sensitive_file" "creds" {
  count = var.create_secret ? 1 : 0

  filename        = var.creds_output_path
  file_permission = "0600"
  content = jsonencode({
    subscription_id = var.subscription_id
    tenant_id       = data.azuread_client_config.current.tenant_id
    client_id       = azuread_application.deployer.client_id
    client_secret   = azuread_application_password.deployer[0].value
  })
}
