variable "project_id" {
  description = "GCP project Cielara will deploy into"
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "Must be a valid GCP project ID."
  }
}

variable "migrate" {
  description = "Import already-existing prepare resources (created by prepare-gke.sh, or by this module when the state was lost) instead of creating them. Pair with create_key = false to keep the existing deployer key."
  type        = bool
  default     = false
}

variable "create_key" {
  description = "Create a JSON key for the deployer service account and write it to key_output_path. Set false to keep an existing key untouched (e.g. when adopting resources prepared by prepare-gke.sh)."
  type        = bool
  default     = true
}

variable "key_output_path" {
  description = "Where to write the deployer service account key file"
  type        = string
  default     = "cielara-key.json"
}
