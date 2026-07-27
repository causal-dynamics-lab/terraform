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
| Custom role | `cielaraAppSecretManager` | Least-privilege Secret Manager access for the app |
| Custom role | `cielaraProvisionerFilestoreSweep` | Filestore cleanup on teardown |
| IAM bindings | — | Minimal role sets for the three accounts |
| API enablements | 11 services | Everything the deploy's Terraform requires |
| Key file | `cielara-key.json` | The handback — upload it in the Cielara deploy form |

## Usage

Requires Terraform >= 1.7 and credentials for the target project with owner
(or equivalent IAM + Service Usage admin) permissions — e.g. `gcloud auth
application-default login`.

```bash
cd cielara-prepare/gke
# Download the pre-filled terraform.tfvars from the Cielara deploy form,
# or copy terraform.tfvars.example and edit it.
terraform init
terraform apply
```

The apply writes `cielara-key.json` next to your working directory — the
deployer key plus a `storage_url` field recording where your Terraform state
is kept (shown in the Cielara manage tab). Upload it in the Cielara deploy
form. Done.

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

## Rotation and teardown

- This module never rotates an existing key: `create_key = false` leaves your
  current `cielara-key.json` valid. Rotate keys through the Cielara credential
  UI, not here.
- `terraform destroy` removes the service accounts and roles (breaking any
  active Cielara deployment) but never disables the enabled APIs — they may be
  shared with other workloads in the project.
