# Cielara AKS prepare

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

```bash
cd cielara-prepare/aks
# Download the pre-filled terraform.tfvars from the Cielara deploy form
# (it carries your Cielara client id), or copy terraform.tfvars.example.
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
  backend in your own cloud account — see `backend.tf`.
- **Keep the state.** Cielara occasionally extends the prepare resource set;
  re-applying this module (at the version the Cielara UI links) picks the
  additions up in place.
- Lost the state? Re-adopt the existing resources with `migrate = true`
  (see below) — do not delete or recreate anything.

## Already prepared with the script, or lost your state?

Azure object ids are random (unlike the deterministic GCP names), so the
migration path needs a discovery step first:

```bash
./discover-migrate.sh <your-cielara-client-id>   # writes migrate.auto.tfvars
terraform init
terraform plan
```

Check the plan: it must show only imports plus new creations (the
`cielara-creds.json` handback and, unless discover-migrate.sh found them from
an earlier module run, the infra-version resources) — nothing changed,
nothing destroyed. Two exceptions are expected: the `version.json` blob is
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

## Rotating the client secret

Secret rotation stays an explicit action through the Cielara credential-edit
UI — do not rotate by re-running this module: the control plane holds the
current secret, and replacing it out-of-band breaks the deployment's stored
credential.
