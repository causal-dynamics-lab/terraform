# Prepares a customer Azure subscription for a Cielara AKS deployment: the
# service principal the control plane authenticates as, plus its two
# subscription-scoped role assignments. Names and role sets must stay in
# lockstep with prepare-aks.sh (parity-tested in the Cielara control plane).

locals {
  # Per-deployment name: resetting one deployment's secret must never
  # invalidate another deployment's stored credential.
  sp_name = "cielara_aks_deployer_${var.cielara_client_id}"

  # Built-in role definition ids the deployer may assign/unassign — exactly
  # the roles the AKS deploy uses. Owner and the RBAC-granting roles are
  # excluded so the SP cannot escalate its own access.
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

  # Needed by the deploy but not managed here: Terraform cannot adopt an
  # existing provider registration. Registration command in the README.
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

  # A freshly created SP lags Entra replication; without this the assignment
  # fails on "principal not found". Create-time only — role assignments cannot
  # be updated, so adopted (imported) ones must not diff on it.
  skip_service_principal_aad_check = true

  lifecycle {
    ignore_changes = [skip_service_principal_aad_check]
  }
}

# The deploy creates role assignments of its own, which Contributor alone
# cannot; the ABAC condition restricts it to the allowlisted roles above.
resource "azurerm_role_assignment" "rbac_admin" {
  scope                = local.subscription_scope
  role_definition_name = "Role Based Access Control Administrator"
  principal_id         = azuread_service_principal.deployer.object_id
  # trimspace: the script writes the condition without a trailing newline, and
  # azurerm replaces the whole assignment on any condition change — the
  # heredoc's final newline alone would force destroy/recreate on adoption.
  condition         = trimspace(local.rbac_admin_condition)
  condition_version = "2.0"

  skip_service_principal_aad_check = true

  lifecycle {
    ignore_changes = [skip_service_principal_aad_check]
  }
}

# The handback: paste this file's contents in the Cielara deploy form. With
# create_secret = false (adoption) the secret is omitted — Azure cannot read
# an existing one back; your current secret keeps working. The secret also
# lives in the Terraform state — protect the state like a credential (see
# backend.tf).
resource "local_sensitive_file" "creds" {
  filename        = var.creds_output_path
  file_permission = "0600"
  content = jsonencode(merge(
    {
      subscription_id = var.subscription_id
      tenant_id       = data.azuread_client_config.current.tenant_id
      client_id       = azuread_application.deployer.client_id
    },
    var.create_secret ? { client_secret = azuread_application_password.deployer[0].value } : {},
  ))
}
