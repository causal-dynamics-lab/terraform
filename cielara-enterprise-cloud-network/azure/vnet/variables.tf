#################################################
# Azure auth (customer-supplied)
#################################################
variable "subscription_id" {
  description = "Azure subscription ID the network is created in"
  type        = string
}

variable "tenant_id" {
  description = "Azure AD (Entra) tenant ID"
  type        = string
}

variable "azure_client_id" {
  description = "Optional service-principal app (client) ID. Leave empty to use az login / ARM_* env vars."
  type        = string
  default     = ""
}

variable "azure_client_secret" {
  description = "Optional service-principal client secret. Leave empty to use az login / ARM_* env vars."
  type        = string
  default     = ""
  sensitive   = true
}

#################################################
# Resource group (customer brings their own — adopted, never created)
#################################################
variable "resource_group_name" {
  description = "Existing resource group the network is provisioned into. This module never creates an RG; it adopts the one you name here."
  type        = string
}

variable "location" {
  # eastus2 mirrors the Cielara Enterprise default region. Whatever you choose
  # MUST equal the adopted resource group's location (enforced by a postcondition).
  description = "Azure region (e.g. eastus2). Must match the resource group's location."
  type        = string
  default     = "eastus2"
}

#################################################
# Naming + ownership tag
#################################################
variable "name_prefix" {
  description = "Prefix for human-readable resource names (VNet, NAT). Subnets are referenced by ID downstream, so names are cosmetic."
  type        = string
  default     = "cielara"
}

variable "cielara_client_id" {
  description = "Optional Cielara client ID. When set, it's stamped into the cielara-client-id tag for identifying the network in your account. Not required — the network is handed back and adopted by name."
  type        = string
  default     = ""
}

#################################################
# Network sizing
#################################################
variable "vnet_cidr" {
  # A /20 (4096 addresses) comfortably holds the four subnets (user /22, system
  # /24, appgw /26, postgres /28) with room to grow — far less of your internal
  # address space than the old /16. The Cielara Enterprise cluster uses service
  # CIDR 10.1.0.0/16, so the VNet must stay disjoint from it. 10.2.0.0/20 is the
  # safe default.
  description = "CIDR for the Cielara Enterprise VNet (a /20 is recommended). Must not overlap the Kubernetes service CIDR 10.1.0.0/16."
  type        = string
  default     = "10.2.0.0/20"

  validation {
    # Guardrail: the VNet must not overlap the Kubernetes service CIDR
    # 10.1.0.0/16. A base-address-equality check is not enough — 10.1.16.0/20 or
    # 10.0.0.0/8 overlap without their base being 10.1.0.0. So compare the two
    # ranges as integers. The VNet's network base (cidrhost(cidr, 0)) is packed
    # to a uint32 via hex; its end is base + 2^(32-prefix) - 1. The service CIDR
    # 10.1.0.0/16 spans [167837696, 167903231]. Ranges overlap iff
    # base <= service_end AND vnet_end >= service_start.
    condition = !(
      parseint(join("", [for o in split(".", cidrhost(var.vnet_cidr, 0)) : format("%02x", tonumber(o))]), 16) <= 167903231 &&
      parseint(join("", [for o in split(".", cidrhost(var.vnet_cidr, 0)) : format("%02x", tonumber(o))]), 16) + pow(2, 32 - tonumber(split("/", var.vnet_cidr)[1])) - 1 >= 167837696
    )
    error_message = "vnet_cidr overlaps the Kubernetes service CIDR 10.1.0.0/16. Use a disjoint range (default 10.2.0.0/20)."
  }

  validation {
    # The subnet split (user /22, system /24, appgw /26, postgres /28) is carved
    # at fixed offsets from the base, so the block must be /20 or larger. A
    # smaller prefix shrinks the derived subnets below Azure minimums (the
    # delegated Postgres subnet needs at least a /28) or fails the plan outright
    # (a /25+ base pushes the postgres subnet past /32). Bigger blocks (/19, /18,
    # …) are fine — the subnets just scale up.
    condition     = tonumber(split("/", var.vnet_cidr)[1]) <= 20
    error_message = "vnet_cidr must be /20 or larger (e.g. /20, /19, /18). A smaller block cannot fit the required subnets — the delegated Postgres subnet needs at least a /28."
  }
}
