#################################################
# Raw outputs
#
# The Cielara Enterprise setup adopts the network by NAME (resource group, VNet,
# and subnet names), so the handback carries names — not full ARM resource IDs.
#################################################
output "resource_group_name" {
  description = "Resource group the network lives in"
  value       = data.azurerm_resource_group.main.name
}

output "location" {
  description = "Azure region"
  value       = data.azurerm_resource_group.main.location
}

output "vnet_name" {
  description = "VNet name"
  value       = azurerm_virtual_network.main.name
}

output "system_subnet_name" {
  description = "Cielara Enterprise system node-pool subnet name"
  value       = azurerm_subnet.system.name
}

output "user_subnet_name" {
  description = "Cielara Enterprise user node-pool subnet name"
  value       = azurerm_subnet.user.name
}

output "appgw_subnet_name" {
  description = "Application Gateway (AGIC) subnet name"
  value       = azurerm_subnet.appgw.name
}

output "postgres_subnet_name" {
  description = "PostgreSQL Flexible Server delegated subnet name"
  value       = azurerm_subnet.postgres.name
}

# Consumed by the sibling private-endpoints module, NOT part of the Cielara
# handback — this subnet carries egress private endpoints to remote clusters.
output "pe_subnet_name" {
  description = "Subnet name for private endpoints (input to the private-endpoints module)"
  value       = azurerm_subnet.pe.name
}

#################################################
# Handback
#
# Single JSON blob to hand back to Cielara. `terraform output -raw handback`
# prints exactly this; paste it into your Cielara Enterprise setup.
#################################################
output "handback" {
  description = "JSON blob of network names to hand back to Cielara. Run: terraform output -raw handback"
  value = jsonencode({
    resource_group_name  = data.azurerm_resource_group.main.name
    location             = data.azurerm_resource_group.main.location
    vnet_name            = azurerm_virtual_network.main.name
    system_subnet_name   = azurerm_subnet.system.name
    user_subnet_name     = azurerm_subnet.user.name
    appgw_subnet_name    = azurerm_subnet.appgw.name
    postgres_subnet_name = azurerm_subnet.postgres.name
  })
}
