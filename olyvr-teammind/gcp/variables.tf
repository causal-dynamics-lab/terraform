
variable "name" {
  description = "Prefix for every resource."
  type        = string
  default     = "teammind"
  validation {
    condition     = can(regex("^[A-Za-z0-9._:/@+=-]*$", var.name))
    error_message = "name is written into a file a root shell sources: letters, digits and . _ : / @ + = - only."
  }
}

variable "artifacts" {
  description = "A bundle folder made by operator/teammind-stage.sh (s3://bucket/prefix on AWS or gs://bucket/prefix on Google Cloud, read with the VM's identity, or an https:// URL): Olyvr's Linux AppImage, the Memory API release archive and the backup tools."
  type        = string
  validation {
    condition     = can(regex("^(s3|gs|https)://[A-Za-z0-9._:/@+=-]+[^/]$", var.artifacts))
    error_message = "artifacts is an s3://, gs:// or https:// folder without a trailing slash: letters, digits and . _ : / @ + = - only."
  }
}

variable "artifacts_sha256" {
  description = "SHA-256 of the bundle's SHA256SUMS, which pins every file in it (teammind-stage.sh prints it)."
  type        = string
  validation {
    condition     = can(regex("^[0-9a-f]{64}$", var.artifacts_sha256))
    error_message = "The 64-character SHA-256 of the bundle's SHA256SUMS."
  }
}

variable "memory_release" {
  description = "The memory API release tag the bundle holds (OLYVR_MEMORY_RELEASE), as the backend labels it; teammind-stage.sh prints it."
  type        = string
  validation {
    condition     = can(regex("^[A-Za-z0-9._:/@+=-]*$", var.memory_release))
    error_message = "memory_release is written into a file a root shell sources: letters, digits and . _ : / @ + = - only."
  }
}

variable "llm_base_url" {
  description = "OpenAI-compatible model endpoint the memory API reasons with (OLYVR_MODEL_BASE)."
  type        = string
  validation {
    condition     = can(regex("^[A-Za-z0-9._:/@+=-]*$", var.llm_base_url))
    error_message = "llm_base_url is written into a file a root shell sources: letters, digits and . _ : / @ + = - only."
  }
}

variable "llm_model" {
  description = "The model id at that endpoint (OLYVR_MODEL). The endpoint must list it, or the memory API starts without a model and the bootstrap fails."
  type        = string
  validation {
    condition     = can(regex("^[A-Za-z0-9._:/@+=-]*$", var.llm_model))
    error_message = "llm_model is written into a file a root shell sources: letters, digits and . _ : / @ + = - only."
  }
}

variable "llm_key_secret" {
  description = "Name of the secret holding the endpoint's API key (OLYVR_MODEL_KEY); empty for an endpoint without one."
  type        = string
  default     = ""
  validation {
    condition     = can(regex("^[A-Za-z0-9._:/@+=-]*$", var.llm_key_secret))
    error_message = "llm_key_secret is written into a file a root shell sources: letters, digits and . _ : / @ + = - only."
  }
}

variable "domain" {
  description = "DNS name for the gate; empty means readers use the IP address."
  type        = string
  default     = ""
  validation {
    condition     = can(regex("^[A-Za-z0-9._:/@+=-]*$", var.domain))
    error_message = "domain is written into a file a root shell sources: letters, digits and . _ : / @ + = - only."
  }
}

variable "dns_zone" {
  description = "The managed DNS zone to put the A record for domain in; empty means you add the record yourself."
  type        = string
  default     = ""
}

variable "tls_mode" {
  description = "letsencrypt (needs domain and acme_email; the A record from dns_zone, or made by hand first), provided (needs tls_secret) or self_signed (the gate makes its own certificate; readers pin it on first use)."
  type        = string
  default     = "self_signed"
  validation {
    condition     = contains(["letsencrypt", "provided", "self_signed"], var.tls_mode)
    error_message = "tls_mode is letsencrypt, provided or self_signed."
  }
  validation {
    condition     = var.tls_mode != "letsencrypt" || (var.domain != "" && var.acme_email != "")
    error_message = "letsencrypt needs domain and acme_email. The A record must point at the server before the VM asks for a certificate: give dns_zone so this apply makes it, or make it by hand (the bootstrap waits 15 minutes for it)."
  }
  validation {
    condition     = var.tls_mode != "provided" || var.tls_secret != ""
    error_message = "provided needs tls_secret: the name of a secret holding the private key and the certificate chain as PEM."
  }
}

