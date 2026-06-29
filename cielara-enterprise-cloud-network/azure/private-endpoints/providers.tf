
terraform {
  required_version = ">= 1.5"

  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
      # Same major the vnet module and Cielara data-plane are locked to (~> 4.77)
      # so private-endpoint / private-dns resource schemas match.
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
