terraform {
  required_version = ">= 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

# IAM is global, but the infra-version bucket is regional, so the region this
# runs in is now part of the account's state, not an incidental detail of the
# operator's shell. var.region pins it; null falls back to AWS_REGION or the
# active profile, same as prepare-eks.sh.
provider "aws" {
  region = var.region
}
