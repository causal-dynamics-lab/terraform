variable "project_id" {
  description = "GCP project Cielara will deploy into"
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "Must be a valid GCP project ID."
  }
}

variable "migrate" {
  description = "Re-adopt resources left by an earlier run of this module after the state was lost: the module checks whether the infra-version bucket exists and imports it instead of creating it. Pair with create_key = false to keep the existing deployer key."
  type        = bool
  default     = false
}

variable "region" {
  description = "Region the deployment runs in; places the cielara-jwt KMS keyring. Must match the region chosen in the Cielara deploy form, and cannot be changed later (keyring locations are immutable)."
  type        = string

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]$", var.region))
    error_message = "Must be a GCP region id such as us-central1."
  }
}

variable "create_key" {
  description = "Create a JSON key for the deployer service account and write it to key_output_path. Set false to keep an existing key untouched (e.g. when adopting resources prepared by prepare-gcp.sh)."
  type        = bool
  default     = true
}

variable "key_output_path" {
  description = "Where to write the deployer service account key file"
  type        = string
  default     = "cielara-key.json"
}

variable "state_storage_url" {
  description = "Where this module's Terraform state is kept — must match the backend you configured (e.g. gs://<bucket>/cielara-prepare/gcp, s3://<bucket>/<key>, an Azure blob URL, or a local path for local state). Recorded in the handback file so the Cielara manage tab shows where the state lives."
  type        = string

  validation {
    condition     = length(trimspace(var.state_storage_url)) > 0
    error_message = "Must not be empty — record where the Terraform state is kept."
  }
}

variable "jwt_key_generation" {
  description = "Increment to rotate the JWT signing key. Each generation past the first is a new crypto-key version; the data plane signs with the highest ENABLED version and earlier ones stay enabled, so a rollback is a decrement. See the README."
  type        = number
  default     = 1

  validation {
    condition     = var.jwt_key_generation >= 1 && floor(var.jwt_key_generation) == var.jwt_key_generation
    error_message = "Must be a whole number >= 1; increment by one to rotate."
  }
}
