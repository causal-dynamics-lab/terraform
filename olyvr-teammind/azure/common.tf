
locals {
  # The server's subnet: the first /24 of vpc_cidr.
  subnet_cidr = cidrsubnet(var.vpc_cidr, 24 - tonumber(split("/", var.vpc_cidr)[1]), 0)
  cloud_init = templatefile("${path.module}/../bootstrap/cloud-init.yaml.tftpl", {
    ssh_user              = var.ssh_user
    ssh_public_key        = var.ssh_public_key
    cloud                 = local.cloud
    gcp_project           = local.gcp_project
    azure_vault           = local.azure_vault
    artifacts             = var.artifacts
    artifacts_sha256      = var.artifacts_sha256
    memory_release        = var.memory_release
    llm_base_url          = var.llm_base_url
    llm_model             = var.llm_model
    llm_key_secret        = var.llm_key_secret
    tls_mode              = var.tls_mode
    domain                = var.domain
    acme_email            = var.acme_email
    tls_secret            = var.tls_secret
    gate_port             = var.gate_port
    backup_bucket         = local.backup_bucket
    public_ip             = local.public_ip
    backup_targets        = var.backup_targets
    backup_remote_secret  = var.backup_remote_secret
    backup_age_recipients = var.backup_age_recipients
    backup_schedule       = var.backup_schedule
    backup_max_age_hours  = var.backup_max_age_hours
    backup_ping_url       = var.backup_ping_url
    pull_ssh_public_key   = var.pull_ssh_public_key
    # teammind-backup, teammind-restore and teammind-check-sftp are installed from the bundle
    # (bootstrap.sh, step 9).
    scripts = {
      for f in ["bootstrap.sh", "olyvr.service", "olyvr-memory.logrotate", "certbot-deploy.sh",
      "teammind-check.sh", "aws-cli.pub.asc"] :
      f => file("${path.module}/../bootstrap/${f}")
    }
  })
  url         = "https://${var.domain != "" ? var.domain : local.public_ip}:${var.gate_port}"
  ssh         = "ssh ${var.ssh_user}@${local.public_ip}"
  known_hosts = "${path.module}/.terraform/teammind-known-hosts"
}

# The readiness check: replaced with the VM, so a replacement VM is checked too and its new host key is
# taken into a fresh known-hosts file.
resource "terraform_data" "ready" {
  count            = var.ready_check ? 1 : 0
  triggers_replace = [local.vm_id]
  provisioner "local-exec" {
    # The key path goes through the environment, not the command line, so no path can reach the shell unquoted.
    command = "${path.module}/../bootstrap/wait-ready.sh ${local.public_ip} ${var.ssh_user} ${var.ready_timeout} ${local.known_hosts}"
    environment = {
      READY_PRIVATE_KEY_FILE = var.ready_private_key_file
    }
  }
}