variable "acme_email" {
  description = "Let's Encrypt account email."
  type        = string
  default     = ""
  validation {
    condition     = can(regex("^[A-Za-z0-9._:/@+=-]*$", var.acme_email))
    error_message = "acme_email is written into a file a root shell sources: letters, digits and . _ : / @ + = - only."
  }
}

variable "tls_secret" {
  description = "For tls_mode = provided: name of the secret holding the PEM private key followed by the certificate chain."
  type        = string
  default     = ""
  validation {
    condition     = can(regex("^[A-Za-z0-9._:/@+=-]*$", var.tls_secret))
    error_message = "tls_secret is written into a file a root shell sources: letters, digits and . _ : / @ + = - only."
  }
}

variable "gate_port" {
  description = "The port the gate listens on. 8013 as the dogfood server; 443 needs no port in the URL."
  type        = number
  default     = 8013
  validation {
    condition     = var.gate_port >= 1 && var.gate_port <= 65535 && floor(var.gate_port) == var.gate_port
    error_message = "A TCP port."
  }
}

variable "admin_cidrs" {
  description = "Who may reach ssh, and where the readiness check runs from. 0.0.0.0/0 or ::/0 is refused unless allow_public_admin is set."
  type        = list(string)
  validation {
    condition     = var.allow_public_admin || length([for c in var.admin_cidrs : c if contains(["0.0.0.0/0", "::/0"], c)]) == 0
    error_message = "admin_cidrs opens ssh to the whole internet. Name the ranges admins come from, or set allow_public_admin = true."
  }
}

variable "allow_public_admin" {
  description = "Accept 0.0.0.0/0 in admin_cidrs."
  type        = bool
  default     = false
}

variable "reader_cidrs" {
  description = "Who may reach the gate: the team's office and VPN ranges. No default. 0.0.0.0/0 or ::/0 is refused unless allow_public_readers is set."
  type        = list(string)
  validation {
    condition     = var.allow_public_readers || length([for c in var.reader_cidrs : c if contains(["0.0.0.0/0", "::/0"], c)]) == 0
    error_message = "reader_cidrs opens the gate to the whole internet. Name the ranges readers come from, or set allow_public_readers = true to accept that the reader token is the only protection."
  }
}

variable "allow_public_readers" {
  description = "Accept 0.0.0.0/0 in reader_cidrs. The gate is HTTPS and refuses anything without a valid reader token, but a public port is still a public port."
  type        = bool
  default     = false
}

variable "ssh_user" {
  description = "The admin login on the VM."
  type        = string
  default     = "ubuntu"
  validation {
    condition     = can(regex("^[A-Za-z0-9._:/@+=-]*$", var.ssh_user))
    error_message = "ssh_user is written into a file a root shell sources: letters, digits and . _ : / @ + = - only."
  }
}

variable "ssh_public_key" {
  description = "The admin's public key, put in that user's authorized_keys."
  type        = string
  validation {
    condition     = can(regex("^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+|sk-ssh-ed25519@openssh.com) [A-Za-z0-9+/=]+( [^\r\n'\"]*)?$", var.ssh_public_key))
    error_message = "One OpenSSH public key line: type, base64 key, optional comment."
  }
}

variable "ready_check" {
  description = "Wait for the bootstrap to finish before the apply succeeds (needs ssh from here). Off: the apply only provisions, and status_command tells readiness."
  type        = bool
  default     = true
}

variable "ready_timeout" {
  description = "Seconds the readiness check waits. The memory API's venv build is most of it."
  type        = number
  default     = 1800
}

variable "ready_private_key_file" {
  description = "Path, on the machine running Terraform, of the private key matching ssh_public_key. Empty: ssh-agent must hold it. Only the path is read."
  type        = string
  default     = ""
  validation {
    condition     = can(regex("^[A-Za-z0-9._/ @+~-]*$", var.ready_private_key_file))
    error_message = "A plain file path: letters, digits and . _ / @ + ~ - and spaces only."
  }
}

variable "backup_bucket" {
  description = "An existing bucket the nightly dumps are copied to (made by olyvr-teammind/<cloud>/backups). The VM may only write to it."
  type        = string
  validation {
    condition     = can(regex("^[A-Za-z0-9._:/@+=-]*$", var.backup_bucket))
    error_message = "backup_bucket is written into a file a root shell sources: letters, digits and . _ : / @ + = - only."
  }
}

variable "backup_targets" {
  description = "Where backup sets go, each <remote>:<path> (olyvr-teammind/docs/teammind-backup-recovery.md). `cloud` is this cloud's backup_bucket through the VM's identity; other remotes are rclone config sections in backup_remote_secret. Empty: cloud:<backup_bucket>/<hostname>."
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for t in var.backup_targets : can(regex("^[A-Za-z0-9_-]+:[A-Za-z0-9._/@+=-]*$", t))])
    error_message = "Each target is <remote>:<path>: letters, digits, _ and - in the remote name; letters, digits and . _ / @ + = - in the path."
  }
}

