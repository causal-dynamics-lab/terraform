
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

provider "aws" {
  region = var.region

  # Authentication uses the standard AWS credential chain: environment
  # variables (AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN),
  # a shared-credentials profile (AWS_PROFILE), or SSO. No credentials are
  # declared here — run this with whatever identity owns the target account.
}
