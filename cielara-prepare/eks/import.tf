# Adoption of an already-prepared account (migrate = true). Unlike Azure,
# both import ids derive from the External ID, so there is no discovery
# step. After apply, `terraform plan` must show no changes.

import {
  for_each = var.migrate ? toset(["this"]) : toset([])
  to       = aws_iam_role.deployer
  id       = "cielara_eks_deployer_${var.external_id}"
}

import {
  for_each = var.migrate ? toset(["this"]) : toset([])
  to       = aws_iam_role_policy.deployer
  id       = "cielara_eks_deployer_${var.external_id}:cielara_eks_deployer_${var.external_id}"
}
