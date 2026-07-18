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

The apply writes `cielara-key.json` next to your working directory. Upload it
in the Cielara deploy form. Done.

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

A migration path (`migrate = true`) that imports the script-created resources
into Terraform state without recreating them ships in a follow-up module
revision. Until then, keep using the script-prepared resources as-is.

## Rotation and teardown

- This module never rotates an existing key: `create_key = false` leaves your
  current `cielara-key.json` valid. Rotate keys through the Cielara credential
  UI, not here.
- `terraform destroy` removes the service accounts and roles (breaking any
  active Cielara deployment) but never disables the enabled APIs — they may be
  shared with other workloads in the project.
