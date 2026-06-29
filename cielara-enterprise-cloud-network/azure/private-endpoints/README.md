# Cielara Enterprise Cloud Network - Azure Private Endpoints

Creates private endpoints in the Cielara VNet so the Kubernetes cluster running
there can reach **remote private AKS clusters** over Azure Private Link instead
of the public internet. Runs **after** the `vnet` module (it adopts that VNet,
resource group, and `pe-subnet` by name) and is driven by a map of remote
clusters, so adding the next 2-3 clusters is one more map entry — no new code.

## What it creates

In the resource group and `pe-subnet` provisioned by the `vnet` module
(adopted, never created here):

| Resource | Per | Notes |
|----------|-----|-------|
| `azurerm_private_endpoint` | cluster | connects to the remote AKS **managed cluster** resource via the `management` subresource (the API server has no standalone PLS); auto-approves by default |
| `azurerm_private_dns_zone` | region | `privatelink.<region>.azmk8s.io`; clusters in the same region share one zone |
| `azurerm_private_dns_zone_virtual_network_link` | region | links the zone to the Cielara VNet so pods resolve the remote API FQDN |
| `azurerm_private_dns_a_record` | cluster | remote API host → this endpoint's private IP |

It creates **no** VNet, subnet, or the remote clusters — those exist already.

> The remote cluster **must be a private cluster** (`--enable-private-cluster`).
> A public cluster has no private API endpoint to connect to.

## Prerequisites

- The `vnet` module applied; copy its `resource_group_name`, `vnet_name`, and
  `pe_subnet_name` outputs into `terraform.tfvars`.
- For each remote cluster: its managed-cluster **resource ID** and **private API
  FQDN** (see `terraform.tfvars.example` for the `az` commands).
- `Contributor` on the resource group; for auto-approval, approval rights on the
  remote cluster (same tenant/owner). Terraform `>= 1.5`, `azurerm ~> 4.77`.

## Run

```bash
cd azure/private-endpoints
cp terraform.tfvars.example terraform.tfvars   # then edit it
terraform init
terraform plan
terraform apply
```

## Connection approval

By default (`is_manual_connection = false`) the connection **auto-approves** when
the identity running Terraform has approval rights on the remote cluster (same
tenant / owner) — nothing else to do.

For **cross-tenant** set `is_manual_connection = true` per cluster; the endpoint
then stays `Pending` until the remote cluster's owner approves it:

```bash
# list connections on the remote managed cluster
az network private-endpoint-connection list \
  --id <remote-cluster-id> -o table

# approve
az network private-endpoint-connection approve \
  --id <remote-cluster-connection-id> \
  --description "approved for Cielara"
```

The Pending/Approved state lives on the producer side, so check it there
(`az network private-endpoint-connection show`), not via a Terraform output.
Once approved, the remote API FQDN resolving from the VNet to the endpoint IP
(`terraform output private_endpoint_ips`) confirms the link is live.

## Adding more clusters

Append another entry to `remote_clusters` in `terraform.tfvars` and re-apply.
The map key is the `for_each` key — keep existing keys stable (renaming a key
destroys and recreates that endpoint).
