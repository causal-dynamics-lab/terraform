# Version marker for the control plane: records which prepare vintage this
# account ran and lets the deployer read it back. Module-only surface — the
# legacy prepare scripts are frozen and never create it, and the read grant
# is a bucket policy so the parity-checked policy.json stays untouched.

data "aws_region" "current" {}

resource "aws_s3_bucket" "infra_version" {
  bucket        = "cielara-infra-version-${lower(var.external_id)}"
  force_destroy = true

  tags = {
    "managed-by" = "cielara"
    "purpose"    = "infra-version-marker"
  }
}

resource "aws_s3_bucket_public_access_block" "infra_version" {
  bucket = aws_s3_bucket.infra_version.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "infra_version" {
  bucket       = aws_s3_bucket.infra_version.id
  key          = "version.json"
  content_type = "application/json"

  content = jsonencode({
    prepare_version = local.prepare_version
    revision        = local.prepare_revision
    channel         = local.release_channel
    module          = local.prepare_module
    provider        = "eks"
    region          = data.aws_region.current.name
  })
}

resource "aws_s3_bucket_policy" "deployer_infra_version_read" {
  bucket = aws_s3_bucket.infra_version.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "CielaraDeployerRead"
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.deployer.arn }
        Action    = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.infra_version.arn,
          "${aws_s3_bucket.infra_version.arn}/*",
        ]
      },
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.infra_version]
}

# The bucket postdates the script era, so adoption is gated on its own flag:
# migrate = true alone must keep working for pre-bucket vintages (an import
# block fails hard when the remote object does not exist). The object and
# policy are overwrite-PUTs — only the bucket itself needs importing.

import {
  for_each = var.migrate_version_bucket ? toset(["this"]) : toset([])
  to       = aws_s3_bucket.infra_version
  id       = "cielara-infra-version-${lower(var.external_id)}"
}
