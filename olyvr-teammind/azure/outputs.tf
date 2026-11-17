
output "teammind_url" {
  description = "What readers paste as the TeamMind address."
  value       = local.url
}

output "public_ip" {
  description = "For the A record when dns_zone is not managed here."
  value       = local.public_ip
}

output "ssh" {
  value = local.ssh
}

output "token_command" {
  description = "The reader token, made once by the bootstrap. Not a Terraform output: it would sit in the state file."
  value       = "${local.ssh} sudo cat /etc/olyvr/teammind-token"
}

output "status_command" {
  value = "${local.ssh} sudo teammind-check"
}

output "backup_bucket" {
  value = var.backup_bucket
}

output "signing_key_command" {
  description = "Prints this server's backup signing key as an allowed_signers line, for teammind-unpack.py. A replacement VM has a new one."
  value       = "${local.ssh} cat /var/lib/olyvr/backup-signer"
}
