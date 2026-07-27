# Cielara GCP VM prepare

Prepares your GCP project for a Cielara VM deployment. Creates the service
account, IAM roles, and API enablements the Cielara control plane needs, and
writes the deployer key file you upload back in the Cielara deploy form.

This is the Terraform equivalent of `prepare-gcp.sh` — it creates exactly the
same resources with the same names. Use one or the other, not both.

## What it creates

| Resource | Name | Purpose |
|---|---|---|
| Service account | `cielara@<project>` | Identity the Cielara control plane deploys as |
| IAM bindings | 13 project roles + 2 self-bindings | Minimal set for VM + network + Cloud SQL provisioning |
| API enablements | 7 services | Everything the deploy's Terraform requires |
| Key file | `cielara-key.json` | The handback — upload it in the Cielara deploy form |

## Usage

Requires Terraform >= 1.7 and credentials for the target project with owner
(or equivalent IAM + Service Usage admin) permissions — e.g. `gcloud auth
application-default login`.

```bash
cd cielara-prepare/gcp
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

## Rotation and teardown

- This module never rotates an existing key: `create_key = false` leaves your
  current `cielara-key.json` valid. Rotate keys through the Cielara credential
  UI, not here.
- `terraform destroy` removes the service account and roles (breaking any
  active Cielara deployment) but never disables the enabled APIs — they may be
  shared with other workloads in the project.
