#################################################
# Raw outputs
#
# The Cielara Enterprise setup adopts the network by self-link (project +
# region + name in one handle), so the handback carries self-links plus the
# secondary range names the cluster binds to and the NAT egress IP.
#################################################
output "project_id" {
  description = "GCP project the network lives in"
  value       = var.project_id
}

output "region" {
  description = "GCP region the network lives in"
  value       = var.region
}

output "vpc_self_link" {
  description = "VPC network self-link (what the Cielara cluster/Cloud SQL reference as `network`)"
  value       = google_compute_network.vpc.self_link
}

output "gke_subnet_self_link" {
  description = "GKE subnet self-link (what the Cielara cluster references as `subnetwork`)"
  value       = google_compute_subnetwork.gke_subnet.self_link
}

output "pods_range_name" {
  description = "Pods secondary range name (the cluster's ip_allocation_policy binds to it)"
  value       = var.pods_range_name
}

output "services_range_name" {
  description = "Services secondary range name (the cluster's ip_allocation_policy binds to it)"
  value       = var.services_range_name
}

output "nat_ip" {
  description = "Static egress IP of the Cloud NAT — the single source address to allowlist (required on the Cielara deploy form when managed RabbitMQ is enabled)"
  value       = google_compute_address.nat_ip.address
}

#################################################
# Handback
#
# Single JSON blob to hand back to Cielara. `terraform output -raw handback`
# prints exactly this; paste it into your Cielara Enterprise setup.
#################################################
output "handback" {
  description = "JSON blob of network handles to hand back to Cielara. Run: terraform output -raw handback"
  value = jsonencode({
    project_id           = var.project_id
    region               = var.region
    vpc_self_link        = google_compute_network.vpc.self_link
    gke_subnet_self_link = google_compute_subnetwork.gke_subnet.self_link
    pods_range_name      = var.pods_range_name
    services_range_name  = var.services_range_name
    nat_ip               = google_compute_address.nat_ip.address
  })
}
