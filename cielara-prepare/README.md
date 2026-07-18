# Cielara prepare modules

Terraform modules that prepare your cloud account for a Cielara deployment —
the identity the Cielara control plane deploys as, its permissions, and the
supporting resources. One root module per deployment target:

| Module | Deployment target |
|---|---|
| [`gke/`](gke/) | Google Kubernetes Engine |

(GCP VM, EKS, AKS, and AWS VM follow the same pattern and are published as
they land.)

Each module is self-contained: `cd` into it, provide a `terraform.tfvars` (the
Cielara deploy form serves a pre-filled one), then `terraform init && terraform
apply`. The apply writes a handback file (`cielara-key.json` or
`cielara-creds.json`) that you upload back in the Cielara deploy form.

These modules replace the `prepare-*.sh` / `prepare-*.ps1` scripts and create
byte-identical resources; use one or the other, not both. See each module's
README for specifics, including why the Terraform state must stay in your
custody.
