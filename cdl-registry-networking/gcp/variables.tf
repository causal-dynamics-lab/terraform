#################################################
# Project / region / auth
#################################################
variable "project_id" {
  description = "GCP project ID the network is created in — the same project Cielara Enterprise deploys into (hand back the same project you authorized with prepare-gke)."
  type        = string
}

variable "region" {
  # us-central1 mirrors the Cielara Enterprise default region. The subnet (and
  # the deployment adopting it) must live in the same region you hand back.
  description = "GCP region for the subnet + Cloud NAT (e.g. us-central1). Must match the region you select on the Cielara deploy form."
  type        = string
  default     = "us-central1"
}

#################################################
# Naming + ownership label
#################################################
variable "name_prefix" {
  description = "Prefix for human-readable resource names (VPC, subnet, NAT router/IP). The network is handed back and adopted by self-link, so names are cosmetic."
  type        = string
  default     = "cielara"
}

variable "cielara_client_id" {
  description = "Optional Cielara client ID. When set, it's lowercased into the cielara-client-id label for identifying the network in your project. Not required — the network is handed back and adopted by self-link."
  type        = string
  default     = ""
}

#################################################
# Network sizing
#
# Defaults match the Cielara data-plane module. GKE runs VPC-native (alias-IP)
# networking: nodes draw from the primary subnet range while PODS draw from the
# pods secondary range — which is why the pods range is the big one (/16) and
# cannot be right-sized the way a node-only range could. Keep all three ranges
# disjoint from each other, from the GKE master CIDR (172.16.0.0/28), and from
# the Cloud SQL Private Service Access range (10.96.0.0/16 unless you override
# it on the deploy form) — Cielara adds that PSA range post-handback (its name
# embeds the deploy-time cluster name, so it cannot be created here).
#################################################
variable "gke_subnet_cidr" {
  description = "Primary CIDR for the GKE node subnet"
  type        = string
  default     = "10.10.0.0/20"

  validation {
    condition     = tonumber(split("/", var.gke_subnet_cidr)[1]) <= 24
    error_message = "gke_subnet_cidr must be /24 or larger — smaller blocks can't hold the cluster's node fleet."
  }
}

variable "pods_cidr" {
  description = "Secondary (alias-IP) range for pods. GKE reserves a /24 per node from this range by default, so it must stay large."
  type        = string
  default     = "10.11.0.0/16"

  validation {
    condition     = tonumber(split("/", var.pods_cidr)[1]) <= 20
    error_message = "pods_cidr must be /20 or larger — GKE reserves a /24 per node from it, and a small range caps the cluster at a handful of nodes."
  }
}

variable "services_cidr" {
  description = "Secondary range for cluster services"
  type        = string
  default     = "10.12.0.0/20"
}

variable "pods_range_name" {
  description = "Name of the pods secondary range. The Cielara cluster's ip_allocation_policy references it by name; the handback carries it, so any valid name works — 'pods' is the convention."
  type        = string
  default     = "pods"
}

variable "services_range_name" {
  description = "Name of the services secondary range. Handed back by name like pods_range_name — 'services' is the convention."
  type        = string
  default     = "services"
}
