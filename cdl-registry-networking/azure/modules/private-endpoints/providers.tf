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
