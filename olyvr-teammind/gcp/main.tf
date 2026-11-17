# A TeamMind server on Google Cloud: one VM with a static address, a firewall, a service account that may read
# the named secrets and write to the backup bucket, and the A record when a zone is given.
# olyvr-teammind/README.md says how to run it.

terraform {
  required_version = ">= 1.9"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = var.project
  region  = var.region
  zone    = var.zone
}

variable "project" {
  description = "The Google Cloud project."
  type        = string
}

variable "region" {
  type    = string
  default = "asia-south1"
}

variable "zone" {
  type    = string
  default = "asia-south1-a"
}

locals {
  cloud       = "gcp"
  gcp_project = var.project
  azure_vault = ""
  public_ip   = google_compute_address.this.address
  vm_id       = google_compute_instance.this.id
  secrets     = compact([var.llm_key_secret, var.tls_secret, var.backup_remote_secret])
  # A gs:// bundle is read with the VM's service account: objectViewer on the folder teammind-stage.sh staged it in
  # (<dest> of <dest>/<track>-<version>), so the VM can be moved to another bundle there without an apply. A bundle
  # at the bucket's root gets its own folder only, never the whole bucket.
  artifacts_gs     = startswith(var.artifacts, "gs://") ? trimprefix(var.artifacts, "gs://") : ""
  artifacts_bucket = split("/", local.artifacts_gs)[0]
  artifacts_folder = trimprefix(trimprefix(local.artifacts_gs, local.artifacts_bucket), "/")
  artifacts_scope  = dirname(local.artifacts_folder) != "." ? dirname(local.artifacts_folder) : local.artifacts_folder
}

data "google_compute_image" "ubuntu" {
  family  = "ubuntu-2404-lts-amd64"
  project = "ubuntu-os-cloud"
}

resource "google_service_account" "this" {
  account_id   = var.name
  display_name = "TeamMind server ${var.name}"
}

# Read exactly the named secrets, nothing else in the project.
resource "google_secret_manager_secret_iam_member" "read" {
  for_each  = toset(local.secrets)
  secret_id = each.value
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.this.email}"
}

# Create objects in the backup bucket; objectCreator can neither list nor read them.
resource "google_storage_bucket_iam_member" "backup" {
  bucket = var.backup_bucket
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.this.email}"
}

data "google_storage_bucket" "artifacts" {
  count = local.artifacts_gs != "" ? 1 : 0
  name  = local.artifacts_bucket
}

# Read the bundle's folder and nothing else in its bucket.
resource "google_storage_bucket_iam_member" "artifacts" {
  count  = local.artifacts_gs != "" ? 1 : 0
  bucket = local.artifacts_bucket
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.this.email}"
  condition {
    title      = "${var.name}-bundle"
    expression = "resource.name.startsWith(\"projects/_/buckets/${local.artifacts_bucket}/objects/${local.artifacts_scope}/\")"
  }
  lifecycle {
    precondition {
      condition     = local.artifacts_folder != ""
      error_message = "A gs:// artifacts value names a folder in the bucket (gs://<bucket>/<folder>), as teammind-stage.sh prints it."
    }
    # Checked at plan time; otherwise the apply makes the service account and the network, then fails here.
    precondition {
      condition     = data.google_storage_bucket.artifacts[0].uniform_bucket_level_access
      error_message = "The bundle's bucket ${local.artifacts_bucket} needs uniform bucket-level access: the folder-only grant is an IAM condition."
    }
  }
}

# A network of its own: the project's "default" network carries default-allow-ssh (22 from anywhere) and
# default-allow-internal, which would make admin_cidrs and reader_cidrs meaningless. Ingress here is only
# what the rules below allow; egress stays open for the downloads.
resource "google_compute_network" "this" {
  name                    = "${var.name}-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "this" {
  name          = "${var.name}-subnet"
  network       = google_compute_network.this.id
  ip_cidr_range = local.subnet_cidr
  region        = var.region
}

resource "google_compute_address" "this" {
  name = var.name
}

resource "google_compute_firewall" "ssh" {
  name          = "${var.name}-ssh"
  network       = google_compute_network.this.name
  source_ranges = var.admin_cidrs
  target_tags   = [var.name]
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

resource "google_compute_firewall" "gate" {
  name          = "${var.name}-gate"
  network       = google_compute_network.this.name
  source_ranges = var.reader_cidrs
  target_tags   = [var.name]
  allow {
    protocol = "tcp"
    ports    = [tostring(var.gate_port)]
  }
}

# Port 80 is for the ACME challenge only; nothing listens there otherwise.
resource "google_compute_firewall" "acme" {
  count         = var.tls_mode == "letsencrypt" ? 1 : 0
  name          = "${var.name}-acme"
  network       = google_compute_network.this.name
  source_ranges = ["0.0.0.0/0"]
  target_tags   = [var.name]
  allow {
    protocol = "tcp"
    ports    = ["80"]
  }
}

resource "google_dns_record_set" "a" {
  count        = var.dns_zone != "" ? 1 : 0
  managed_zone = var.dns_zone
  name         = "${var.domain}."
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_address.this.address]
}

resource "google_compute_instance" "this" {
  name         = var.name
  machine_type = var.machine_type
  tags         = [var.name]

  boot_disk {
    initialize_params {
      image = data.google_compute_image.ubuntu.self_link
      size  = var.disk_gb
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.this.id
    access_config {
      nat_ip = google_compute_address.this.address
    }
  }

  service_account {
    email  = google_service_account.this.email
    scopes = ["cloud-platform"] # what the account may do is the IAM above
  }

  metadata = {
    user-data              = local.cloud_init
    block-project-ssh-keys = "TRUE" # only the key cloud-init installs
  }

  lifecycle {
    precondition {
      condition     = can(regex("^(gs|https)://", var.artifacts))
      error_message = "On Google Cloud, artifacts is a gs:// or https:// folder (s3:// is read on AWS only)."
    }
  }

  # The record must exist before the VM asks Let's Encrypt for a certificate.
  depends_on = [google_dns_record_set.a, google_secret_manager_secret_iam_member.read, google_storage_bucket_iam_member.backup, google_storage_bucket_iam_member.artifacts]
}

locals {
  backup_bucket = var.backup_bucket
}
