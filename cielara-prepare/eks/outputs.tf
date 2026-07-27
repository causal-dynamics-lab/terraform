output "role_arn" {
  description = "The handback — paste this Role ARN in the Cielara deploy form"
  value       = aws_iam_role.deployer.arn
}

output "role_name" {
  description = "Per-tenant cross-account role the Cielara control plane assumes"
  value       = aws_iam_role.deployer.name
}

output "jwt_signing_key_arn" {
  description = "AWS KMS key the data plane signs its JWTs with (dormant until the AWS KMS signer ships)"
  value       = aws_kms_key.jwt_signing.arn
}

output "creds_file" {
  description = "Path of the credentials handback file for the Cielara deploy form"
  value       = var.creds_output_path
}

output "state_storage_url" {
  description = "Where this module's Terraform state is kept (as supplied via state_storage_url — shown in the Cielara manage tab)"
  value       = var.state_storage_url
}
