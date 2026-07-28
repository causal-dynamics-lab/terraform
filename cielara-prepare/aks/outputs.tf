output "service_principal_name" {
  description = "Per-deployment service principal the Cielara control plane authenticates as"
  value       = local.sp_name
}

output "client_id" {
  description = "App (client) id of the deployer service principal"
  value       = azuread_application.deployer.client_id
}

output "tenant_id" {
  description = "Entra tenant id"
  value       = data.azuread_client_config.current.tenant_id
}

output "creds_file" {
  description = "Path of the credentials handback file for the Cielara deploy form (written without client_secret when create_secret = false)"
  value       = var.creds_output_path
}

output "required_resource_providers" {
  description = "Resource providers the deploy needs registered on the subscription (see README for the registration command)"
  value       = local.required_resource_providers
}

output "state_storage_url" {
  description = "Where this module's Terraform state is kept (as supplied via state_storage_url — shown in the Cielara manage tab)"
  value       = var.state_storage_url
}

output "infra_version_storage_account" {
  description = "Storage account holding the infra-version marker (name is a hash of the client id — needed for the deployer read check in the README)"
  value       = azurerm_storage_account.infra_version.name
}
