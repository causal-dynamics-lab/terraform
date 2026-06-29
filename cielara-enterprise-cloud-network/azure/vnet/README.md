# Cielara Enterprise Cloud Network - Azure

Provisions the Azure networking Cielara Enterprise needs, in **your**
subscription with **your** credentials. After apply you hand a small JSON blob
of resource IDs back to Cielara; the Cielara Enterprise deployment then runs
*into* this network instead of creating its own.

## What it creates

In a resource group **you already own** (this module adopts it, never creates
or deletes it):

| Resource | Notes |
|----------|-------|
| VNet | `vnet_cidr`, default `10.2.0.0/20` |
| `user-subnet` `/22` | Kubernetes user/workload node pools + pods; `Microsoft.Storage` service endpoint |
| `system-subnet` `/24` | Kubernetes system node pool; `Microsoft.Storage` service endpoint |
| `appgw-subnet` `/26` | dedicated Application Gateway subnet |
| `postgres-subnet` `/28` | delegated to `Microsoft.DBforPostgreSQL/flexibleServers` |
| `pe-subnet` `/26` | private endpoints (network policies disabled); ~59 usable IPs; consumed by the sibling `private-endpoints` module for egress to remote private AKS clusters |
| NAT gateway + public IP | outbound for the private node subnets, associated to system+user |

It does **not** create the Kubernetes cluster, Postgres server, Key Vault,
storage account, or the Postgres private DNS zone — Cielara creates those after
handback as part of your Cielara Enterprise deployment.

## Prerequisites

- An existing resource group; note its **name** and **region**.
- `Contributor` (or finer) on that RG so Terraform can create network resources.
- Terraform `>= 1.5`, the `azurerm` provider (`~> 4.77`, fetched by `init`).
- Either a service principal (`subscription_id`/`tenant_id`/`azure_client_id`/
  `azure_client_secret`) **or** `az login`.

## Run

```bash
cd azure/vnet
cp terraform.tfvars.example terraform.tfvars   # then edit it
terraform init
terraform plan
terraform apply
```

## Hand back to Cielara

```bash
terraform output -raw handback
```

Copy the JSON it prints and send it to Cielara. Shape:

```json
{
  "resource_group_name": "my-cielara-rg",
  "location": "eastus2",
  "vnet_name": "cielara-vnet",
  "system_subnet_name": "system-subnet",
  "user_subnet_name": "user-subnet",
  "appgw_subnet_name": "appgw-subnet",
  "postgres_subnet_name": "postgres-subnet"
}
```

## Role assignments

You don't grant anything from this module — it needs no IAM permissions. The
Cielara deployment service principal is granted everything it needs (including
the access to operate on this VNet — the Postgres private-DNS vnet-link and the
Kubernetes control-plane / Application Gateway role assignments) **once** by
`prepare-aks.sh`, which an IAM administrator runs as a single setup step. The
network administrator running this module needs only `Contributor` on the
resource group.

## CIDR note

`vnet_cidr` must not overlap Cielara Enterprise's Kubernetes service CIDR
`10.1.0.0/16` (the module validates this). The default `10.2.0.0/20` is safe.
The subnet ranges are derived automatically and must not be changed —
Cielara Enterprise's cluster, Postgres VNet-injection, and Azure Files mounts
depend on this exact layout. The `pe-subnet` (`10.2.8.0/26` for the default
`/20`, ~59 usable IPs) is carved from the free `10.2.8.0/21` tail and feeds the
sibling `private-endpoints` module.
