# Adoption of an already-prepared account (migrate = true): both import ids
# derive from your Cielara client id, so there is no discovery step. After
# apply, `terraform plan` must show no changes.

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

# The JWT signing key has no deterministic id — the alias resolves it. The
# alias (and key) exist only for accounts prepared with a script version
# carrying the JWT block (or by this module). Adopting an older account?
# Re-run the latest prepare-eks.sh first, or this data source fails.
#
# A key created by an older script version keeps AWS's permissive default key
# policy; adopting it here rewrites the policy to the deployer-Deny version.
data "aws_kms_alias" "jwt_signing" {
  count = var.migrate ? 1 : 0

  name = "alias/cielara-jwt-signing"
}

import {
  for_each = var.migrate ? toset(["this"]) : toset([])
  to       = aws_kms_key.jwt_signing
  id       = data.aws_kms_alias.jwt_signing[0].target_key_id
}

import {
  for_each = var.migrate ? toset(["this"]) : toset([])
  to       = aws_kms_alias.jwt_signing
  id       = "alias/cielara-jwt-signing"
}
