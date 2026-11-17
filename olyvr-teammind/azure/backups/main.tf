# The durable storage account and container a TeamMind server's nightly dumps go to. Its own root, so the
# server root's destroy never touches it (prevent_destroy refuses a destroy, it doesn't skip the resource).

terraform {
  required_version = ">= 1.9"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

variable "subscription_id" {
  type = string
}

variable "resource_group" {
  description = "An existing resource group for the storage account."
  type        = string
}

variable "location" {
  type    = string
  default = "centralindia"
}

variable "storage_account" {
  description = "Storage account name (global, 3-24 lowercase letters and digits)."
  type        = string
}

variable "name" {
  description = "Container name."
  type        = string
  default     = "teammind-backups"
}

resource "azurerm_storage_account" "backups" {
  name                            = var.storage_account
  resource_group_name             = var.resource_group
  location                        = var.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  allow_nested_items_to_be_public = false
  min_tls_version                 = "TLS1_2"

  blob_properties {
    versioning_enabled = true
    delete_retention_policy {
      days = 90
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_storage_container" "backups" {
  name                  = var.name
  storage_account_id    = azurerm_storage_account.backups.id
  container_access_type = "private"
  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_storage_management_policy" "expire" {
  storage_account_id = azurerm_storage_account.backups.id
  rule {
    name    = "expire"
    enabled = true
    filters {
      blob_types = ["blockBlob"]
    }
    actions {
      base_blob {
        delete_after_days_since_modification_greater_than = 90
      }
      version {
        delete_after_days_since_creation = 90
      }
    }
  }
}

output "storage_account" {
  value = azurerm_storage_account.backups.name
}

output "container" {
  value = azurerm_storage_container.backups.name
}
