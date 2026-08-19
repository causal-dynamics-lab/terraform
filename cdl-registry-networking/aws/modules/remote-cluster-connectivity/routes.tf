#################################################
# Routes — consumer VPC private route tables → remote VPC CIDR
#################################################
resource "aws_route" "consumer" {
  for_each = merge([
    for k, c in local.clusters : {
      for rt_id in var.private_route_table_ids : "${k}/${rt_id}" => {
        cluster_key    = k
        route_table_id = rt_id
        destination    = c.remote_vpc_cidr
        pcx_id         = aws_vpc_peering_connection.remote[k].id
      }
    }
  ]...)

  route_table_id            = each.value.route_table_id
  destination_cidr_block    = each.value.destination
  vpc_peering_connection_id = each.value.pcx_id
}

#################################################
# Routes — optional return routes on the remote VPC (same account)
#
# When remote_route_table_ids is set per cluster, add vpc_cidr → peering on
# the producer side. Omit when the remote owner manages routes out of band.
#################################################
resource "aws_route" "remote_return" {
  for_each = merge([
    for k, c in local.clusters : {
      for rt_id in c.remote_route_table_ids : "${k}/${rt_id}" => {
        route_table_id = rt_id
        destination    = var.vpc_cidr
        pcx_id         = aws_vpc_peering_connection.remote[k].id
      }
    }
  ]...)

  route_table_id            = each.value.route_table_id
  destination_cidr_block    = each.value.destination
  vpc_peering_connection_id = each.value.pcx_id
}
