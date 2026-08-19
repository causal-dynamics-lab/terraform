# Reads the infra-version object back as the deployer itself: the provider
# authenticates with the handback key, so a successful read proves the
# Cielara control plane's identity can reach the object.
#
#   terraform init
#   terraform apply
#
# A just-granted bucket IAM binding can take a minute or two to propagate —
# a 403 right after the prepare apply usually just means retry.

terraform {
  required_version = ">= 1.7"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

variable "key_path" {
  description = "Path to the deployer key written by the prepare module"
  type        = string
  default     = "../cielara-key.json"
}

locals {
  project_id = jsondecode(file(var.key_path)).project_id
}

provider "google" {
  credentials = file(var.key_path)
  project     = local.project_id
}

data "google_storage_bucket_object_content" "infra_version" {
  bucket = "cielara-infra-version-${local.project_id}"
  name   = "version.json"
}

output "version_json" {
  value = data.google_storage_bucket_object_content.infra_version.content
}
