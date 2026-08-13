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

# The signing key is module-only: the frozen prepare scripts create neither it
# nor its alias, so a script-prepared account adopts by CREATING them. The key
# has no deterministic id, so the probe returns the alias's current target for
# the import below. Adopting a key an older script version made rewrites its
# permissive default policy to the deployer-Deny version.
data "external" "jwt_signing_key" {
  count = var.migrate ? 1 : 0

  program = ["bash", "${path.module}/check-jwt-key.sh"]
}

locals {
  jwt_alias_exists = try(data.external.jwt_signing_key[0].result.exists, "false") == "true"
  jwt_alias_target = try(data.external.jwt_signing_key[0].result.key_id, "")
}

import {
  for_each = local.jwt_alias_exists ? toset(["this"]) : toset([])
  to       = aws_kms_key.jwt_signing["1"]
  id       = local.jwt_alias_target
}

import {
  for_each = local.jwt_alias_exists ? toset(["this"]) : toset([])
  to       = aws_kms_alias.jwt_signing
  id       = "alias/cielara-jwt-signing"
}
