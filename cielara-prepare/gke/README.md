# Cielara GKE prepare

Prepares your GCP project for a Cielara GKE deployment. Creates the service
accounts, IAM roles, and API enablements the Cielara control plane needs, and
writes the deployer key file you upload back in the Cielara deploy form.

This is the Terraform equivalent of `prepare-gke.sh` — it creates exactly the
same resources with the same names. Use one or the other, not both.

## What it creates

| Resource | Name | Purpose |
|---|---|---|
| Service account | `cielara@<project>` | Identity the Cielara control plane deploys as |
| Service account | `gke-node-sa@<project>` | Identity the GKE node pool runs as |
| Service account | `cielara-app@<project>` | Identity the Cielara app assumes via Workload Identity |
| Service account | `cielara-jwt-signer@<project>` | Identity admin-backend signs JWTs as (Workload Identity) |
| Custom role | `cielaraAppSecretManager` | Least-privilege Secret Manager access for the app |
| Custom role | `cielaraProvisionerFilestoreSweep` | Filestore and PD disk cleanup on teardown |
| Custom role | `cielaraAppJwtSigner` | Sign + read-public-key on the JWT key, nothing else |
| KMS keyring + key | `cielara-jwt/jwt-signing` | Customer-owned JWT signing key (EC P-256) — Cielara never holds the private key |
| IAM bindings | — | Minimal role sets for the accounts; signer role bound at key scope only |
| API enablements | 12 services | Everything the deploy's Terraform requires |
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

```bash
cd cielara-prepare/gke
# Terraform reads Application Default Credentials; sign in as part of every apply.
gcloud auth login
gcloud auth application-default login
# Download the pre-filled terraform.tfvars from the Cielara deploy form,
# or copy terraform.tfvars.example and edit it.
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
terraform -chdir=verify init
terraform -chdir=verify apply
```

A 403 in the first minute or two is IAM propagation — retry.

## State is a credential

The Terraform state contains the deployer service account's private key.

- **Never send the state to Cielara** — Cielara never needs it.
- Local state is fine for a single operator. For a team, configure a remote
  backend in your own cloud account — see `backend.tf`.
- **Keep the state.** Cielara occasionally extends the prepare resource set;
  re-applying this module (at the version the Cielara UI links) picks the
  additions up in place.
- Lost the state? Re-adopt the existing resources with `migrate = true`
  (see below) — do not delete or recreate anything.

## Already prepared with the script, or lost your state?

Set `migrate = true` (with `create_key = false`) and apply: every existing
prepare resource is imported into state instead of recreated — nothing
changes in your project, your current `cielara-key.json` keeps working, and
active Cielara deployments are untouched.

```hcl
# terraform.tfvars
project_id = "my-gcp-project"
migrate    = true
create_key = false
```

```bash
terraform init
terraform apply     # imports, creates nothing new
terraform plan      # must report: No changes.
```

Verify the plan is empty before relying on the migrated state. The existing
deployer key cannot be imported (Terraform does not support it); it simply
stays as it is — rotate it through the Cielara credential UI if you ever need
to. After the first successful apply, set `migrate` back to false (or leave
it — imports of already-managed resources are skipped).

The infra-version bucket postdates the scripts. With `migrate = true` the
module checks whether it already exists (state lost after a run that had
already created it) and imports it when it does; otherwise it is created
fresh. The check runs `gcloud storage buckets describe` via
`check-version-marker.sh`, so migrations need the gcloud CLI authenticated —
fresh prepares do not.

Adopting a project prepared **before the JWT signing key existed**? Re-run the
latest prepare once first (idempotent) — the migrate imports expect the
keyring, key, signer account, and signer role to exist.

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
  first is a new ENABLED crypto-key version, and the data plane signs with the
  highest one.

  ```hcl
  jwt_key_generation = 2   # terraform.tfvars — was 1
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
  failing inside the same window (measured on staging: JWKS dropped it in under
  30s, tokens 401'd within a minute), so revoke is the command to reach for when
  you believe a key is compromised.

  Rollback of a rotation is a `jwt_key_generation` decrement (the dropped
  version is scheduled for destruction, recoverable inside the KMS window) —
  the data plane falls back to the highest version still enabled.
- `terraform destroy` removes the service accounts and roles (breaking any
  active Cielara deployment) but never disables the enabled APIs — they may be
  shared with other workloads in the project.
- The JWT signing key refuses to destroy (`prevent_destroy`), and so does a
  `region` change — the keyring location is immutable, so terraform would
  replace the key, scheduling every version for destruction and stopping a
  live data plane signing within minutes. Moving region for real: destroy the
  Cielara deployment first, delete the `lifecycle` block from
  `google_kms_crypto_key.jwt_signing` for one apply, and put it back. KMS
  keyrings and keys cannot be deleted on GCP regardless: a destroy schedules
  the key's versions for destruction and removes both from state, leaving the
  empty shells behind.

## TLDR / CLI

```bash
git clone https://github.com/causal-dynamics-lab/terraform.git
cd terraform && git checkout <TAG>        # the tag the Cielara deploy form names
cd cielara-prepare/gke

gcloud auth login
gcloud auth application-default login

# Download the pre-filled terraform.tfvars from the Cielara deploy form
# (or copy terraform.tfvars.example and edit it).

# Already prepared (script or lost state)? Add:
#   echo 'migrate = true'    >> terraform.tfvars
#   echo 'create_key = false' >> terraform.tfvars

terraform init
terraform plan     # migrating: only imports + the marker additions, 0 destroy
terraform apply
terraform plan     # must print: No changes.
# handback: cielara-key.json -> Cielara deploy form
```
