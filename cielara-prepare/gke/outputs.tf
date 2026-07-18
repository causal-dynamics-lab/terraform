output "deployer_service_account_email" {
  description = "Service account the Cielara control plane deploys as"
  value       = google_service_account.deployer.email
}

output "node_service_account_email" {
  description = "Service account the GKE node pool runs as"
  value       = google_service_account.node.email
}

output "app_service_account_email" {
  description = "Service account the Cielara app assumes via Workload Identity"
  value       = google_service_account.app.email
}

output "key_file" {
  description = "Path of the deployer key file to upload in the Cielara deploy form (null when create_key = false)"
  value       = var.create_key ? var.key_output_path : null
}
