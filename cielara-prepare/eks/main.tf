# Prepares your AWS account for a Cielara EKS deployment: one cross-account
# IAM role the Cielara control plane assumes via STS, gated by your Cielara
# client id as the External ID. Every name below is load-bearing — do not
# rename.

locals {
  role_name = "cielara_eks_deployer_${var.external_id}"
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

# JWT signing key: a customer-owned AWS KMS asymmetric key the Cielara data
# plane signs its JWTs with. The private key never leaves this account's KMS.
#
# No IAM grant is attached here: the runtime identities (EKS app IRSA role) are
# terraform-created per-deployment and do not exist at prepare time. The
# deployment terraform attaches the sign/get-public-key grant when the AWS KMS
# signer lands; until then the key stays dormant.
#
# AWS's default key policy delegates all access to account IAM policies — which
# include the control-plane-assumable deployer roles' broad grants (kms:* on
# the EKS role, AdministratorAccess on the VM role). The key policy's explicit
# Deny (which IAM allows cannot override) keeps those roles from signing with,
# disabling, or scheduling deletion of the customer-only key, while leaving
# customer IAM administration and the future runtime-role sign grant intact.
resource "aws_kms_key" "jwt_signing" {
  description              = "Cielara data-plane JWT signing key (plan 0049)"
  key_usage                = "SIGN_VERIFY"
  customer_master_key_spec = "ECC_NIST_P256"

  policy = templatefile("${path.module}/kms-key-policy.json.tpl", {
    account_id = data.aws_caller_identity.current.account_id
  })

  tags = {
    "managed-by" = "cielara"
  }
}

resource "aws_kms_alias" "jwt_signing" {
  name          = "alias/cielara-jwt-signing"
  target_key_id = aws_kms_key.jwt_signing.key_id
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
