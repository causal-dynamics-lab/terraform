# State lives in a GCS bucket (versioned, locking built in); it holds the PagerDuty integration key, so keep the bucket
# private. The bucket and prefix come from a backend.hcl you keep next to this file (git-ignored; backend.hcl.example
# shows it): terraform init -backend-config=backend.hcl
terraform {
  backend "gcs" {}
}
