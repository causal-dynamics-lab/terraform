#################################################
# Locals
#################################################
locals {
  tags = merge(
    {
      Project   = "cielara"
      ManagedBy = "cielara-enterprise-cloud-network"
    },
    var.cielara_client_id != "" ? { "cielara-client-id" = var.cielara_client_id } : {}
  )

  clusters = {
    for k, c in var.remote_clusters : k => {
      cluster_name           = c.cluster_name
      cluster_region         = coalesce(c.cluster_region, var.region)
      remote_vpc_id          = c.remote_vpc_id
      remote_vpc_cidr        = c.remote_vpc_cidr
      api_endpoint           = trimsuffix(replace(replace(c.api_endpoint, "https://", ""), "http://", ""), ".")
      api_endpoint_ips       = coalesce(c.api_endpoint_ips, [])
      discover_endpoint_ips  = c.discover_endpoint_ips
      remote_route_table_ids = coalesce(c.remote_route_table_ids, [])
    }
  }

  # Clusters where we auto-discover control-plane ENI private IPs (same account).
  discover_clusters = {
    for k, c in local.clusters : k => c
    if c.discover_endpoint_ips && length(c.api_endpoint_ips) == 0
  }

  # Flat map "cluster_key/eni-id" → eni id for per-ENI data sources.
  eni_lookup_keys = merge([
    for k, c in local.discover_clusters : {
      for eni_id in data.aws_network_interfaces.eks_cp[k].ids : "${k}/${eni_id}" => eni_id
    }
  ]...)

  discovered_endpoint_ips = {
    for k, c in local.discover_clusters : k => distinct([
      for key, eni_id in local.eni_lookup_keys : data.aws_network_interface.eks_cp_eni[key].private_ip
      if startswith(key, "${k}/")
    ])
  }

  endpoint_ips = {
    for k, c in local.clusters : k => (
      length(c.api_endpoint_ips) > 0 ? c.api_endpoint_ips : try(local.discovered_endpoint_ips[k], [])
    )
  }
}

#################################################
# Network handles — adopted by ID, never created
#################################################
data "aws_vpc" "consumer" {
  id = var.vpc_id
}
