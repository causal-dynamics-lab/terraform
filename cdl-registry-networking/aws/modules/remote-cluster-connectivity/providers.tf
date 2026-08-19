terraform {
  # remote_clusters validations reference var.region and var.vpc_cidr (Terraform >= 1.9).
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # Pinned to the same major the vpc module and Cielara data-plane are locked to
      # (~> 5.60) so peering / Route53 resource schemas match.
      version = "~> 5.60"
    }
  }
}
