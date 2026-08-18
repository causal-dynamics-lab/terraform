# Cielara Enterprise Cloud Network - GCP

Provisions the GCP networking Cielara Enterprise needs, in **your** project
with **your** credentials. After apply you hand a small JSON blob of resource
handles back to Cielara; the Cielara Enterprise deployment then runs *into*
this VPC instead of creating its own.

## What it creates

| Resource | Notes |
|----------|-------|
| Custom-mode VPC | `<name_prefix>-vpc`; no auto subnets |
| Regional subnet | `gke_subnet_cidr`, default `10.10.0.0/20`; private Google access ON (private nodes reach Google APIs through it) |
| Secondary range `pods` | `pods_cidr`, default `10.11.0.0/16` — VPC-native GKE assigns pod IPs from it (a /24 per node), so it stays large |
| Secondary range `services` | `services_cidr`, default `10.12.0.0/20` |
| Cloud NAT + static IP | `<name_prefix>-nat` / `<name_prefix>-nat-ip`; single stable egress address (the handback's `nat_ip`) |
| Cloud Router | carries the NAT |

It does **not** create the GKE cluster, Cloud SQL instance, ingress IP/SSL, or
firewalls (GKE manages its own), and it does **not** reserve the Cloud SQL
Private Service Access range — Cielara adds that post-handback (its name embeds
the deploy-time cluster name; default `10.96.0.0/16`, overridable on the deploy
form if it collides with your address space).

## Prerequisites

- A GCP project and a region choice (default `us-central1`) — the **same
  project and region** you use on the Cielara deploy form.
- Credentials able to create network resources (`roles/compute.networkAdmin`
  or equivalent) via Application Default Credentials (`gcloud auth
  application-default login`) or a service-account key (`credentials_file`).
- Terraform `>= 1.5`, the `google` provider (`~> 5.0`, fetched by `init`).

## Run

```bash
cd gcp/vpc
cp terraform.tfvars.example terraform.tfvars   # then edit it
terraform init
terraform plan
terraform apply
```

## Hand back to Cielara

```bash
terraform output -raw handback
```

Copy the JSON it prints and send it to Cielara (or paste the fields into the
deploy form's Network Settings). Shape:

```json
{
  "project_id": "my-gcp-project",
  "region": "us-central1",
  "vpc_self_link": "https://www.googleapis.com/compute/v1/projects/my-gcp-project/global/networks/cielara-vpc",
  "gke_subnet_self_link": "https://www.googleapis.com/compute/v1/projects/my-gcp-project/regions/us-central1/subnetworks/cielara-gke-subnet",
  "pods_range_name": "pods",
  "services_range_name": "services",
  "nat_ip": "34.0.0.0"
}
```

`nat_ip` is required on the deploy form when the deployment uses Cielara's
managed RabbitMQ — the broker's firewall admits exactly that address.

## Bringing a VPC you already have

You can skip this module entirely and hand back handles for an existing VPC,
as long as it satisfies the same contract (Cielara verifies it before the
deploy starts):

- **A regional subnet in the deploy region**, in the deploy project (Shared
  VPC host/service projects are not supported).
- **Two secondary ranges** on that subnet — one for pods, one for services —
  whose names you hand back (`pods`/`services` by convention). The pods range
  needs a `/24` per node of free space.
- **Private Google access enabled** on the subnet — nodes have no external
  IPs and reach Google APIs through it.
- **Working egress** (Cloud NAT or equivalent) with a stable IP you can hand
  back — Cielara never adds NAT capacity to an adopted VPC.
- Address space disjoint from `172.16.0.0/28` (the GKE master range) and from
  whatever Cloud SQL PSA range the deploy will reserve (default
  `10.96.0.0/16`).
