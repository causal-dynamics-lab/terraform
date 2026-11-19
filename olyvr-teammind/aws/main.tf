# A TeamMind server on AWS: one EC2 instance with an Elastic IP in a VPC of its own (or one you name), a security group, an instance profile that may
# read the named secrets and put objects in the backup bucket, and the Route 53 record when a zone is given.
# olyvr-teammind/README.md says how to run it.

terraform {
  required_version = ">= 1.11"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  type    = string
  default = "ap-south-1"
}

variable "vpc_id" {
  description = "An existing VPC to use; empty makes one for this server, <name>-vpc, with one public subnet."
  type        = string
  default     = ""
}

variable "subnet_id" {
  description = "A public subnet of vpc_id (one routed to an internet gateway); empty picks one of its subnets."
  type        = string
  default     = ""
  validation {
    condition     = var.subnet_id == "" || var.vpc_id != ""
    error_message = "subnet_id names a subnet of vpc_id: set vpc_id too, or leave both empty for a VPC of the server's own."
  }
}

variable "availability_zone" {
  description = "Where the made subnet goes, such as us-east-1a; empty picks the region's first available zone."
  type        = string
  default     = ""
}

variable "egress_extra_tcp_ports" {
  description = "TCP ports the server may dial on the internet besides 443, 80 and llm_base_url's port: e.g. 22 for an SFTP backup target in backup_remote_secret."
  type        = list(number)
  default     = []
  validation {
    condition     = alltrue([for p in var.egress_extra_tcp_ports : p >= 1 && p <= 65535 && floor(p) == p])
    error_message = "egress_extra_tcp_ports holds TCP port numbers, 1 to 65535."
  }
}

locals {
  # The LLM endpoint's explicit port, if llm_base_url names one.
  llm_port         = try(tonumber(regex("^[a-z]+://[^/:@]+:([0-9]+)", var.llm_base_url)[0]), null)
  egress_tcp_ports = toset(compact(concat(["443", "80"], [for p in concat(local.llm_port == null ? [] : [local.llm_port], var.egress_extra_tcp_ports) : tostring(p)])))
}

locals {
  cloud       = "aws"
  gcp_project = ""
  azure_vault = ""
  public_ip   = aws_eip.this.public_ip
  vm_id       = aws_instance.this.id
  own_vpc     = var.vpc_id == ""
  vpc_id      = local.own_vpc ? aws_vpc.this[0].id : var.vpc_id
  subnet_id   = local.own_vpc ? aws_subnet.this[0].id : (var.subnet_id != "" ? var.subnet_id : data.aws_subnets.given[0].ids[0])
  secrets     = compact([var.llm_key_secret, var.tls_secret, var.backup_remote_secret, var.grafana_secret])
  # An s3:// bundle is read with the VM's identity: GetObject on the folder teammind-stage.sh staged it in
  # (<dest>/<track>-<version>), so the VM can be moved to another bundle there without an apply.
  artifacts_s3 = startswith(var.artifacts, "s3://") ? dirname(trimprefix(var.artifacts, "s3://")) : ""
}

# The server's own network when no VPC is given: a VPC, one public subnet routed to an internet gateway, nothing
# else. Many accounts have no default VPC in a region (dev2's us-east-1), and a shared VPC's other rules don't apply
# to this server. The security group below is the only way in.
data "aws_availability_zones" "available" {
  count = local.own_vpc && var.availability_zone == "" ? 1 : 0
  state = "available"
}

resource "aws_vpc" "this" {
  count                = local.own_vpc ? 1 : 0
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.name}-vpc" }
}

resource "aws_internet_gateway" "this" {
  count  = local.own_vpc ? 1 : 0
  vpc_id = aws_vpc.this[0].id
  tags   = { Name = "${var.name}-igw" }
}

resource "aws_subnet" "this" {
  count             = local.own_vpc ? 1 : 0
  vpc_id            = aws_vpc.this[0].id
  cidr_block        = local.subnet_cidr
  availability_zone = var.availability_zone != "" ? var.availability_zone : data.aws_availability_zones.available[0].names[0]
  # The server's address is the Elastic IP; nothing else launched here gets a public one by default.
  map_public_ip_on_launch = false
  tags                    = { Name = "${var.name}-public" }
}

resource "aws_route_table" "this" {
  count  = local.own_vpc ? 1 : 0
  vpc_id = aws_vpc.this[0].id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this[0].id
  }
  tags = { Name = "${var.name}-public" }
}

resource "aws_route_table_association" "this" {
  count          = local.own_vpc ? 1 : 0
  subnet_id      = aws_subnet.this[0].id
  route_table_id = aws_route_table.this[0].id
}

# A subnet of the given VPC, when none is named.
data "aws_subnets" "given" {
  count = !local.own_vpc && var.subnet_id == "" ? 1 : 0
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }
}

data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

data "aws_secretsmanager_secret" "named" {
  for_each = toset(local.secrets)
  name     = each.value
}

