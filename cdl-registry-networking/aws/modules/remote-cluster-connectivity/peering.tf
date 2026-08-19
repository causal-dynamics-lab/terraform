#################################################
# VPC peering — one connection per remote cluster
#
# v1: same-account only (auto_accept = true). Cross-account peering is Phase 2.
# allow_remote_vpc_dns_resolution is enabled on both sides so Route 53 PHZ
# records in the consumer VPC resolve correctly from pods.
#################################################
resource "aws_vpc_peering_connection" "remote" {
  for_each = local.clusters

  vpc_id      = var.vpc_id
  peer_vpc_id = each.value.remote_vpc_id
  auto_accept = true
  tags        = merge(local.tags, { Name = "${var.name_prefix}-peer-${each.key}" })

  lifecycle {
    precondition {
      condition     = data.aws_vpc.consumer.cidr_block == var.vpc_cidr
      error_message = "var.vpc_cidr (${var.vpc_cidr}) must match the CIDR of vpc_id (${data.aws_vpc.consumer.cidr_block})."
    }
  }
}

resource "aws_vpc_peering_connection_options" "remote" {
  for_each = aws_vpc_peering_connection.remote

  vpc_peering_connection_id = each.value.id

  accepter {
    allow_remote_vpc_dns_resolution = true
  }

  requester {
    allow_remote_vpc_dns_resolution = true
  }
}
