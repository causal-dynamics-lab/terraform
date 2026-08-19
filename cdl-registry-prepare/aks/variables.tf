variable "subscription_id" {
  description = "Azure subscription Cielara will deploy into"
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.subscription_id))
    error_message = "Must be an Azure subscription GUID."
  }
}

variable "cielara_client_id" {
  description = "Your Cielara client id (pre-filled in the main.tf served by the deploy form). Names the service principal so each deployment gets its own credential."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-zA-Z-]+$", var.cielara_client_id))
    error_message = "Must be a Cielara client id (alphanumeric and dashes)."
  }
}

variable "location" {
  description = "Azure region for the infra-version storage account and the JWT signing vault (e.g. eastus2). A Key Vault URL carries no region, so this is a latency/residency choice and a mismatch with the deploy form cannot break signing."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]+$", var.location))
    error_message = "Must be an Azure region name like eastus2 (lowercase, no spaces)."
  }
}

variable "migrate" {
  description = "Import already-existing prepare resources (created by prepare-aks.sh, or by this module when the state was lost) instead of creating them. Requires the migrate_* object ids — run discover-migrate.sh to generate them. Pair with create_secret = false to keep the existing client secret. The infra-version resources are checked for existence and imported only when present."
  type        = bool
  default     = false
}

variable "create_secret" {
  description = "Create a client secret for the service principal and write the handback file to creds_output_path. Set false to keep an existing secret untouched (e.g. when adopting resources prepared by prepare-aks.sh)."
  type        = bool
  default     = true
}

variable "creds_output_path" {
  description = "Where to write the credentials handback file"
  type        = string
  default     = "cielara-creds.json"
}

# Azure object ids are not derivable from names, so migration needs them
# supplied. discover-migrate.sh queries the subscription and writes
# migrate.auto.tfvars with all four.
variable "migrate_app_object_id" {
  description = "Entra application object id to adopt (from discover-migrate.sh)"
  type        = string
  default     = ""
}

variable "migrate_sp_object_id" {
  description = "Service principal object id to adopt (from discover-migrate.sh)"
  type        = string
  default     = ""
}

variable "migrate_contributor_assignment_id" {
  description = "Full resource id of the existing Contributor role assignment (from discover-migrate.sh)"
  type        = string
  default     = ""
}

variable "migrate_rbac_admin_assignment_id" {
  description = "Full resource id of the existing RBAC Administrator role assignment (from discover-migrate.sh)"
  type        = string
  default     = ""
}

variable "state_storage_url" {
  description = "Where this module's Terraform state is kept — must match the backend you configured (e.g. an Azure blob URL, s3://<bucket>/<key>, gs://<bucket>/<prefix>, or a local path for local state). Recorded in the handback file so the Cielara manage tab shows where the state lives."
  type        = string

  validation {
    condition     = length(trimspace(var.state_storage_url)) > 0
    error_message = "Must not be empty — record where the Terraform state is kept."
  }
}

variable "jwt_key_auto_rotation_months" {
  description = "Months between automatic JWT signing-key rotations (Key Vault rotation policy). 0 disables the policy - rotation stays on-demand via az keyvault key rotate. Earlier versions stay enabled either way. See the README."
  type        = number
  default     = 0

  validation {
    condition     = var.jwt_key_auto_rotation_months >= 0 && floor(var.jwt_key_auto_rotation_months) == var.jwt_key_auto_rotation_months
    error_message = "Must be a whole number of months; 0 disables automatic rotation."
  }
}
