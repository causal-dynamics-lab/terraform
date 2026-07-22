output "role_arn" {
  description = "The handback — paste this Role ARN in the Cielara deploy form"
  value       = aws_iam_role.deployer.arn
}

output "role_name" {
  description = "Per-tenant cross-account role the Cielara control plane assumes"
  value       = aws_iam_role.deployer.name
}
