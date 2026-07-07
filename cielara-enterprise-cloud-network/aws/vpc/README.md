# Cielara Enterprise Cloud Network - AWS

Provisions the AWS networking Cielara Enterprise needs, in **your** account
with **your** credentials. After apply you hand a small JSON blob of resource
IDs back to Cielara; the Cielara Enterprise deployment then runs *into* this
VPC instead of creating its own.

## What it creates

| Resource | Notes |
|----------|-------|
| VPC | `vpc_cidr`, default `10.0.0.0/16`; DNS hostnames + support enabled (EKS requirement) |
| 2 private subnets (`+4` bits, `/20` each for a `/16`) | EKS nodes + pods, RDS, EFS; tagged `kubernetes.io/role/internal-elb=1`; one per AZ |
| 2 public subnets (`+8` bits, `/24` each for a `/16`) | internet-facing load balancers; tagged `kubernetes.io/role/elb=1`; one per AZ |
| Internet gateway | egress for the public subnets |
| NAT gateway(s) + EIP(s) | egress for the private subnets; one shared (default) or one per AZ (`ha_nat = true`) |
| Route tables + associations | public → IGW, private → NAT |

It does **not** create the EKS cluster, RDS instance, EFS filesystem, load
balancers, or security groups — Cielara creates those after handback as part
of your Cielara Enterprise deployment.

## Prerequisites

- An AWS account and a region choice (default `us-east-1`).
- Credentials able to create VPC resources (`ec2:*` on VPC/subnet/NAT/EIP/route
  resources) via the standard chain: environment variables, `AWS_PROFILE`, or SSO.
- Terraform `>= 1.5`, the `aws` provider (`~> 5.60`, fetched by `init`).

## Run

```bash
cd aws/vpc
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
  "region": "us-east-1",
  "vpc_id": "vpc-0123456789abcdef0",
  "private_subnet_ids": ["subnet-0aaa...", "subnet-0bbb..."],
  "public_subnet_ids": ["subnet-0ccc...", "subnet-0ddd..."]
}
```

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
  (the AWS VPC CNI assigns pod IPs from the node subnets) — a `/20` per subnet
  is the recommended floor.

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

`vpc_cidr` must be `/19` or larger (the module validates this — smaller blocks
carve public subnets below `/27`, the AWS ALB minimum). The subnet ranges are
derived automatically and must not be changed — the layout is byte-identical
to the network Cielara Enterprise creates when no VPC is handed back. EKS
auto-selects a Kubernetes service CIDR disjoint from your VPC, so no service
CIDR coordination is needed.
