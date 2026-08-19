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
