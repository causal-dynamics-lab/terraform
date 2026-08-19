# Cielara GCP VM prepare

> Published to the Terraform Registry as
> [`causal-dynamics-lab/cielara-prepare-vm/google`](https://registry.terraform.io/modules/causal-dynamics-lab/cielara-prepare-vm/google/latest)
> via the read-only mirror repo `terraform-google-cielara-prepare-vm`.
> Development, history, and issues:
> [causal-dynamics-lab/terraform](https://github.com/causal-dynamics-lab/terraform).

Prepares your GCP project for a Cielara VM deployment. Creates the service
account, IAM roles, and API enablements the Cielara control plane needs, and
writes the deployer key file you upload back in the Cielara deploy form.

This is the Terraform equivalent of `prepare-gcp.sh` — it creates exactly the
same resources with the same names. Use one or the other, not both.

## What it creates

| Resource | Name | Purpose |
|---|---|---|
| Service account | `cielara@<project>` | Identity the Cielara control plane deploys as |
| Service account | `cielara-app@<project>` | Identity the VM runs and signs JWTs as |
| Custom role | `cielaraVmSecretManager` | Least-privilege Secret Manager access + sign/read-public-key on the JWT key |
| Custom role | `cielaraAppJwtSigner` | Sign + read-public-key on the JWT key, nothing else |
| KMS keyring + key | `cielara-jwt/jwt-signing` | Customer-owned JWT signing key (EC P-256) — Cielara never holds the private key |
| IAM bindings | 13 project roles + 2 self-bindings | Minimal set for VM + network + Cloud SQL provisioning; signer role bound at key scope only, never to the deployer |
| API enablements | 8 services | Everything the deploy's Terraform requires |
| Bucket + object | `cielara-infra-version-<project>` / `version.json` | Version marker the Cielara control plane reads (deployer gets read on just this bucket) |
| Key file | `cielara-key.json` | The handback — upload it in the Cielara deploy form |

The KMS keyring lives in `region`, a required variable — set it to the region
you will choose in the Cielara deploy form; the two must match, because the
control plane derives the signing key's path from the form's region. A mismatch
deploys cleanly and then fails at the first sign/JWKS call. The keyring's
location is immutable and GCP never deletes keyrings, so changing it later
strands the old one.

## Usage

Requires Terraform >= 1.7 and the gcloud CLI, signed in to the target project
as an owner (or with equivalent IAM + Service Usage admin permissions).

The Cielara deploy form serves a generated `main.tf` — provider, backend
guidance, and this module pinned to the exact version your deployment
expects, inputs pre-filled. Drop it in an empty folder. Writing the call
yourself instead:

```hcl
provider "google" {
  project = "my-gcp-project"
}

module "cielara_prepare" {
  source  = "causal-dynamics-lab/cielara-prepare-vm/google"
  version = "X.Y.Z" # the exact version the Cielara deploy form names

  project_id = "my-gcp-project"
  region     = "us-central1" # must match the deploy form's region

  # Recorded into the handback so Cielara can show where your Terraform
  # state lives: "local", or your remote backend URL (gs://bucket/prefix).
  state_storage_url = "local"
}
```

```bash
# Terraform reads Application Default Credentials; sign in as part of every apply.
gcloud auth login
gcloud auth application-default login
terraform init
terraform apply
```

The apply writes `cielara-key.json` next to your working directory — the
deployer key plus a `storage_url` field recording where your Terraform state
is kept (shown in the Cielara manage tab). Upload it in the Cielara deploy
form. Done.

## Infra-version marker

The apply also creates a tiny bucket, `cielara-infra-version-<project>`, with
a single `version.json` recording which version of this module ran
(`0.0.0-dev` on an untagged checkout). The deployer service account gets read
access to just this bucket so the Cielara control plane can tell the prepare
vintage without asking you.

To confirm the deployer can actually read it, run the bundled verify module
after the apply — it reads the object back authenticated with
`cielara-key.json`, i.e. as the deployer itself:

```bash
# after init, the module source (verify/ included) sits under .terraform/modules/
terraform -chdir=.terraform/modules/cielara_prepare/verify init
terraform -chdir=.terraform/modules/cielara_prepare/verify apply \
  -var key_path=../../../../cielara-key.json
```

A 403 in the first minute or two is IAM propagation — retry. Re-running after
a lost state? Set `migrate = true` (and `create_key = false` to keep the
existing deployer key): the module checks whether the infra-version bucket
already exists and imports it instead of creating it. The check runs `gcloud
storage buckets describe` via `check-version-marker.sh`, so it needs the
gcloud CLI authenticated — fresh prepares do not.

## State is a credential

The Terraform state contains the deployer service account's private key.

- **Never send the state to Cielara** — Cielara never needs it.
- Local state is fine for a single operator. For a team, configure a remote
  backend in your own cloud account — see "Remote state" below.
- **Keep the state.** Cielara occasionally extends the prepare resource set;
  re-applying this module (at the version the Cielara UI links) picks the
  additions up in place.
- Lost the state? Re-adopt the existing resources with `migrate = true`
  (see below) — do not delete or recreate anything.

### Remote state

Terraform ignores backend blocks inside a published module — the backend
belongs in your root module, next to the `module` call. The Cielara-generated
`main.tf` carries one already: filled in when your deployment has a recorded
state location, commented out otherwise. Writing it by hand:

```hcl
terraform {
  backend "gcs" {
    bucket = "<your-terraform-state-bucket>"
    prefix = "cielara-prepare/gcp"
  }
}
```

Any backend pointing at storage you own works — `s3` and `azurerm` are just
as good. Adding it after a local-state apply: run `terraform init
-migrate-state` once.

## Already prepared with the script, or lost your state?

Set `migrate = true` (with `create_key = false`) and apply: every existing
prepare resource is imported into state instead of recreated — nothing
changes in your project, your current `cielara-key.json` keeps working, and
active Cielara deployments are untouched.

```hcl
module "cielara_prepare" {
  # ...source, version, and inputs as above...
  migrate    = true
  create_key = false
}
```

The deploy form's "already prepared" toggle serves the generated `main.tf`
with both already set.

```bash
terraform init
terraform apply     # imports, creates nothing new
terraform plan      # must report: No changes.
```

Verify the plan is empty before relying on the migrated state. The existing
deployer key cannot be imported (Terraform does not support it); it simply
stays as it is.

Adopting a project prepared **before the JWT signing key existed**? Re-run
the latest `prepare-gcp.sh` once first (idempotent) — the migrate imports
expect the keyring, key, app account, and signer role to exist.

## Rotation and teardown

Two different keys live in this module, with different rotation stories — do not
confuse them.

- **Deployer service-account key** (`cielara-key.json`, the handback): this
  module never rotates an existing one — `create_key = false` leaves your
  current file valid. Rotate it through the Cielara credential UI, not here.
- **JWT signing key** (keyring `cielara-jwt`, key `jwt-signing`): rotation
  *and* revocation are yours, not Cielara's — the control plane holds no
  permission to create, disable, or destroy a version, which is the whole
  point of the key living in your project. **Rotation is a
  `jwt_key_generation` bump and nothing else**: each generation past the
  first is a new ENABLED crypto-key version, and the VM signs with the
  highest one.

  ```hcl
  module "cielara_prepare" {
    # ...source, version, and inputs as before...
    jwt_key_generation = 2 # was 1
  }
  ```

  Revocation stays a gcloud one-liner:

  ```bash
  # revoke: stop a version verifying (and signing, if it was the newest)
  gcloud kms keys versions disable <N> \
    --keyring cielara-jwt --key jwt-signing --location <region>
  ```

  Every ENABLED version is published in the data plane's JWKS, so tokens signed
  by an older version keep verifying until you disable that version — a rotation
  on its own logs nobody out. The data plane picks up a new version within its
  ~5-minute key cache. A disabled version drops out of JWKS and its tokens start
  failing inside the same window, so revoke is the command to reach for when you
  believe a key is compromised.

  Rollback of a rotation is a `jwt_key_generation` decrement (the dropped
  version is scheduled for destruction, recoverable inside the KMS window) —
  the data plane falls back to the highest version still enabled.

  The re-rendered `main.tf` from the Cielara lifecycle panel carries the
  expected generation, so rotation is the same download-and-apply motion as
  an upgrade.
- `terraform destroy` removes the service account and roles (breaking any
  active Cielara deployment) but never disables the enabled APIs — they may be
  shared with other workloads in the project.
- The JWT signing key refuses to destroy (`prevent_destroy`), and so does a
  `region` change — the keyring location is immutable, so terraform would
  replace the key, scheduling every version for destruction and stopping a
  live data plane signing within minutes. Moving region for real: destroy the
  Cielara deployment first, delete the `lifecycle` block from
  `google_kms_crypto_key.jwt_signing` for one apply, and put it back.

## TLDR / CLI

```bash
mkdir cielara-prepare-vm && cd cielara-prepare-vm
# Download the generated main.tf from the Cielara deploy form into this folder.

gcloud auth login
gcloud auth application-default login

# Lost your state after an earlier run? Use the deploy form's "already
# prepared" toggle — the downloaded file carries migrate = true, create_key = false.

terraform init
terraform plan
terraform apply
terraform plan     # must print: No changes.
# handback: cielara-key.json -> Cielara deploy form
```
