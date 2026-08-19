#################################################
# ENI discovery — control-plane private IPs (same account)
#
# EKS registers control-plane ENIs in the remote VPC with description
# "Amazon EKS <cluster-name>". Those IPs are what the API hostname must
# resolve to from the consumer VPC (mirrors Azure's PE IP → A record).
#################################################
data "aws_network_interfaces" "eks_cp" {
  for_each = local.discover_clusters

  filter {
    name   = "description"
    values = ["Amazon EKS ${each.value.cluster_name}"]
  }

  filter {
    name   = "vpc-id"
    values = [each.value.remote_vpc_id]
  }
}

data "aws_network_interface" "eks_cp_eni" {
  for_each = local.eni_lookup_keys

  id = each.value
}

#################################################
# Private DNS — one PHZ per cluster API hostname in the consumer VPC
#
# Pods resolve the remote cluster's API FQDN to the control-plane ENI private
# IPs over the peering link. Zone apex = api_endpoint hostname.
#################################################
resource "aws_route53_zone" "cluster_api" {
  for_each = local.clusters

  name = each.value.api_endpoint

  vpc {
    vpc_id = var.vpc_id
  }

  tags = merge(local.tags, { Name = "${var.name_prefix}-dns-${each.key}" })

  lifecycle {
    precondition {
      condition     = length(local.endpoint_ips[each.key]) > 0
      error_message = "remote_clusters[\"${each.key}\"]: no API endpoint IPs found. Set api_endpoint_ips manually or ensure ENI discovery can reach the remote cluster (same account, eks:DescribeCluster + ec2:DescribeNetworkInterfaces)."
    }
  }
}

resource "aws_route53_record" "cluster_api" {
  for_each = local.clusters

  zone_id = aws_route53_zone.cluster_api[each.key].zone_id
  name    = each.value.api_endpoint
  type    = "A"
  ttl     = 300
  records = local.endpoint_ips[each.key]
}
