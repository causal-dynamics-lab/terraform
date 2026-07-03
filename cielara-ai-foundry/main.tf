locals {
  base_name = "${var.name_prefix}-${var.environment}"
  # Custom subdomain: lowercase alphanumerics + hyphens only, globally unique.
  subdomain           = lower(replace("${local.base_name}-foundry", "/[^a-z0-9-]/", ""))
  resource_group_name = var.create_resource_group ? azurerm_resource_group.foundry[0].name : data.azurerm_resource_group.existing[0].name
  resource_group_loc  = var.create_resource_group ? azurerm_resource_group.foundry[0].location : data.azurerm_resource_group.existing[0].location
}

resource "azurerm_resource_group" "foundry" {
  count    = var.create_resource_group ? 1 : 0
  name     = var.resource_group_name
  location = var.location

  tags = {
    managed-by  = "terraform"
    environment = var.environment
  }
}

data "azurerm_resource_group" "existing" {
  count = var.create_resource_group ? 0 : 1
  name  = var.resource_group_name
}

# Azure AI Foundry resource (Microsoft.CognitiveServices/accounts, kind
# AIServices). One account hosts all four model deployments; keys and the
# endpoint come from this account.
resource "azurerm_cognitive_account" "foundry" {
  name                = "${local.base_name}-foundry"
  location            = local.resource_group_loc
  resource_group_name = local.resource_group_name
  kind                = "AIServices"
  sku_name            = "S0"

  # Required for key/deployment access via a stable per-account endpoint
  # (https://<subdomain>.cognitiveservices.azure.com/) instead of the shared
  # regional one.
  custom_subdomain_name = local.subdomain

  public_network_access_enabled = true

  tags = {
    managed-by  = "terraform"
    environment = var.environment
  }
}

resource "azurerm_cognitive_deployment" "models" {
  for_each = var.model_deployments

  name                 = each.key
  cognitive_account_id = azurerm_cognitive_account.foundry.id

  model {
    format  = "OpenAI"
    name    = each.value.model_name
    version = each.value.version
  }

  sku {
    name     = each.value.sku_name
    capacity = each.value.capacity
  }
}
