# Prepares your Azure subscription for a Cielara AKS deployment: the service
# principal the Cielara control plane deploys as, plus its two
# subscription-scoped role assignments. Every name below is load-bearing —
# do not rename.

locals {
  sp_name = "cielara_aks_deployer_${var.cielara_client_id}"

  # Built-in Azure role definition ids the deployer may assign.
  rbac_admin_role_guids = [
    "b24988ac-6180-42a0-ab88-20f7382dd24c", # Contributor
    "4d97b98b-1d4f-4787-a291-c67834d212e7", # Network Contributor
    "acdd72a7-3385-48ef-bd42-f606fba81ae7", # Reader
    "b86a8fe4-44ce-4948-aee5-eccb2c155cd7", # Key Vault Secrets Officer
    "4633458b-17de-408a-b874-0445c86b69e6", # Key Vault Secrets User
    "17d1049b-9a84-46fb-8f53-869881c3d3ab", # Storage Account Contributor
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

  # Not managed by this module — see the README for the registration command.
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
}

resource "azuread_service_principal" "deployer" {
  client_id = azuread_application.deployer.client_id
}

resource "azuread_application_password" "deployer" {
  count = var.create_secret ? 1 : 0

  application_id = azuread_application.deployer.id
  display_name   = "cielara-prepare"
}

resource "azurerm_role_assignment" "contributor" {
  scope                = local.subscription_scope
  role_definition_name = "Contributor"
  principal_id         = azuread_service_principal.deployer.object_id

  skip_service_principal_aad_check = true

  lifecycle {
    ignore_changes = [skip_service_principal_aad_check]
  }
}

resource "azurerm_role_assignment" "rbac_admin" {
  scope                = local.subscription_scope
  role_definition_name = "Role Based Access Control Administrator"
  principal_id         = azuread_service_principal.deployer.object_id
  condition            = trimspace(local.rbac_admin_condition)
  condition_version    = "2.0"

  skip_service_principal_aad_check = true

  lifecycle {
    ignore_changes = [skip_service_principal_aad_check]
  }
}

# Upload this file in the Cielara deploy form. With create_secret = false
# the secret is omitted — enter your existing one in the form manually. The
# secret also lives in the Terraform state — protect the state like a
# credential (see the README's Remote state section).
resource "local_sensitive_file" "creds" {
  filename        = var.creds_output_path
  file_permission = "0600"
  content = jsonencode(merge(
    {
      subscription_id = var.subscription_id
      tenant_id       = data.azuread_client_config.current.tenant_id
      client_id       = azuread_application.deployer.client_id
      storage_url     = var.state_storage_url
    },
    var.create_secret ? { client_secret = azuread_application_password.deployer[0].value } : {},
  ))
}
