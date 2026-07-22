# Prepares a customer AWS account for a Cielara EKS deployment: one
# cross-account IAM role the control plane assumes via STS, gated by a
# per-tenant External ID. Names and the policy documents must stay in
# lockstep with prepare-eks.sh (parity-tested in the Cielara control plane).

locals {
  # Per-tenant name: two Cielara tenants can onboard into the same AWS
  # account without clobbering each other's trust policy.
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

# Inline (vs managed) keeps the grant self-contained: deleting the role
# removes the policy, and revocation is a single delete. The document is
# service-scoped, not AdministratorAccess; IAM management is fenced to the
# Cielara data-plane naming (cdl-*/cielara-*).
resource "aws_iam_role_policy" "deployer" {
  name   = local.role_name
  role   = aws_iam_role.deployer.id
  policy = file("${path.module}/policy.json")
}
