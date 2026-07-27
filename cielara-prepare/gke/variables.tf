variable "project_id" {
  description = "GCP project Cielara will deploy into"
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "Must be a valid GCP project ID."
  }
}

variable "region" {
  description = "Region the Cielara deployment will run in — places the cielara-jwt KMS keyring. MUST match the region chosen in the Cielara deploy form: the control plane derives the key path from that region."
  type        = string
  default     = "us-central1"
}

variable "migrate" {
  description = "Import already-existing prepare resources (created by prepare-gke.sh, or by this module when the state was lost) instead of creating them. Pair with create_key = false to keep the existing deployer key."
  type        = bool
  default     = false
}

variable "migrate_version_resources" {
  description = "Import an already-existing infra-version bucket (created by an earlier run of this module before the state was lost) instead of creating it. Leave false unless apply fails with a bucket-already-exists conflict."
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

variable "state_storage_url" {
  description = "Where this module's Terraform state is kept — must match the backend you configured (e.g. gs://<bucket>/cielara-prepare/gke, s3://<bucket>/<key>, an Azure blob URL, or a local path for local state). Recorded in the handback file so the Cielara manage tab shows where the state lives."
  type        = string

  validation {
    condition     = length(trimspace(var.state_storage_url)) > 0
    error_message = "Must not be empty — record where the Terraform state is kept."
  }
}
