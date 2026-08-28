output "role_arn" {
  description = "The handback — paste this Role ARN in the Cielara deploy form"
  value       = aws_iam_role.deployer.arn
}

output "role_name" {
  description = "Per-tenant cross-account role the Cielara control plane assumes"
  value       = aws_iam_role.deployer.name
}

output "jwt_signing_key_arn" {
  description = "AWS KMS key the data plane currently signs its JWTs with (the generation alias/cielara-jwt-signing targets)"
  value       = aws_kms_key.jwt_signing[local.jwt_current_generation].arn
}

output "jwt_signing_key_arns_by_generation" {
  description = "Every JWT signing key generation this account holds, newest = jwt_key_generation. Earlier generations stay enabled so a rotation is reversible; disable one to revoke it."
  value       = { for g, k in aws_kms_key.jwt_signing : g => k.arn }
}

output "creds_file" {
  description = "Path of the credentials handback file for the Cielara deploy form"
  value       = var.creds_output_path
}

output "state_storage_url" {
  description = "Where this module's Terraform state is kept (as supplied via state_storage_url — shown in the Cielara manage tab)"
  value       = var.state_storage_url
}

# Adoption probe results (populated only when migrate = true): the generated
# root main.tf keys its import blocks on these — import blocks are illegal
# inside a published child module, so adoption imports live in the caller.
output "probe_jwt_alias_exists" {
  value = local.jwt_alias_exists
}

output "probe_infra_version_marker_exists" {
  value = local.infra_version_marker_exists
}

output "probe_jwt_alias_target" {
  value = local.jwt_alias_target
}
