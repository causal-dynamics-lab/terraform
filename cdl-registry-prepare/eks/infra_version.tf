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

# Versioning keeps every overwritten version.json recoverable; the lifecycle
# rule deletes a replaced version 30 days after it became noncurrent.
# Both are separate resources, so an existing bucket is never
# replaced. Once enabled, S3 versioning can only be suspended, not removed.
resource "aws_s3_bucket_versioning" "infra_version" {
  bucket = aws_s3_bucket.infra_version.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "infra_version" {
  bucket = aws_s3_bucket.infra_version.id

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }

  depends_on = [aws_s3_bucket_versioning.infra_version]
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

  # Write the marker only after versioning is on, so the previous marker is
  # kept as a noncurrent version on upgrade.
  depends_on = [aws_s3_bucket_versioning.infra_version]
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

# The bucket postdates the script era, so whether it exists depends on what
# prepared this account (script vs earlier module run). An import block fails
# hard when the remote object does not exist, so adoption keys on a live
# existence check instead of a flag. The object and policy are overwrite-PUTs
# — only the bucket itself needs importing. Only consulted when migrate =
# true, so fresh prepares never shell out.

data "external" "infra_version_marker" {
  count   = var.migrate ? 1 : 0
  program = [local.bash, "${path.module}/check-version-marker.sh", "cielara-infra-version-${lower(var.external_id)}", coalesce(var.region, "")]

  lifecycle {
    precondition {
      condition     = !local.bash_missing
      error_message = local.bash_missing_error
    }
  }
}

locals {
  infra_version_marker_exists = try(data.external.infra_version_marker[0].result.exists, "false") == "true"
}
