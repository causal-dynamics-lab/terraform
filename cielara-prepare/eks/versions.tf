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

# IAM is global, but the provider still requires a region — it is resolved
# from AWS_REGION or the active profile, same as prepare-eks.sh.
provider "aws" {}
