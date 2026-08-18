# State backend — READ THIS BEFORE APPLYING.
#
# The Terraform state for this module contains the deployer service account's
# PRIVATE KEY (when create_key = true). Treat the state like a password:
#
#   - Never send it to Cielara. Cielara never needs your state; if it is lost,
#     re-adopt the existing resources with `migrate = true` instead.
#   - Local state (the default) is acceptable for a single operator. If more
#     than one person will run this module, or you want the state to survive
#     the machine, use a remote backend in YOUR OWN cloud account.
#
# To use a remote backend, uncomment exactly one block below and run
# `terraform init` (add `-migrate-state` if you applied with local state
# first). Buckets are examples — any bucket/container you own works.
#
# terraform {
#   backend "gcs" {
#     bucket = "<your-terraform-state-bucket>"
#     prefix = "cielara-prepare/gcp"
#   }
# }
#
# terraform {
#   backend "s3" {
#     bucket = "<your-terraform-state-bucket>"
#     key    = "cielara-prepare/gcp/terraform.tfstate"
#     region = "<bucket-region>"
#   }
# }
#
# terraform {
#   backend "azurerm" {
#     resource_group_name  = "<your-rg>"
#     storage_account_name = "<your-storage-account>"
#     container_name       = "tfstate"
#     key                  = "cielara-prepare-gcp.tfstate"
#   }
# }
