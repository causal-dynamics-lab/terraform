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
| `azurerm_private_endpoint` | cluster | manual connection to the remote API-server Private Link Service; starts **Pending** until approved |
| `azurerm_private_dns_zone` | region | `privatelink.<region>.azmk8s.io`; clusters in the same region share one zone |
| `azurerm_private_dns_zone_virtual_network_link` | region | links the zone to the Cielara VNet so pods resolve the remote API FQDN |
| `azurerm_private_dns_a_record` | cluster | remote API host → this endpoint's private IP |

It creates **no** VNet, subnet, or the remote clusters — those exist already.

## Prerequisites

- The `vnet` module applied; copy its `resource_group_name`, `vnet_name`, and
  `pe_subnet_name` outputs into `terraform.tfvars`.
- For each remote cluster: its API-server **Private Link Service ID** and
  **private API FQDN** (see `terraform.tfvars.example` for the `az` commands).
- `Contributor` on the resource group; Terraform `>= 1.5`, `azurerm ~> 4.77`.

## Run

```bash
cd azure/private-endpoints
cp terraform.tfvars.example terraform.tfvars   # then edit it
terraform init
terraform plan
terraform apply
```

## Approve the connection (required, manual)

Each private endpoint uses a **manual** connection, so it stays `Pending` until
the **remote** cluster's owner approves it. Until then, no traffic flows. On the
remote side:

```bash
# list pending connections on the remote API-server Private Link Service
az network private-endpoint-connection list \
  --id <remote-pls-id> -o table

# approve
az network private-endpoint-connection approve \
  --id <remote-pls-connection-id> \
  --description "approved for Cielara"
```

After approval, `terraform output connection_states` and DNS resolution from the
VNet confirm the link is live.

## Adding more clusters

Append another entry to `remote_clusters` in `terraform.tfvars` and re-apply.
The map key is the `for_each` key — keep existing keys stable (renaming a key
destroys and recreates that endpoint).
