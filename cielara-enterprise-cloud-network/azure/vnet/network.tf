#################################################
# Locals — subnet layout
#
# Sized for the Cielara Enterprise workload, derived from var.vnet_cidr
# (default 10.2.0.0/20 = 4096 addresses). The cluster runs Azure CNI (pods draw
# IPs from the node subnets), so the user subnet is the largest:
#   user      <cidr>/22  (1024) user/workload node pools + pods
#   system    <cidr>/24  (256)  system node pool
#   appgw     <cidr>/26  (64)   Application Gateway (dedicated, AGIC)
#   postgres  <cidr>/28  (16)   PostgreSQL Flexible Server (delegated subnet)
#   pe        <cidr>/28  (16)   Private endpoints (egress to remote private clusters)
# For the default 10.2.0.0/20: user 10.2.4.0/22, system 10.2.0.0/24,
# appgw 10.2.1.0/26, postgres 10.2.1.64/28, pe 10.2.8.0/28; the rest of
# 10.2.8.0/21 is left free for growth.
#################################################
locals {
  user_subnet_cidr   = cidrsubnet(var.vnet_cidr, 2, 1)
  system_subnet_cidr = cidrsubnet(var.vnet_cidr, 4, 0)
  appgw_subnet_cidr  = cidrsubnet(var.vnet_cidr, 6, 4)
  pg_subnet_cidr     = cidrsubnet(var.vnet_cidr, 8, 20)
  pe_subnet_cidr     = cidrsubnet(var.vnet_cidr, 8, 128)

  # cielara-client-id is an optional ownership/audit tag — added only when a
  # client ID is provided. The network is handed back (and adopted) by name, so
  # the tag is a nice-to-have for identifying the network in your account, not a
  # functional input.
  tags = merge(
    {
      Project   = "cielara"
      ManagedBy = "cielara-enterprise-cloud-network"
    },
    var.cielara_client_id != "" ? { "cielara-client-id" = var.cielara_client_id } : {}
  )
}

#################################################
# Resource group — adopted, never created (Decision 2)
#
# This module provisions INTO an existing customer RG. The postcondition fails
# the plan loudly if the RG's Azure location disagrees with var.location, which
# drives placement of every resource here (mirrors the data-plane module's
# existing-RG postcondition).
#################################################
data "azurerm_resource_group" "main" {
  name = var.resource_group_name

  lifecycle {
    postcondition {
      condition     = self.location == var.location
      error_message = "resource_group_name is in location '${self.location}' but var.location is '${var.location}'; they must match."
    }
  }
}

#################################################
# VNet + subnets
#################################################
resource "azurerm_virtual_network" "main" {
  name                = "${var.name_prefix}-vnet"
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name
  address_space       = [var.vnet_cidr]
  tags                = local.tags
}

resource "azurerm_subnet" "system" {
  name                 = "system-subnet"
  resource_group_name  = data.azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [local.system_subnet_cidr]
  # Required so the Azure Files (NFS) storage account network rule can allow
  # this subnet and pods can mount the share (data-plane storage.tf).
  service_endpoints = ["Microsoft.Storage"]
}

resource "azurerm_subnet" "user" {
  name                 = "user-subnet"
  resource_group_name  = data.azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [local.user_subnet_cidr]
  service_endpoints    = ["Microsoft.Storage"]
}

# Dedicated Application Gateway subnet (AGIC's gateway can't share node subnets).
resource "azurerm_subnet" "appgw" {
  name                 = "appgw-subnet"
  resource_group_name  = data.azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [local.appgw_subnet_cidr]
}

# Delegated subnet for the Flexible Server (VNet integration requires a subnet
# delegated to Microsoft.DBforPostgreSQL/flexibleServers, used by nothing else).
resource "azurerm_subnet" "postgres" {
  name                 = "postgres-subnet"
  resource_group_name  = data.azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [local.pg_subnet_cidr]

  delegation {
    name = "fs"
    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# Subnet that hosts private endpoints created by the sibling private-endpoints
# module (egress from this VNet to remote private AKS clusters). Network policies
# MUST be disabled on a subnet that holds private endpoints. The subnet is owned
# here (single source of subnet truth); the private-endpoints module looks it up
# by name and never creates subnets of its own.
resource "azurerm_subnet" "pe" {
  name                              = "pe-subnet"
  resource_group_name               = data.azurerm_resource_group.main.name
  virtual_network_name              = azurerm_virtual_network.main.name
  address_prefixes                  = [local.pe_subnet_cidr]
  private_endpoint_network_policies = "Disabled"
}

#################################################
# NAT gateway — outbound internet for the private node subnets (Decision 1)
#
# The data-plane cluster sets outbound_type = "userAssignedNATGateway", which
# requires the node subnets to carry a NAT gateway. Owned here by the customer.
#################################################
resource "azurerm_public_ip" "nat" {
  name                = "${var.name_prefix}-nat-pip"
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_nat_gateway" "main" {
  name                = "${var.name_prefix}-nat"
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name
  sku_name            = "Standard"
  tags                = local.tags
}

resource "azurerm_nat_gateway_public_ip_association" "main" {
  nat_gateway_id       = azurerm_nat_gateway.main.id
  public_ip_address_id = azurerm_public_ip.nat.id
}

resource "azurerm_subnet_nat_gateway_association" "system" {
  subnet_id      = azurerm_subnet.system.id
  nat_gateway_id = azurerm_nat_gateway.main.id
}

resource "azurerm_subnet_nat_gateway_association" "user" {
  subnet_id      = azurerm_subnet.user.id
  nat_gateway_id = azurerm_nat_gateway.main.id
}

# No role assignments here: the Cielara deployment service principal is granted
# everything it needs (subscription-scope Contributor + RBAC Administrator) once
# by prepare-aks.sh, run by an IAM admin. That covers operating on this VNet
# (Postgres private-DNS vnet-link, control-plane / Application Gateway role
# assignments), so this module needs no IAM permissions.
