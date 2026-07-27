output "deployer_service_account_email" {
  description = "Service account the Cielara control plane deploys as"
  value       = google_service_account.deployer.email
}

output "key_file" {
  description = "Path of the deployer key file to upload in the Cielara deploy form (null when create_key = false)"
  value       = var.create_key ? var.key_output_path : null
}

output "state_storage_url" {
  description = "Where this module's Terraform state is kept (as supplied via state_storage_url — shown in the Cielara manage tab)"
  value       = var.state_storage_url
}
