terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source = "hashicorp/google"
      # Pinned to the same major the Cielara data-plane module is locked to
      # (deployments/data-plane/gke) so network / subnetwork / Cloud NAT
      # resource schemas match what the deploy expects.
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region

  # Authentication uses Application Default Credentials (gcloud auth
  # application-default login) when credentials_file is empty, or the given
  # service-account key file. Run this with whatever identity owns the target
  # project — no Cielara credentials are involved.
  credentials = var.credentials_file != "" ? file(var.credentials_file) : null

  default_labels = local.owner_labels
}
