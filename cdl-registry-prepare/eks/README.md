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
| KMS key + alias | `alias/cielara-jwt-signing` | Customer-owned JWT signing key (ECC P-256) — its key policy explicitly denies the Cielara deployer roles sign and key administration. One key per `jwt_key_generation`; the alias targets the newest. See "Rotating or revoking the JWT signing key" |
| Credentials file | `cielara-creds.json` | The handback — upload it in the Cielara deploy form (written on fresh prepare and adoption alike) |

The role is named per tenant: each Cielara tenant onboarding into the same
AWS account gets its own role and trust policy. The KMS key is regional
(created in your active `AWS_REGION`) and shared across Cielara tenants in
the account.

## Usage

Requires Terraform >= 1.7 and an AWS identity with IAM-write permissions in
the target account (an `AdministratorAccess` identity, or one scoped to
`arn:aws:iam::*:role/cielara_eks_deployer_*`):

```bash
aws configure sso                    # one-time SSO setup
aws sso login --profile <your-profile>
export AWS_PROFILE=<your-profile>    # or static keys via: aws configure
export AWS_REGION=<region>           # see "Pick a region and keep it"
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

## Pick a region and keep it

The deployer role is global, but the JWT signing key and the infra-version
bucket below are both regional, so the region this module runs in becomes part
of the account's state. `region` is required in `terraform.tfvars` — it is no
longer inferred from `AWS_REGION`, because an operator's shell silently
deciding where the signing key lives is exactly the failure it prevents: the
key's alias ARN is regional and the control plane builds it from the deploy
form's region, so a mismatch fails at the first login. Keep it identical on
every run —
otherwise a later apply from a differently-pointed shell tries to create the
bucket again in the new region and fails with:

```
Error: creating S3 Bucket (cielara-infra-version-<client-id>): api error
AuthorizationHeaderMalformed: The authorization header is malformed;
the region 'us-east-1' is wrong; expecting 'us-east-2'
```

The region S3 says it is "expecting" is where the bucket already lives. Set
`region` to that value. With `migrate = true` the existence check reports the
same mismatch up front, naming the region to set.

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

The role imports derive from your Cielara client id and the JWT signing key
resolves through its alias, so there is no discovery step — set one variable:

```bash
echo 'migrate = true' >> terraform.tfvars
terraform init
terraform plan
```

Check the plan: it must show only the 2 imports plus new creations (the
`cielara-creds.json` handback and the infra-version bucket resources, which
postdate the scripts) — nothing changed, nothing destroyed. If an earlier run
of this module already created the infra-version bucket (lost state), the
module detects that and imports the bucket too — the check runs `aws s3api
head-bucket` via `check-version-marker.sh`, so migrations need the AWS CLI
authenticated. Then:
Adopting an account prepared **before the JWT signing key existed**? Re-run

```bash
terraform apply
terraform plan   # must print: No changes.
```

Active Cielara deployments are untouched — the role and its trust policy
are adopted exactly as they are.

## Rotating or revoking the JWT signing key

**Rotation needs `jwt_key_generation` incremented, and nothing else.** The
variable names the live generation; the alias always targets the highest one.

```hcl
jwt_key_generation = 2   # terraform.tfvars — was 1
```

Everything a rotation has to get right comes with that: the new ECC P-256 key
carries the deployer-Deny key policy and the `cielara-jwt-signing` tag the data
plane's signer is authorised against, and `alias/cielara-jwt-signing` moves to
it. Cielara is not involved and cannot perform or undo it. The data plane
begins signing with the new key within its ~5-minute key cache.

**A rollback needs the number decremented** — earlier generations stay enabled
precisely so that stays possible. The generation you drop is scheduled for
deletion, recoverable inside the KMS deletion window.

**Revoking a generation needs it disabled**, which drops it from the data
plane's published keys at the next cache refresh:
`aws kms disable-key --key-id <arn from jwt_signing_key_arns_by_generation>`.

**Rotation needs no hand-made keys.** A key created with the AWS CLI gets AWS's
default key policy, which delegates to account IAM where the Cielara deployer
roles hold `kms:*` — that hands Cielara the ability to sign as you. It also
lacks the tag the signer is authorised against, so signing stops instead.

Sessions issued before a rotation need a fresh login, a few minutes later, once
every verifier's key cache has turned over. Nothing else is affected.

## Revoking access

```bash
terraform destroy
```

removes the role and its policy; the Cielara control plane immediately
loses access to the account. Only do this for deployments you have already
destroyed through Cielara. The JWT signing key is not deleted instantly: destroy
schedules its deletion with AWS KMS's mandatory waiting period, so the alias and
key linger until it elapses.

## TLDR / CLI

```bash
git clone https://github.com/causal-dynamics-lab/terraform.git
cd terraform && git checkout <TAG>        # the tag the Cielara deploy form names
cd cielara-prepare/eks

aws sso login --profile <profile> && export AWS_PROFILE=<profile>
export AWS_REGION=<region>

# Download the pre-filled terraform.tfvars from the Cielara deploy form
# (or copy terraform.tfvars.example and edit it).

# Already prepared (script or lost state)? Add:
#   echo 'migrate = true' >> terraform.tfvars

terraform init
terraform plan     # migrating: only imports + the marker additions, 0 destroy
terraform apply
terraform plan     # must print: No changes.
# handback: cielara-creds.json -> Cielara deploy form (or `terraform output -raw role_arn`)
```
