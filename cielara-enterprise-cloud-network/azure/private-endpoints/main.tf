#################################################
# Locals
#################################################
locals {
  tags = merge(
    {
      Project   = "cielara"
      ManagedBy = "cielara-enterprise-cloud-network"
    },
    var.cielara_client_id != "" ? { "cielara-client-id" = var.cielara_client_id } : {}
  )

  # Parse each remote FQDN into the private DNS zone it belongs to and the
  # A-record (host) name within that zone. For
  #   myaks-abc123.0123-...-89ef.privatelink.eastus2.azmk8s.io
  # zone   = privatelink.eastus2.azmk8s.io   (labels from "privatelink" onward)
  # record = myaks-abc123.0123-...-89ef      (labels before "privatelink")
  clusters = {
    for k, c in var.remote_clusters : k => {
      pls_id      = c.pls_id
      fqdn        = c.fqdn
      zone_name   = join(".", slice(split(".", c.fqdn), index(split(".", c.fqdn), "privatelink"), length(split(".", c.fqdn))))
      record_name = join(".", slice(split(".", c.fqdn), 0, index(split(".", c.fqdn), "privatelink")))
    }
  }

  # Distinct DNS zones — clusters in the same region share one zone, so the zone
  # + vnet-link are created once per region, not once per cluster.
  zones = toset([for k, c in local.clusters : c.zone_name])
}

#################################################
# Network handles — adopted by name, never created
#################################################
data "azurerm_resource_group" "main" {
  name = var.resource_group_name
}

data "azurerm_virtual_network" "main" {
  name                = var.vnet_name
  resource_group_name = var.resource_group_name
}

data "azurerm_subnet" "pe" {
  name                 = var.pe_subnet_name
  virtual_network_name = var.vnet_name
  resource_group_name  = var.resource_group_name
}

#################################################
# Private endpoints — one per remote cluster
#
# is_manual_connection = true: the remote cluster's owner must APPROVE the
# connection out of band before traffic flows (it starts "Pending"):
#   az network private-endpoint-connection approve --id <remote PLS connection id>
#################################################
resource "azurerm_private_endpoint" "remote_aks" {
  for_each = local.clusters

  name                = "${var.name_prefix}-pe-${each.key}"
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name
  subnet_id           = data.azurerm_subnet.pe.id
  tags                = local.tags

  private_service_connection {
    name                           = "${var.name_prefix}-psc-${each.key}"
    is_manual_connection           = true
    private_connection_resource_id = each.value.pls_id
    request_message                = var.request_message
  }
}

#################################################
# Private DNS — one zone per region, shared across clusters in that region
#################################################
resource "azurerm_private_dns_zone" "remote_aks" {
  for_each = local.zones

  name                = each.value
  resource_group_name = data.azurerm_resource_group.main.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "remote_aks" {
  for_each = local.zones

  name                  = "${var.name_prefix}-link-${replace(each.value, ".", "-")}"
  resource_group_name   = data.azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.remote_aks[each.value].name
  virtual_network_id    = data.azurerm_virtual_network.main.id
  registration_enabled  = false
  tags                  = local.tags
}

# One A record per cluster: the remote API host → this endpoint's private IP, so
# pods in this VNet resolve the remote cluster's API FQDN to the local PE.
resource "azurerm_private_dns_a_record" "remote_aks" {
  for_each = local.clusters

  name                = each.value.record_name
  zone_name           = azurerm_private_dns_zone.remote_aks[each.value.zone_name].name
  resource_group_name = data.azurerm_resource_group.main.name
  ttl                 = 300
  records             = [azurerm_private_endpoint.remote_aks[each.key].private_service_connection[0].private_ip_address]
}
