# Cielara AKS prepare

> Published to the Terraform Registry as
> [`causal-dynamics-lab/cielara-prepare-aks/azurerm`](https://registry.terraform.io/modules/causal-dynamics-lab/cielara-prepare-aks/azurerm/latest)
> via the read-only mirror repo `terraform-azurerm-cielara-prepare-aks`.
> Development, history, and issues:
> [causal-dynamics-lab/terraform](https://github.com/causal-dynamics-lab/terraform).

Prepares your Azure subscription for a Cielara AKS deployment. Creates the
Entra service principal the Cielara control plane authenticates as, assigns
its subscription-scoped roles, and writes the credentials file you upload
back in the Cielara deploy form. No Cielara identity is added to your tenant.

## What it creates

| Resource | Name | Purpose |
|---|---|---|
| Entra application + SP | `cielara_aks_deployer_<cielara-client-id>` | Identity the Cielara control plane deploys as |
| Client secret | — | Its credential (only when `create_secret = true`) |
| Role assignment | Contributor (subscription scope) | Create/manage the cluster, database, key vault, storage, gateway, network, identities |
| Role assignment | Role Based Access Control Administrator (subscription scope, constrained to the exact roles the deploy assigns) | Lets the deploy create the role assignments it needs |
| Storage account + blob | `cielarainfra<hash>` in RG `cielara-infra-version-<cielara-client-id>` / `version.json` | Version marker the Cielara control plane reads (deployer SP gets Storage Blob Data Reader on just this account) |
| Key Vault + EC P-256 key | `cielarajwt<hash>` / `jwt-signing` in RG `cielara-jwt-<cielara-client-id>` | Customer-owned JWT signing key. The data plane signs with it via the `cielara-jwt-signer` managed identity (Key Vault Crypto User); the deployer SP holds no vault role and cannot grant itself one. Rotation/revocation stay yours: `az keyvault key rotate` / disable a version |
| Managed identity | `cielara-jwt-signer` | Runtime signing identity the data plane federates as (deployer SP gets Managed Identity Contributor on just this identity, to bind each cluster's ServiceAccount) |
| Credentials file | `cielara-creds.json` | The handback — upload it in the Cielara deploy form |

The service principal is named per deployment on purpose: resetting one
deployment's secret never invalidates another's stored credential.

## Usage

Requires Terraform >= 1.7 and an identity that can create service principals
in the tenant and role assignments at the subscription scope (e.g. a
subscription Owner who can also register applications):

```bash
az login                              # or: az login --use-device-code
az account set --subscription <id>
```

The Cielara deploy form serves a generated `main.tf` — provider, backend
guidance, and this module pinned to the exact version your deployment
expects, inputs pre-filled. Drop it in an empty folder. Writing the call
yourself instead:

```hcl
provider "azurerm" {
  features {}
  subscription_id = "<subscription id>"
}

module "cielara_prepare" {
  source  = "causal-dynamics-lab/cielara-prepare-aks/azurerm"
  version = "X.Y.Z" # the exact version the Cielara deploy form names

  subscription_id   = "<subscription id>"
  cielara_client_id = "<your Cielara client id>" # the deploy form pre-fills it
  location          = "eastus2"

  # Recorded into the handback so Cielara can show where your Terraform
  # state lives: "local", or your remote backend URL.
  state_storage_url = "local"
}
```

```bash
terraform init
terraform apply
```

The apply writes `cielara-creds.json` into the working directory —
subscription id, tenant id, client id, client secret, plus the `storage_url`
where your Terraform state is kept. Upload it (or paste the
four values) in the Cielara deploy form, then treat it like a password.

## Infra-version marker

The apply also creates a tiny storage account (`cielarainfra<hash>`, resource
group `cielara-infra-version-<cielara-client-id>`) with a single
`version.json` blob recording which version of this module ran (`0.0.0-dev`
on an untagged checkout). The deployer service principal gets **Storage Blob
Data Reader** on just this account so the Cielara control plane can tell the
prepare vintage without asking you.

To confirm the deployer can actually read it, log in as the service principal
(values from `cielara-creds.json`) and download the blob:

```bash
az login --service-principal -u <client_id> -p <client_secret> --tenant <tenant_id>
az storage blob download --auth-mode login \
  --account-name "$(terraform output -raw infra_version_storage_account)" \
  --container-name infra-version --name version.json --file version-check.json
cat version-check.json
```

Azure RBAC data-plane grants can take a few minutes to propagate — an
authorization error right after the apply usually just means retry. If your
subscription enforces the "storage accounts should prevent shared key
access" policy, exempt this account: the Terraform provider uploads the blob
via a listKeys-issued key (the deployer read itself uses Entra RBAC).

### Resource providers

The deploy needs these resource providers registered on the subscription
(most already are; the module does not manage registrations):

```bash
for ns in Microsoft.Network Microsoft.ContainerService Microsoft.Compute \
  Microsoft.DBforPostgreSQL Microsoft.KeyVault Microsoft.Storage \
  Microsoft.ManagedIdentity; do
  az provider register --namespace "$ns"
done
```

## State is a credential

The Terraform state contains the service principal's client secret.

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
  backend "azurerm" {
    resource_group_name  = "<your-rg>"
    storage_account_name = "<your-storage-account>"
    container_name       = "tfstate"
    key                  = "cielara-prepare-aks.tfstate"
  }
}
```

Any backend pointing at storage you own works — the other clouds' backends
are just as good. Adding it after a local-state apply: run `terraform init
-migrate-state` once.

## Already prepared with the script, or lost your state?

Azure object ids are random (unlike the deterministic GCP names), so the
migration path needs a discovery step first:

```bash
terraform init    # downloads the module; the script rides along inside it
.terraform/modules/cielara_prepare/discover-migrate.sh <your-cielara-client-id>
terraform plan
```

The script writes `migrate.auto.tfvars`. Values in that file only reach the
module through matching root-level `variable` blocks — the Cielara-generated
migrate `main.tf` declares them and passes them through, and it also carries
the adoption `import` blocks (keyed on this module's `probe_*` outputs);
Terraform only allows import blocks in the root module, so they cannot ship
inside this one. Writing the call by hand instead: copy the discovered
values into the module block (`migrate_app_object_id`,
`migrate_sp_object_id`, `migrate_contributor_assignment_id`,
`migrate_rbac_admin_assignment_id`, plus `migrate = true` and
`create_secret = false`) and copy the import blocks from the generated
file too.

Check the plan: it must show only imports plus new creations (the
`cielara-creds.json` handback and, unless an earlier module run already
created them, the infra-version resources — the module checks for those via
`check-version-marker.sh` at plan time; the generated file's import blocks
adopt what exists) — nothing changed, nothing destroyed. Two exceptions are expected: the `version.json` blob is
re-uploaded on adoption (one replace — its content is not readable back), and
if the plan wants to **replace** a role assignment on the *subscription*
scope, stop: the ABAC condition drifted (Azure replaces an assignment on any
condition change, even whitespace). Then:

```bash
terraform apply
terraform plan   # must print: No changes.
```

Your existing client secret keeps working (`create_secret = false` is set by
the discover script), and active Cielara deployments are untouched. The
apply still writes `cielara-creds.json` — without the `client_secret` field,
since Azure cannot read an existing secret back — so you can paste it in the
deploy form and only fill the secret manually.

## Rotating or revoking the JWT signing key

Rotation needs `az keyvault key rotate --vault-name <vault> --name jwt-signing`
and nothing else. Key Vault keeps the earlier versions, so tokens already issued
keep verifying until you disable the version they were signed with. The data
plane picks the new version up within its ~5-minute key cache.

Prefer a schedule? Set `jwt_key_auto_rotation_months` (any whole number of
months) and re-apply: a Key Vault rotation policy mints a new version that
long after each version's creation, with no expiry — earlier versions stay
enabled and the versionless key reference keeps resolving to the newest.
Setting it back to 0 stops managing the policy but leaves the last one on the
key; overwrite it with `az keyvault key rotation-policy update` if you want
it gone.

Revoking a version needs it disabled:
`az keyvault key set-attributes --vault-name <vault> --name jwt-signing --version <ver> --enabled false`.
It leaves the published key set at the next cache refresh, and tokens signed
with it stop verifying.

Cielara can do neither: the deployer service principal holds no role on this
vault, and its RBAC-admin grant is conditioned to a role allowlist that excludes
Key Vault Crypto roles, so it cannot grant itself one. The vault name is in the
`jwt_signing_key_url` output.

## Rotating the client secret

Secret rotation stays an explicit action through the Cielara credential-edit
UI — do not rotate by re-running this module: the control plane holds the
current secret, and replacing it out-of-band breaks the deployment's stored
credential.

## TLDR / CLI

```bash
mkdir cielara-prepare-aks && cd cielara-prepare-aks
# Download the generated main.tf from the Cielara deploy form into this folder.

az login && az account set --subscription <SUBSCRIPTION_ID>

terraform init

# Already prepared (script or lost state)? Use the deploy form's "already
# prepared" toggle, then run the discovery step (Windows: through Git Bash):
#   .terraform/modules/cielara_prepare/discover-migrate.sh <CIELARA_CLIENT_ID>

terraform plan     # migrating: only imports + the marker additions, 0 destroy
terraform apply
terraform plan     # must print: No changes.
# handback: cielara-creds.json -> Cielara deploy form
```
