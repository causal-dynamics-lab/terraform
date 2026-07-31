#################################################
# Azure auth
#################################################
variable "subscription_id" {
  description = "Azure subscription ID the AI Foundry resource is created in"
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
# Resource group
#################################################
variable "resource_group_name" {
  description = "Resource group for the AI Foundry resource. Created unless create_resource_group is false, in which case an existing group with this name is adopted."
  type        = string
  default     = "cielara-ai-foundry-rg"
}

variable "create_resource_group" {
  description = "Create the resource group (true) or adopt an existing one by name (false)."
  type        = bool
  default     = true
}

variable "location" {
  description = "Azure region for the AI Foundry resource (e.g. eastus2). Model availability varies by region — eastus2 carries the full set the data plane needs."
  type        = string
  default     = "eastus2"
}

#################################################
# Naming
#################################################
variable "name_prefix" {
  description = "Prefix for the AI Foundry account name and its custom subdomain. The subdomain must be globally unique across Azure, so keep this distinctive (e.g. include your org or environment)."
  type        = string
  default     = "cielara"
}

variable "environment" {
  description = "Environment discriminator appended to resource names and the custom subdomain (e.g. staging, production, mehran-test)."
  type        = string
  default     = "staging"
}

#################################################
# Model deployments
#################################################
variable "model_deployments" {
  # Deployment names (map keys) are load-bearing: the Cielara data plane
  # resolves models by deployment name, and the expected names are the
  # azure_openai defaults in core's internal/llmprovider/categories.go —
  # reasoning=gpt-5.5, coding=gpt-5.3-codex, mini=gpt-5.4-mini,
  # embedding=text-embedding-3-small. Keep key == model name unless you
  # also override the model selection in the data-plane web app.
  #
  # gpt-5.6-luna is deployed in addition to the defaults: core's
  # ProviderModels offers it as an alternative for both the reasoning and
  # the coding category, so the deployment has to exist before an operator
  # can pick it under Admin > Models. Nothing selects it by default.
  description = "Model deployments to create, keyed by deployment name. version=null picks the model's current default version."
  type = map(object({
    model_name = string
    version    = optional(string)
    sku_name   = optional(string, "GlobalStandard")
    capacity   = optional(number, 100)
  }))
  default = {
    "gpt-5.5" = {
      model_name = "gpt-5.5"
    }
    "gpt-5.3-codex" = {
      model_name = "gpt-5.3-codex"
    }
    "gpt-5.4-mini" = {
      model_name = "gpt-5.4-mini"
    }
    "gpt-5.6-luna" = {
      model_name = "gpt-5.6-luna"
    }
    "text-embedding-3-small" = {
      model_name = "text-embedding-3-small"
      sku_name   = "Standard"
      capacity   = 120
    }
  }
}
