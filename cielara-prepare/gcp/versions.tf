terraform {
  # >= 1.7 matches the sibling prepare modules (config-driven import blocks);
  # the GCP VM flavor has no migration path but keeps the same floor.
  required_version = ">= 1.7"

  required_providers {
    google = {
      source = "hashicorp/google"
      # Same major as the Cielara data-plane Terraform so provider schemas
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
