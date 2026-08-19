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

output "jwt_signer_service_account_email" {
  description = "Service account admin-backend assumes (Workload Identity) to sign JWTs with the Cloud KMS key"
  value       = google_service_account.jwt_signer.email
}

output "jwt_signing_key_id" {
  description = "Cloud KMS key the data plane signs its JWTs with"
  value       = google_kms_crypto_key.jwt_signing.id
}

output "key_file" {
  description = "Path of the deployer key file to upload in the Cielara deploy form (null when create_key = false)"
  value       = var.create_key ? var.key_output_path : null
}

output "state_storage_url" {
  description = "Where this module's Terraform state is kept (as supplied via state_storage_url — shown in the Cielara manage tab)"
  value       = var.state_storage_url
}

output "jwt_key_generation" {
  description = "JWT signing key generation this state holds. Rotation = increment + re-apply; earlier crypto-key versions stay enabled so a rollback is a decrement."
  value       = var.jwt_key_generation
}