variable "backup_remote_secret" {
  description = "Name of the secret holding rclone config sections for targets outside this cloud's bucket (e.g. [aws_backup] type = s3 …, [nas_backup] type = sftp …). Write-only credentials; no section may be named cloud. Empty: none."
  type        = string
  default     = ""
  validation {
    condition     = can(regex("^[A-Za-z0-9._:/@+=-]*$", var.backup_remote_secret))
    error_message = "backup_remote_secret is written into a file a root shell sources: letters, digits and . _ : / @ + = - only."
  }
}

variable "backup_age_recipients" {
  description = "age public keys (age1…) every backup is encrypted to. Their private keys stay off the VM: one with the operator, one break-glass copy offline. Required: backups are never written unencrypted."
  type        = list(string)
  validation {
    condition     = length(var.backup_age_recipients) > 0 && alltrue([for r in var.backup_age_recipients : can(regex("^age1[a-z0-9]{58}$", r))])
    error_message = "At least one age recipient, each an age1… public key (age-keygen -y <key file>)."
  }
}

variable "backup_schedule" {
  description = "When backups run, as the five cron fields."
  type        = string
  default     = "15 3 * * *"
  validation {
    condition     = can(regex("^[0-9*/,-]+( [0-9*/,-]+){4}$", var.backup_schedule))
    error_message = "Five cron fields: digits and * / , - only."
  }
}

variable "backup_max_age_hours" {
  description = "teammind-check reports not ready when the last fully successful backup is older than this. 26 suits a nightly schedule."
  type        = number
  default     = 26
  validation {
    condition     = var.backup_max_age_hours >= 1 && floor(var.backup_max_age_hours) == var.backup_max_age_hours
    error_message = "A whole number of hours, at least 1."
  }
}

variable "backup_ping_url" {
  description = "A dead-man's switch (healthchecks.io, Better Stack, Cronitor, self-hosted): pinged after each successful backup, <url>/fail after a failed one. It alerts when pings stop, including when the VM is gone. Empty: none."
  type        = string
  default     = ""
  validation {
    condition     = can(regex("^(https://[A-Za-z0-9._:/@+=-]+)?$", var.backup_ping_url))
    error_message = "An https URL of letters, digits and . _ : / @ + = - only, or empty."
  }
}

variable "pull_ssh_public_key" {
  description = "A key that may pull the encrypted backup sets to a PC (olyvr-teammind/operator/teammind-pull.sh) and do nothing else. Its machine must be in admin_cidrs. Empty: no pull user."
  type        = string
  default     = ""
  validation {
    condition     = var.pull_ssh_public_key == "" || can(regex("^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+|sk-ssh-ed25519@openssh.com) [A-Za-z0-9+/=]+( [^\r\n'\"]*)?$", var.pull_ssh_public_key))
    error_message = "One OpenSSH public key line, or empty."
  }
}

variable "grafana_secret" {
  description = "Name of the secret holding the Grafana Cloud connection, lines of KEY=value: GRAFANA_METRICS_URL, GRAFANA_METRICS_USER, GRAFANA_LOGS_URL, GRAFANA_LOGS_USER and GRAFANA_TOKEN (an access policy token with metrics:write and logs:write). Set: the bootstrap installs Grafana Alloy, which sends the VM's metrics and logs there (docs/teammind-monitoring.md). Empty: no monitoring."
  type        = string
  default     = ""
  validation {
    condition     = can(regex("^[A-Za-z0-9._:/@+=-]*$", var.grafana_secret))
    error_message = "grafana_secret is written into a file a root shell sources: letters, digits and . _ : / @ + = - only."
  }
}

variable "machine_type" {
  description = "VM size: 2 vCPUs and 8 GB hold Olyvr, the memory API and a small PostgreSQL."
  type        = string
}

variable "disk_gb" {
  description = "Boot disk size."
  type        = number
  default     = 50
}

variable "vpc_cidr" {
  description = "The address range of the network made for the server (AWS: when vpc_id is empty). Its first /24 is the server's subnet."
  type        = string
  default     = "10.80.0.0/16"
  validation {
    condition     = can(cidrsubnet(var.vpc_cidr, 0, 0)) && tonumber(split("/", var.vpc_cidr)[1]) <= 24
    error_message = "An IPv4 CIDR block of /24 or larger, such as 10.80.0.0/16."
  }
}
