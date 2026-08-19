# Prepares your AWS account for a Cielara EKS deployment: one cross-account
# IAM role the Cielara control plane assumes via STS, gated by your Cielara
# client id as the External ID. Every name below is load-bearing — do not
# rename.

locals {
  role_name = "cielara_eks_deployer_${var.external_id}"

  jwt_key_generations    = toset([for g in range(1, var.jwt_key_generation + 1) : tostring(g)])
  jwt_current_generation = tostring(var.jwt_key_generation)
}

resource "aws_iam_role" "deployer" {
  name        = local.role_name
  description = "Cielara control plane role for EKS data-plane infra provisioning"

  assume_role_policy = templatefile("${path.module}/trust.json.tpl", {
    principal_arn = var.control_plane_principal_arn
    external_id   = var.external_id
  })

  max_session_duration = 3600

  tags = {
    "managed-by" = "cielara"
    "purpose"    = "control-plane-eks-deployer"
  }
}

resource "aws_iam_role_policy" "deployer" {
  name   = local.role_name
  role   = aws_iam_role.deployer.id
  policy = file("${path.module}/policy.json")
}

data "aws_caller_identity" "current" {}

# Customer-owned AWS KMS asymmetric key the data plane signs its JWTs with; the
# private key never leaves this account. No IAM grant here: the runtime identity
# is created per-deployment by the deploy terraform. AWS's default key policy
# delegates to account IAM, where the deployer roles hold kms:* - so the explicit
# Deny below is what keeps Cielara from signing with, disabling or deleting it.
# Rotation is a jwt_key_generation bump; earlier generations stay enabled.
resource "aws_kms_key" "jwt_signing" {
  for_each = local.jwt_key_generations

  description              = "Cielara data-plane JWT signing key (plan 0049), generation ${each.key}"
  key_usage                = "SIGN_VERIFY"
  customer_master_key_spec = "ECC_NIST_P256"

  policy = templatefile("${path.module}/kms-key-policy.json.tpl", {
    account_id = data.aws_caller_identity.current.account_id
  })

  tags = {
    "managed-by"          = "cielara"
    "cielara-jwt-signing" = "true"
  }
}

resource "aws_kms_alias" "jwt_signing" {
  name          = "alias/cielara-jwt-signing"
  target_key_id = aws_kms_key.jwt_signing[local.jwt_current_generation].key_id
}

# Pre-generation state holds a single un-indexed key; without this every
# already-prepared account would destroy and recreate its signing key on
# upgrade.
moved {
  from = aws_kms_key.jwt_signing
  to   = aws_kms_key.jwt_signing["1"]
}

# Upload this file in the Cielara deploy form.
resource "local_sensitive_file" "creds" {
  filename        = var.creds_output_path
  file_permission = "0600"
  content = jsonencode({
    role_arn    = aws_iam_role.deployer.arn
    storage_url = var.state_storage_url
  })
}
