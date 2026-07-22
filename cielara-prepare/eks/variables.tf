variable "control_plane_principal_arn" {
  description = "IAM principal the Cielara control plane assumes this role from (pre-filled in the terraform.tfvars served by the deploy form)"
  type        = string

  validation {
    condition     = can(regex("^arn:aws:iam::[0-9]{12}:(role|user)/", var.control_plane_principal_arn))
    error_message = "Must be an IAM role or user ARN."
  }
}

variable "external_id" {
  description = "Your Cielara client id (pre-filled in the terraform.tfvars served by the deploy form). Used as the STS External ID and as the role-name suffix, so each tenant gets its own role."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-zA-Z-]+$", var.external_id))
    error_message = "Must be a Cielara client id (alphanumeric and dashes)."
  }
}

variable "migrate" {
  description = "Import the already-existing role and policy (created by prepare-eks.sh, or by this module when the state was lost) instead of creating them. AWS names are deterministic — no discovery step needed."
  type        = bool
  default     = false
}

variable "creds_output_path" {
  description = "Where to write the credentials handback file"
  type        = string
  default     = "cielara-creds.json"
}
