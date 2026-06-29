
terraform {
  required_version = ">= 1.5"

  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
      # Pinned to the same major the Cielara data-plane module is locked to
      # (4.77.0 in deployments/data-plane/aks/.terraform.lock.hcl) so subnet /
      # delegation / NAT resource schemas match what the deploy expects.
      version = "~> 4.77"
    }
  }
}

provider "azurerm" {
  features {}

  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id
  # client_id / client_secret are optional: set them for non-interactive SP
  # auth, or leave empty to use `az login` / ARM_* environment variables.
  client_id     = var.azure_client_id != "" ? var.azure_client_id : null
  client_secret = var.azure_client_secret != "" ? var.azure_client_secret : null
}
