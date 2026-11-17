# The durable bucket a TeamMind server's nightly dumps go to. Its own root, so the server root's destroy never
# touches it (prevent_destroy refuses a destroy, it doesn't skip the resource). One per environment.

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
}

variable "project" {
  type = string
}

variable "name" {
  description = "Bucket name (global)."
  type        = string
}

variable "location" {
  type    = string
  default = "ASIA-SOUTH1"
}

resource "google_storage_bucket" "backups" {
  name                        = var.name
  location                    = var.location
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      age = 90
    }
    action {
      type = "Delete"
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

output "bucket" {
  value = google_storage_bucket.backups.name
}
