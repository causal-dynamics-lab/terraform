# Cielara Enterprise Cloud Network

Terraform module that provisions a cloud VPC/VNet and related networking resources to support a Cielara Enterprise deployment.

## How this fits into a Cielara Enterprise deployment

After you sign up for Cielara Enterprise, Cielara provisions your environment
(Kubernetes cluster, database, ingress, and related services) into **your**
cloud account. This Terraform module is the first step on your side: it creates
the VPC/VNet and subnets Cielara Enterprise needs before that deployment can
run.

You run this module in your own subscription with your own credentials. When it
finishes, you send Cielara a small JSON blob of resource IDs (`handback`).
Cielara then deploys Cielara Enterprise **into** that network instead of
creating one for you.

### Steps

1. **Clone this repository**

   ```bash
   git clone git@<repo>
   cd cielara-enterprise-cloud-network
   ```

2. **Choose your cloud provider** and change into that module's directory
   (today only Azure is published; AWS and GCP will follow the same pattern):

   ```bash
   cd <cloud>   # e.g. azure
   ```

3. **Configure and apply** — copy `terraform.tfvars.example` to
   `terraform.tfvars`, fill in your subscription details (resource group,
   region, credentials), then run `terraform init` and `terraform apply`.

4. **Hand the output back to Cielara**

   ```bash
   terraform output -raw handback
   ```

   Send the printed JSON to Cielara. Once they have it, they start (or
   continue) your Cielara Enterprise deployment into the network you just
   created.

The repo holds **no Cielara secrets**. Each cloud module is self-contained
(its own provider + auth), so you only need credentials for the cloud you run.

## Deployment Instructions

A `terraform.tfvars` file is optional. You can pass every variable on the
command line with `-var`, or point at a file with `-var-file`. Example for
`azure/`:

```bash
cd azure
terraform init

terraform apply \
  -var='subscription_id=00000000-0000-0000-0000-000000000000' \
  -var='tenant_id=00000000-0000-0000-0000-000000000000' \
  -var='resource_group_name=my-cielara-rg' \
  -var='location=eastus2'
# optional: -var='vnet_cidr=10.2.0.0/20'
#           -var='cielara_client_id=<client id Cielara gave you>'

# then hand the IDs back to Cielara
terraform output -raw handback
```

`terraform plan` takes the same `-var` flags. A non-default `-var-file` works
too: `terraform apply -var-file=prod.tfvars`.

> **Secrets on the command line are recorded in your shell history** (and can be
> visible in the process list). For `azure_client_secret`, prefer an
> environment variable instead of `-var`:
>
> ```bash
> export TF_VAR_azure_client_secret='...'   # Terraform reads TF_VAR_<name> automatically
> # or rely on `az login` and omit azure_client_id/azure_client_secret entirely
> ```
>
> Any variable can be supplied this way: `export TF_VAR_subscription_id=...`.

## Clouds

| Dir | Status |
|-----|--------|
| [`azure/`](azure/) | **Available** — Azure VNet + subnets + NAT for Cielara Enterprise |

AWS and GCP modules are planned but not yet published here — they'll land as
sibling `aws/` and `gcp/` directories following the same contract.

The module creates the network, then exposes a single `handback` output (JSON)
of the resource IDs the Cielara Enterprise deployment uses.

## What's NOT here

The Kubernetes cluster, database, ingress, secret store, and storage are
created by Cielara *after* handback as part of your Cielara Enterprise
deployment. This module creates only the network. It adopts an existing resource
group / VNet and never deletes network infrastructure you own.

See [`azure/README.md`](azure/README.md) for prerequisites, run steps, and the
handback shape.
