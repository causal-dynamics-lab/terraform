# Cielara Terraform

Customer-facing Terraform modules for [Cielara](https://cielara.ai) deployments.

- [`cielara-prepare/`](cielara-prepare/) — prepares your cloud account for a
  Cielara deployment (GKE, GCP VM, EKS, AKS). Start here if the Cielara deploy
  form sent you to this repository.
- [`cielara-enterprise-cloud-network/`](cielara-enterprise-cloud-network/) —
  bring-your-own network modules for enterprise deployments (Azure VNet +
  private endpoints, AWS VPC + remote-cluster connectivity, GCP VPC).
- [`cielara-ai-foundry/`](cielara-ai-foundry/) — Azure AI Foundry account +
  model deployments for the Cielara data plane.

Every module is a standalone root module: clone the repository, enter the
module directory, and follow its README.

PRs land on `main` (the pre-release line); releases are cut from the
`release` branch and tagged `vX.Y.Z`, `vX.Y.Z-beta.N`, or `vX.Y.Z-alpha.N` —
see [RELEASING.md](RELEASING.md).
