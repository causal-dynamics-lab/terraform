# Cielara Enterprise Cloud Network - AWS

> Published to the Terraform Registry as
> [`causal-dynamics-lab/cielara-network/aws`](https://registry.terraform.io/modules/causal-dynamics-lab/cielara-network/aws/latest)
> via the read-only mirror repo `terraform-aws-cielara-network`.
> Development, history, and issues:
> [causal-dynamics-lab/terraform](https://github.com/causal-dynamics-lab/terraform).

Provisions the AWS networking Cielara Enterprise needs, in **your** account
with **your** credentials. After apply you hand a small JSON blob of resource
IDs back to Cielara; the Cielara Enterprise deployment then runs *into* this
VPC instead of creating its own.

## What it creates

| Resource | Notes |
|----------|-------|
| VPC | `vpc_cidr`, default `10.2.0.0/20`; DNS hostnames + support enabled (EKS requirement) |
| 2 private subnets (`+2` bits, `/22` each for a `/20`) | **all** EKS nodes + pods, RDS, EFS; tagged `kubernetes.io/role/internal-elb=1`; one per AZ |
| 2 public subnets (`+6` bits, `/26` each for a `/20`) | NAT gateways + internet-facing load balancers only — no nodes; tagged `kubernetes.io/role/elb=1`; one per AZ |
| Internet gateway | egress for the public subnets |
| NAT gateway(s) + EIP(s) | egress for the private subnets; one shared (default) or one per AZ (`ha_nat = true`) |
| Route tables + associations | public → IGW, private → NAT |

It does **not** create the EKS cluster, RDS instance, EFS filesystem, load
balancers, security groups, or VPC peering to remote clusters — Cielara creates
those after handback as part of your Cielara Enterprise deployment. For reaching
**remote private EKS clusters** over peering, apply the bundled
[`remote-cluster-connectivity`](https://registry.terraform.io/modules/causal-dynamics-lab/cielara-network/aws/latest/submodules/remote-cluster-connectivity)
submodule after this one.

## Prerequisites

- An AWS account and a region choice (default `us-east-1`).
- Credentials able to create VPC resources (`ec2:*` on VPC/subnet/NAT/EIP/route
  resources) via the standard chain: environment variables, `AWS_PROFILE`, or SSO.
- Terraform `>= 1.5`, the `aws` provider (`~> 5.60`, fetched by `init`).

## Run

```hcl
provider "aws" {
  region = "us-east-1"
}

module "cielara_network" {
  source  = "causal-dynamics-lab/cielara-network/aws"
  version = "X.Y.Z" # pin an exact released version

  region = "us-east-1" # must match the provider block
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
  "region": "us-east-1",
  "vpc_id": "vpc-0123456789abcdef0",
  "private_subnet_ids": ["subnet-0aaa...", "subnet-0bbb..."],
  "public_subnet_ids": ["subnet-0ccc...", "subnet-0ddd..."]
}
```

Additional outputs for the `remote-cluster-connectivity` submodule:
`vpc_cidr`, `private_route_table_ids` — wire them straight from the module
call (see the submodule's README).

## Bringing a VPC you already have

You can skip this module entirely and hand back IDs for an existing VPC, as
long as it satisfies the same contract:

- **Two private subnets in two distinct AZs**, each tagged
  `kubernetes.io/role/internal-elb = 1`, with a working default route to a NAT
  gateway (or equivalent egress) — nodes pull container images and reach AWS
  APIs from these subnets.
- **Two public subnets in two distinct AZs**, each tagged
  `kubernetes.io/role/elb = 1`, with a route to an internet gateway and
  auto-assigned public IPs.
- **VPC DNS hostnames and DNS support enabled.**
- Enough free IP space in the private subnets for the node pools plus pods
  (the AWS VPC CNI assigns pod IPs from the node subnets) — a `/22` per subnet
  is the recommended floor. All nodes run in the private subnets; the public
  pair only hosts NAT gateways and load balancers.

The `kubernetes.io/role/*` tags are how the in-cluster AWS Load Balancer
Controller discovers where to place load balancers. The cluster-scoped tag
(`kubernetes.io/cluster/<name> = shared`) is added to your subnets by the
Cielara deployment itself — the cluster name is generated at deploy time — and
removed again on teardown. Nothing else on your VPC is modified.

## IAM

You don't grant anything from this module — it needs no IAM permissions beyond
EC2. The Cielara deployer role is granted everything it needs (including
describing and tagging these subnets) **once** by `prepare-eks.sh`, which an
IAM administrator runs as a single setup step.

## CIDR note

`vpc_cidr` must be `/20` or larger (the module validates this — smaller blocks
carve public subnets below `/27`, the AWS ALB minimum, and starve the node
subnets of pod IP space). The subnet ranges are derived automatically: private
`/22` + `/22`, public `/26` + `/26` for the default `/20`, with the tail left
free for growth. EKS auto-selects a Kubernetes service CIDR disjoint from your
VPC, so no service CIDR coordination is needed. If you also run the Azure
module (default `10.2.0.0/20`) and ever plan to peer the two networks, give
one of them a different range — the defaults collide by design only because
each cloud is normally an island.
