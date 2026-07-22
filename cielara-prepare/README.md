# Cielara prepare modules

Terraform modules that prepare your cloud account for a Cielara deployment —
the identity the Cielara control plane deploys as, its permissions, and the
supporting resources. One root module per deployment target:

| Module | Deployment target |
|---|---|
| [`gke/`](gke/) | Google Kubernetes Engine |
| [`gcp/`](gcp/) | GCP virtual machine |

(EKS, AKS, and AWS VM follow the same pattern and are published as they
land.)

## Quick start

1. Clone this repository and enter the module for your deployment target:

   ```bash
   git clone https://github.com/causal-dynamics-lab/terraform.git
   cd terraform/cielara-prepare/gke
   ```

2. Download the pre-filled `terraform.tfvars` from the Cielara deploy form
   and place it in the module directory (or copy
   `terraform.tfvars.example` and fill it in).

3. Apply:

   ```bash
   terraform init
   terraform apply
   ```

4. The apply writes a handback file (`cielara-key.json` or
   `cielara-creds.json`) into the module directory. Upload it in the Cielara
   deploy form. Treat it like a password and delete it once uploaded — it can
   be regenerated from the module.

## Keep your Terraform state — and keep it safe

The state file is the module's memory of what it created, and with
`create_key = true` it **contains the deployer credential**. Three rules:

- **Keep it.** Cielara updates occasionally require re-running the prepare
  (new permissions, new resources). With the state present that is a plain
  `terraform apply`; without it you must re-adopt first (below).
- **Sync it to storage you own.** Local state works for a single operator on
  one machine. For a team — or to survive a lost laptop — use a remote
  backend in **your own** cloud: each module's `backend.tf` ships commented
  `gcs` / `s3` / `azurerm` examples. Uncomment one, point it at a versioned
  bucket you own, and run `terraform init` (add `-migrate-state` if you
  already applied with local state).
- **Never send it to Cielara.** Cielara never needs your state; nothing in
  the product asks for it, and no support flow requires it.

Preparing several accounts or projects? Use one working directory (and one
state) per project — copy the module directory rather than re-pointing a
single one.

## Already prepared, or lost your state?

If the account was prepared before — by an earlier run of this module whose
state is gone, or by any previous Cielara setup flow — the module **adopts**
the existing resources instead of failing on "already exists":

```hcl
# terraform.tfvars
project_id = "<your-project>"
migrate    = true
create_key = false   # your existing credential keeps working; nothing is rotated
```

```bash
terraform init
terraform plan
```

Check the plan before applying: it should show only imports (plus, at most,
cosmetic in-place updates such as a display name). **Anything being added or
destroyed means the account does not match what Cielara expects — stop and
contact support.** After `terraform apply`, a follow-up `terraform plan` must
print `No changes.`

## Notes

- Requires Terraform >= 1.7 and credentials with administrative rights on the
  target project/account (each module's README lists specifics).
- Applies are idempotent — re-running is always safe.
- Never run `terraform destroy` against a live Cielara deployment; the state
  owns the real identities the deployment runs as.

See each module's README for the exact resources created and
provider-specific details.
