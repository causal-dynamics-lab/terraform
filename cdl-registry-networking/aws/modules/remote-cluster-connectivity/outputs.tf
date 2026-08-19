output "peering_connection_ids" {
  description = "Map of remote-cluster label -> VPC peering connection ID"
  value       = { for k, pcx in aws_vpc_peering_connection.remote : k => pcx.id }
}

output "api_endpoint_ips" {
  description = "Map of remote-cluster label -> private IP(s) of the EKS API control-plane ENIs (verify DNS from a consumer pod resolves here)"
  value       = local.endpoint_ips
}

output "private_hosted_zone_ids" {
  description = "Map of remote-cluster label -> Route 53 private hosted zone ID for the API hostname"
  value       = { for k, z in aws_route53_zone.cluster_api : k => z.zone_id }
}

output "connectivity_check" {
  description = "Per-cluster summary for post-apply verification"
  value = {
    for k, c in local.clusters : k => {
      api_endpoint    = c.api_endpoint
      endpoint_ips    = local.endpoint_ips[k]
      peering_id      = aws_vpc_peering_connection.remote[k].id
      peering_state   = aws_vpc_peering_connection.remote[k].accept_status
      remote_vpc_id   = c.remote_vpc_id
      remote_vpc_cidr = c.remote_vpc_cidr
    }
  }
}
