# Cielara Terraform

Customer-facing Terraform modules for [Cielara](https://cielara.ai) deployments.

- [`cielara-prepare/`](cielara-prepare/) — prepares your cloud account for a
  Cielara deployment (GKE, GCP VM, EKS, AKS). Start here if the Cielara deploy
  form sent you to this repository.
- [`cielara-enterprise-cloud-network/`](cielara-enterprise-cloud-network/) —
  bring-your-own network modules for enterprise deployments (Azure VNet +
  private endpoints, AWS VPC + remote-cluster connectivity).

Every module is a standalone root module: clone the repository, enter the
module directory, and follow its README.
