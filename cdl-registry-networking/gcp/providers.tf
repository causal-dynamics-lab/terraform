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
