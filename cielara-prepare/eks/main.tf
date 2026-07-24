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

# Upload this file in the Cielara deploy form.
resource "local_sensitive_file" "creds" {
  filename        = var.creds_output_path
  file_permission = "0600"
  content = jsonencode({
    role_arn = aws_iam_role.deployer.arn
  })
}
