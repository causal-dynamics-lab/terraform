variable "project_id" {
  description = "GCP project Cielara will deploy into"
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "Must be a valid GCP project ID."
  }
}

variable "create_key" {
  description = "Create a JSON key for the deployer service account and write it to key_output_path. Set false to keep an existing key untouched."
  type        = bool
  default     = true
}

variable "key_output_path" {
  description = "Where to write the deployer service account key file"
  type        = string
  default     = "cielara-key.json"
}
