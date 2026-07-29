output "endpoint" {
  description = "Azure AI Foundry endpoint. Paste into the data-plane web app (Admin > Models) as the Azure OpenAI endpoint."
  value       = azurerm_cognitive_account.foundry.endpoint
}

output "api_key" {
  description = "Primary API key for the AI Foundry account. Paste into the data-plane web app as the Azure OpenAI API key. Marked sensitive — read with: terraform output -raw api_key"
  value       = azurerm_cognitive_account.foundry.primary_access_key
  sensitive   = true
}

output "deployment_names" {
  description = "Created model deployment names (the data plane resolves models by these names)."
  value       = sort(keys(azurerm_cognitive_deployment.models))
}

output "resource_group_name" {
  description = "Resource group holding the AI Foundry account."
  value       = local.resource_group_name
}
