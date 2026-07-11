# Cielara Enterprise Cloud Network - AWS Remote Cluster Connectivity

Creates VPC peering and private DNS in the Cielara VPC so the Kubernetes cluster
running there can reach **remote private EKS clusters** over private networking
instead of the public internet. Runs **after** the `vpc` module (it adopts that
VPC and private route tables by ID) and is driven by a map of remote clusters, so
adding the next 2-3 clusters is one more map entry — no new code.

## What it creates

In the Cielara VPC adopted from the `vpc` module:

| Resource | Per | Notes |
|----------|-----|-------|
| `aws_vpc_peering_connection` | cluster | links Cielara VPC to the remote cluster VPC (same-account, auto-accepted in v1) |
| `aws_vpc_peering_connection_options` | cluster | enables DNS resolution across the peering link (both sides) |
| `aws_route` (consumer) | route table × cluster | remote VPC CIDR → peering connection in each Cielara private route table |
| `aws_route` (remote return) | optional | `vpc_cidr` → peering on remote route tables when `remote_route_table_ids` is set |
| `aws_route53_zone` + `aws_route53_record` | cluster | API hostname → control-plane ENI private IP(s) in the consumer VPC |

It creates **no** VPC, subnets, or remote clusters — those exist already.

> The remote cluster **must have private API access enabled**
> (`endpointPrivateAccess = true`). A cluster with only a public API endpoint is
> reachable over the internet, not via this module.

## Prerequisites

- The `vpc` module applied; copy its `vpc_id`, `vpc_cidr`, `private_route_table_ids`,
  and `region` outputs into `terraform.tfvars`.
- For each remote cluster: its name, VPC ID, VPC CIDR, and API endpoint hostname
  (see `terraform.tfvars.example` for the `aws` commands).
- **Non-overlapping CIDRs** between the Cielara VPC and each remote VPC (the
  default Cielara `10.2.0.0/20` collides if the remote VPC uses the same range).
- IAM able to create peering connections, routes, and Route 53 private zones in
  the consumer account; for ENI auto-discovery, `ec2:DescribeNetworkInterfaces`
  in the remote cluster's account (same account as the consumer in v1).
- Terraform `>= 1.9` (validations reference `vpc_cidr` / `region` from inside `remote_clusters`), `aws` provider `~> 5.60`.

## Run

```bash
cd aws/remote-cluster-connectivity
cp terraform.tfvars.example terraform.tfvars   # then edit it
terraform init
terraform plan
terraform apply
```

## Remote cluster owner responsibilities

Even when this module manages consumer-side routes and DNS, the **remote cluster
owner** must ensure:

1. **Return routes** — remote private route tables route the Cielara `vpc_cidr`
   back over the peering connection (set `remote_route_table_ids` per cluster
   when you manage both VPCs in the same account, or add routes out of band).
2. **Security group** — the EKS cluster control plane security group allows
   inbound **TCP 443** from the Cielara `vpc_cidr`.
3. **Private API** — `endpointPrivateAccess` enabled on the remote cluster.

Once applied, the remote API hostname resolving from the Cielara VPC to the
expected private IP(s) (`terraform output api_endpoint_ips`) confirms DNS is
wired; `curl -sk https://<api_endpoint>/healthz` from a pod in the consumer
cluster confirms the path is live.

## ENI discovery vs manual IPs

By default (`discover_endpoint_ips = true`), Terraform looks up control-plane ENI
private IPs in the remote VPC (description `Amazon EKS <cluster-name>`). This
requires **same-account** access.

For **cross-account** (Phase 2), set `discover_endpoint_ips = false` and supply
`api_endpoint_ips` manually after looking up the ENI IPs on the producer side.

## Adding more clusters

Append another entry to `remote_clusters` in `terraform.tfvars` and re-apply.
The map key is the `for_each` key — keep existing keys stable (renaming a key
destroys and recreates that peering connection and DNS zone).

## v1 limitations

- **Same region only** — `cluster_region` must match `var.region`.
- **Same account only** — cross-account peering and PHZ association are Phase 2.
- **API server reachability only** — not pod-to-pod mesh between clusters.
- **Static DNS A records** — control-plane ENI private IPs can change when AWS
  upgrades or scales the remote EKS control plane. The Route 53 A record in this
  module is refreshed on `terraform apply` only; after a remote upgrade, re-apply
  (or supply updated `api_endpoint_ips`) if API calls start failing or timing
  out. Phase 2 may add Route 53 Resolver outbound forwarding to the remote VPC
  for live DNS instead of pinned A records.
