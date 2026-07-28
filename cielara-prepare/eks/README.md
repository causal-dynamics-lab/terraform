# Cielara EKS prepare

Prepares your AWS account for a Cielara EKS deployment. Creates one
cross-account IAM role the Cielara control plane assumes via STS — gated by
a per-tenant External ID — with a service-scoped inline policy covering
exactly what the EKS data plane provisions. No long-lived access keys leave
your account.

## What it creates

| Resource | Name | Purpose |
|---|---|---|
| IAM role | `cielara_eks_deployer_<cielara-client-id>` | Identity the Cielara control plane deploys as |
| Inline role policy | `cielara_eks_deployer_<cielara-client-id>` | Service-scoped grant (EKS, RDS, EFS, Secrets Manager, ACM, ELB + supporting EC2/IAM) — not AdministratorAccess; IAM management is fenced to Cielara-named resources |
| S3 bucket + object | `cielara-infra-version-<cielara-client-id>` / `version.json` | Version marker the Cielara control plane reads (deployer role gets read via a bucket policy) |
| Credentials file | `cielara-creds.json` | The handback — upload it in the Cielara deploy form (written on fresh prepare and adoption alike) |

The role is named per tenant: each Cielara tenant onboarding into the same
AWS account gets its own role and trust policy.

## Usage

Requires Terraform >= 1.7 and an AWS identity with IAM-write permissions in
the target account (an `AdministratorAccess` identity, or one scoped to
`arn:aws:iam::*:role/cielara_eks_deployer_*`):

```bash
aws configure sso                    # one-time SSO setup
aws sso login --profile <your-profile>
export AWS_PROFILE=<your-profile>    # or static keys via: aws configure
export AWS_REGION=<region>           # any region — the role is global
```

```bash
cd cielara-prepare/eks
# Download the pre-filled terraform.tfvars from the Cielara deploy form
# (it carries the control plane principal and your Cielara client id).
terraform init
terraform apply
```

The apply writes `cielara-creds.json` (holding the deployer role ARN and
the `storage_url` where your Terraform state is kept) into
the working directory — upload it in the Cielara deploy form to fill the
**Role ARN** field. `terraform output -raw role_arn` prints the same value
if you prefer to paste it.

## Infra-version marker

The apply also creates a tiny S3 bucket,
`cielara-infra-version-<cielara-client-id>`, holding a single `version.json`
that records which version of this module ran (`0.0.0-dev` on an untagged
checkout). A bucket policy grants the deployer role read on just this bucket
so the Cielara control plane can tell the prepare vintage without asking you.

There is no customer-side read check here: the role's trust policy only lets
the Cielara control plane assume it (by design), so the read is verified by
Cielara at deploy time.

## Keep your Terraform state

The state holds no secret — the role has no long-lived credential — but
keep it anyway:

- **Never send the state to Cielara** — Cielara never needs it.
- Local state is fine for a single operator. For a team, configure a remote
  backend in your own cloud account — see `backend.tf`.
- **Keep the state.** Cielara occasionally extends the prepare resource set;
  re-applying this module (at the version the Cielara UI links) picks the
  additions up in place.
- Lost the state? Re-adopt the existing resources with `migrate = true`
  (see below) — do not delete or recreate anything.

## Already prepared with the script, or lost your state?

Both import ids derive from your Cielara client id, so there is no
discovery step — set one variable:

```bash
echo 'migrate = true' >> terraform.tfvars
terraform init
terraform plan
```

Check the plan: it must show only the 2 imports plus new creations (the
`cielara-creds.json` handback and the infra-version bucket resources, which
postdate the scripts) — nothing changed, nothing destroyed. If the plan
instead fails with a bucket-already-exists error, an earlier run of this
module created the bucket: also set `migrate_version_bucket = true`. Then:

```bash
terraform apply
terraform plan   # must print: No changes.
```

Active Cielara deployments are untouched — the role and its trust policy
are adopted exactly as they are.

## Revoking access

```bash
terraform destroy
```

removes the role and its policy; the Cielara control plane immediately
loses access to the account. Only do this for deployments you have already
destroyed through Cielara.