data "aws_s3_bucket" "backup" {
  bucket = var.backup_bucket
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "vm" {
  dynamic "statement" {
    for_each = length(local.secrets) > 0 ? [1] : []
    content {
      sid       = "ReadNamedSecrets"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = [for s in data.aws_secretsmanager_secret.named : s.arn]
    }
  }
  dynamic "statement" {
    for_each = local.artifacts_s3 != "" ? [1] : []
    content {
      sid       = "ReadBundle"
      actions   = ["s3:GetObject"]
      resources = ["arn:aws:s3:::${local.artifacts_s3}/*"]
    }
  }
  statement {
    sid       = "WriteBackups"
    actions   = ["s3:PutObject"]
    resources = ["${data.aws_s3_bucket.backup.arn}/*"]
  }
}

resource "aws_iam_role" "vm" {
  name               = var.name
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy" "vm" {
  name   = var.name
  role   = aws_iam_role.vm.id
  policy = data.aws_iam_policy_document.vm.json
}

resource "aws_iam_instance_profile" "vm" {
  name = var.name
  role = aws_iam_role.vm.name
}

resource "aws_security_group" "this" {
  name   = var.name
  vpc_id = local.vpc_id

  ingress {
    description = "ssh"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.admin_cidrs
  }
  ingress {
    description = "the gate"
    from_port   = var.gate_port
    to_port     = var.gate_port
    protocol    = "tcp"
    cidr_blocks = var.reader_cidrs
  }
  dynamic "ingress" {
    for_each = var.tls_mode == "letsencrypt" ? [1] : []
    content {
      description = "ACME challenge only"
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }
  # Egress narrowed to what the server dials (DCF-85). It does need the internet, so the
  # destination stays 0.0.0.0/0 but only on these TCP ports:
  #   443: S3 (bundle, backups), Secrets Manager, awscli/uv/rclone/Alloy downloads, the LLM endpoint
  #        over https, Grafana Cloud, the backup ping URL, Let's Encrypt ACME
  #   80:  apt (Ubuntu archive mirrors are plain http; packages are signature-checked)
  #   the LLM endpoint's own port when llm_base_url names one (e.g. :11434), and egress_extra_tcp_ports
  #   for anything else (an SFTP backup target on 22, say).
  # DNS (VPC resolver), NTP (169.254.169.123) and instance metadata are not filtered by security groups.
  dynamic "egress" {
    for_each = local.egress_tcp_ports
    content {
      description = "tcp ${egress.value} to the internet"
      from_port   = egress.value
      to_port     = egress.value
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }
}

resource "aws_eip" "this" {
  domain = "vpc"
  # An address in a VPC needs its internet gateway attached first.
  depends_on = [aws_internet_gateway.this]
  tags       = { Name = var.name }
}

data "aws_route53_zone" "this" {
  count = var.dns_zone != "" ? 1 : 0
  name  = var.dns_zone
}

resource "aws_route53_record" "a" {
  count   = var.dns_zone != "" ? 1 : 0
  zone_id = data.aws_route53_zone.this[0].zone_id
  name    = var.domain
  type    = "A"
  ttl     = 300
  records = [aws_eip.this.public_ip]
}

# The VM's network interface, made before the VM with the Elastic IP already on it: the subnet hands out no public
# addresses, and cloud-init's first download runs within seconds of boot, before an association made after the VM
# would land. Launched on this interface, the VM has its public address from its first packet.
resource "aws_network_interface" "this" {
  subnet_id       = local.subnet_id
  security_groups = [aws_security_group.this.id]
  tags            = { Name = var.name }
}

resource "aws_eip_association" "this" {
  allocation_id        = aws_eip.this.id
  network_interface_id = aws_network_interface.this.id
}

resource "aws_instance" "this" {
  ami                  = data.aws_ssm_parameter.ubuntu.value
  instance_type        = var.machine_type
  iam_instance_profile = aws_iam_instance_profile.vm.name
  network_interface {
    network_interface_id = aws_network_interface.this.id
    device_index         = 0
  }
  # Raw user data is capped at 16 KiB; gzipped, the cloud-init file with the scripts is well under.
  user_data_base64 = base64gzip(local.cloud_init)
  # Cloud-init reads user data once; a change would only stop and start the VM. Rerun the bootstrap or -replace.
  lifecycle {
    ignore_changes = [user_data_base64]
    precondition {
      condition     = can(regex("^(s3|https)://", var.artifacts))
      error_message = "On AWS, artifacts is an s3:// or https:// folder (gs:// is read on Google Cloud only)."
    }
  }

  root_block_device {
    volume_size = var.disk_gb
    volume_type = "gp3"
    encrypted   = true
  }

  metadata_options {
    http_tokens = "required" # IMDSv2
  }

  tags = { Name = var.name }

  # The VM fetches packages and the bundle at boot: its route out and its public address must exist first.
  depends_on = [aws_route53_record.a, aws_iam_role_policy.vm, aws_route_table_association.this, aws_eip_association.this]
}


locals {
  backup_bucket = var.backup_bucket
}
