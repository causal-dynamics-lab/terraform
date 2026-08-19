# Cielara Enterprise Cloud Network - Azure

> Published to the Terraform Registry as
> [`causal-dynamics-lab/cielara-network/azurerm`](https://registry.terraform.io/modules/causal-dynamics-lab/cielara-network/azurerm/latest)
> via the read-only mirror repo `terraform-azurerm-cielara-network`.
> Development, history, and issues:
> [causal-dynamics-lab/terraform](https://github.com/causal-dynamics-lab/terraform).

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
| `apiserver-subnet` `/27` | delegated to `Microsoft.ContainerService/managedClusters` — hosts the AKS API server endpoint (API Server VNet Integration), keeping node↔API-server traffic on your private network |
| `pe-subnet` `/26` | private endpoints (network policies disabled); ~59 usable IPs; consumed by the bundled `private-endpoints` submodule for egress to remote private AKS clusters |
| NAT gateway + public IP | outbound for the private node subnets, associated to system+user |

It does **not** create the Kubernetes cluster, Postgres server, Key Vault,
storage account, or the Postgres private DNS zone — Cielara creates those after
handback as part of your Cielara Enterprise deployment.

## Prerequisites

- An existing resource group; note its **name** and **region**.
- `Contributor` (or finer) on that RG so Terraform can create network resources.
- Terraform `>= 1.5`, the `azurerm` provider (`~> 4.77`, fetched by `init`).
- Auth comes from your root module's `provider "azurerm"` block: `az login`,
  `ARM_*` environment variables, or an explicit service principal — any
  azurerm auth method works.

## Run

```hcl
provider "azurerm" {
  features {}
  subscription_id = "<subscription id>"
}

module "cielara_network" {
  source  = "causal-dynamics-lab/cielara-network/azurerm"
  version = "X.Y.Z" # pin an exact released version

  resource_group_name = "my-cielara-rg"
  location            = "eastus2" # must match the resource group's region
}

output "handback" {
  value = module.cielara_network.handback
}
```

```bash
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
  "postgres_subnet_name": "postgres-subnet",
  "apiserver_subnet_name": "apiserver-subnet",
  "nat_gateway_name": "cielara-nat"
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
sibling `private-endpoints` module. The `apiserver-subnet` (`10.2.1.96/27` for
the default `/20`) is delegated to AKS for API Server VNet Integration — Azure
requires at least a `/28` and reserves 9+ IPs in it.
