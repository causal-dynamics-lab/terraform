terraform {
  # >= 1.7: config-driven import blocks with for_each (used by the migration
  # path for script-prepared subscriptions).
  required_version = ">= 1.7"

  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
      # Same major as the Cielara data-plane AKS module so provider schemas
      # (and role-assignment behaviors) match what the deploy uses.
      version = "~> 4.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

provider "azuread" {}
