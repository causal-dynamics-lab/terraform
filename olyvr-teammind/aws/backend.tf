# State lives in an S3 bucket (versioned; use_lockfile locks with an S3 object, no DynamoDB table). The bucket, key
# and region come from a backend.hcl you keep next to this file (git-ignored; backend.hcl.example shows it):
# terraform init -backend-config=backend.hcl
terraform {
  backend "s3" {}
}
