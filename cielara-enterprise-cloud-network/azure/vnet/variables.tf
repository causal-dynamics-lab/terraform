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
    # Guardrail: the VNet network base must not equal 10.1.0.0 (the service
    # CIDR). cidrhost(<cidr>, 0) is the network address; comparing it to
    # 10.1.0.0 catches the overlap the default 10.2.0.0/20 was chosen to avoid.
    condition     = cidrhost(var.vnet_cidr, 0) != "10.1.0.0"
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
