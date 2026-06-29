#################################################
# Azure auth (customer-supplied) — mirrors the vnet module
#################################################
variable "subscription_id" {
  description = "Azure subscription ID (must be the one the vnet module ran in)"
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
# Network handles — adopted from the vnet module (by name)
#
# This module creates NO network of its own. It looks the VNet, resource group,
# and pe-subnet up by name and provisions private endpoints into the existing
# pe-subnet. Copy these from the vnet module's outputs.
#################################################
variable "resource_group_name" {
  description = "Resource group the vnet module provisioned into (vnet output: resource_group_name)"
  type        = string
}

variable "vnet_name" {
  description = "VNet name (vnet output: vnet_name)"
  type        = string
}

variable "pe_subnet_name" {
  description = "Private-endpoint subnet name (vnet output: pe_subnet_name)"
  type        = string
  default     = "pe-subnet"
}

#################################################
# Naming + ownership tag — mirrors the vnet module
#################################################
variable "name_prefix" {
  description = "Prefix for private-endpoint / DNS resource names."
  type        = string
  default     = "cielara"
}

variable "cielara_client_id" {
  description = "Optional Cielara client ID, stamped into the cielara-client-id tag."
  type        = string
  default     = ""
}

variable "request_message" {
  description = "Message sent to the remote cluster's owner on the manual private-link connection request (shown when they approve/reject)."
  type        = string
  default     = "Cielara Enterprise private endpoint connection request"
}

#################################################
# Remote private AKS clusters to reach over private link
#
# One entry per remote cluster. The map KEY is a short label used in resource
# names and as the for_each key (keep it stable — changing it recreates the PE).
#
# The AKS API server is NOT a standalone Private Link Service: the private
# endpoint targets the managed CLUSTER resource itself with the "management"
# subresource (group id). So:
#   cluster_id : resource ID of the remote AKS managed cluster, e.g.
#                az aks show -g <rg> -n <cluster> --query id -o tsv
#   fqdn       : the remote cluster's PRIVATE API FQDN, e.g.
#                az aks show -g <rg> -n <cluster> --query privateFqdn -o tsv
#                The DNS zone (privatelink.<region>.azmk8s.io) and the A-record
#                name are parsed from this; clusters in the same region share
#                one zone.
#   is_manual_connection : false (default) auto-approves when this identity has
#                approval rights on the remote cluster (same tenant/owner). Set
#                true for cross-tenant, where the remote owner must approve the
#                request (request_message is sent to them).
#################################################
variable "remote_clusters" {
  description = "Map of remote private AKS clusters to create private endpoints for. Key = short stable label."
  type = map(object({
    cluster_id           = string
    fqdn                 = string
    is_manual_connection = optional(bool, false)
  }))
  default = {}

  validation {
    # Every fqdn must contain the privatelink.<region>.azmk8s.io zone so the
    # zone name and A-record name can be parsed deterministically.
    condition = alltrue([
      for k, c in var.remote_clusters : contains(split(".", c.fqdn), "privatelink")
    ])
    error_message = "Each remote_clusters[*].fqdn must be a private AKS API FQDN containing 'privatelink' (e.g. <name>.<guid>.privatelink.<region>.azmk8s.io)."
  }
}
