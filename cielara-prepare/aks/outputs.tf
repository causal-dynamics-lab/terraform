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
  description = "Path of the credentials handback file to upload in the Cielara deploy form (null when create_secret = false)"
  value       = var.create_secret ? var.creds_output_path : null
}

output "required_resource_providers" {
  description = "Resource providers the deploy needs registered on the subscription (see README for the registration command)"
  value       = local.required_resource_providers
}
