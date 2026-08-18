terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # Pinned to the same major the Cielara data-plane module is locked to
      # (deployments/data-plane/eks) so subnet / NAT / tagging resource schemas
      # match what the deploy expects.
      version = "~> 5.60"
    }
  }
}
