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
| Role assignment | Role Based Access Control Administrator (subscription scope, ABAC-constrained) | Lets the deploy create its own role assignments — constrained to the exact roles the deploy uses, so it cannot self-escalate to Owner |
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
subscription id, tenant id, client id, client secret. Upload it (or paste the
four values) in the Cielara deploy form, then treat it like a password.

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

Check the plan: it must show only imports — nothing added, nothing
destroyed. (One exception: a role-assignment condition written by an older
setup can differ in whitespace and show a one-time in-place update; that is
cosmetic.) Then:

```bash
terraform apply
terraform plan   # must print: No changes.
```

Your existing client secret keeps working (`create_secret = false` is set by
the discover script), and active Cielara deployments are untouched.

## Rotating the client secret

Secret rotation stays an explicit action through the Cielara credential-edit
UI — do not rotate by re-running this module: the control plane holds the
current secret, and replacing it out-of-band breaks the deployment's stored
credential.
