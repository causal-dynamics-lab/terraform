terraform {
  # >= 1.7: config-driven import blocks with for_each (used by the migration
  # path for script-prepared projects).
  required_version = ">= 1.7"

  required_providers {
    google = {
      source = "hashicorp/google"
      # Same major as the Cielara data-plane GKE module so provider schemas
      # (and IAM resource behaviors) match what the deploy uses.
      version = "~> 5.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

provider "google" {
  project = var.project_id
}
