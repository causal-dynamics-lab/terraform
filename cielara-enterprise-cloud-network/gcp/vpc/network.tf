#################################################
# Locals — ownership label
#
# GCP label values must be lowercase [a-z0-9_-] and <= 63 chars; the Cielara
# client ID is a ULID (uppercase), so lowercase + sanitize it. Added only when
# a client ID is provided — the network is handed back (and adopted) by
# self-link, so the label is a nice-to-have for identifying the network in
# your project, not a functional input.
#################################################
locals {
  owner_labels = var.cielara_client_id != "" ? {
    cielara-client-id = substr(lower(replace(var.cielara_client_id, "/[^a-zA-Z0-9_-]/", "-")), 0, 63)
  } : {}
}

#################################################
# Required APIs
#
# compute is needed to create the VPC/subnet/NAT. Enabled here so a fresh
# project can run this module standalone. disable_on_destroy=false leaves the
# API on for the rest of the project (the Cielara deploy needs it too).
#################################################
resource "google_project_service" "compute" {
  service            = "compute.googleapis.com"
  disable_on_destroy = false
}

#################################################
# VPC + subnet
#
# Layout mirrors the Cielara data-plane module: a custom-mode VPC with one
# regional subnet carrying two secondary ranges (pods + services) for
# VPC-native (alias-IP) GKE, and private Google access on so private nodes
# reach Google APIs. The cluster's ip_allocation_policy binds to the secondary
# ranges BY NAME — the handback carries the names you chose.
#################################################
resource "google_compute_network" "vpc" {
  name                    = "${var.name_prefix}-vpc"
  auto_create_subnetworks = false

  depends_on = [google_project_service.compute]
}

resource "google_compute_subnetwork" "gke_subnet" {
  name                     = "${var.name_prefix}-gke-subnet"
  ip_cidr_range            = var.gke_subnet_cidr
  region                   = var.region
  network                  = google_compute_network.vpc.id
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = var.pods_range_name
    ip_cidr_range = var.pods_cidr
  }

  secondary_ip_range {
    range_name    = var.services_range_name
    ip_cidr_range = var.services_cidr
  }
}

#################################################
# Egress — Cloud NAT with a single static IP
#
# Private GKE nodes have no external IPs; egress (image pulls, external APIs,
# the managed RabbitMQ broker) goes through Cloud NAT. MANUAL_ONLY pins the
# NAT to ONE static IP so you allowlist a single source address — and so the
# handback's nat_ip is stable. You own egress for this network — the Cielara
# deployment never adds NAT capacity to an adopted VPC.
#
# No firewalls here: GKE manages its own node firewalls, and the Cloud SQL
# Private Service Access range is added by Cielara post-handback (its name
# embeds the deploy-time cluster name).
#################################################
resource "google_compute_address" "nat_ip" {
  name         = "${var.name_prefix}-nat-ip"
  region       = var.region
  address_type = "EXTERNAL"
  description  = "Static external IP for the Cloud NAT gateway"
}

resource "google_compute_router" "router" {
  name    = "${var.name_prefix}-router"
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  name                                = "${var.name_prefix}-nat"
  router                              = google_compute_router.router.name
  region                              = var.region
  nat_ip_allocate_option              = "MANUAL_ONLY"
  nat_ips                             = [google_compute_address.nat_ip.self_link]
  source_subnetwork_ip_ranges_to_nat  = "ALL_SUBNETWORKS_ALL_IP_RANGES"
  enable_endpoint_independent_mapping = true

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}
