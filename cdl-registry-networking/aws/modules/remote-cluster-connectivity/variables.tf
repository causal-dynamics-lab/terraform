#################################################
# Region + network handles — adopted from the vpc module (by ID)
#
# This module creates NO VPC of its own. It looks the Cielara VPC and its
# private route tables up by ID and provisions peering + DNS into the existing
# network. Copy these from the vpc module's outputs.
#################################################
variable "region" {
  description = "AWS region the Cielara VPC lives in (vpc output: region). Remote clusters must be in the same region in v1."
  type        = string
  default     = "us-east-1"
}

variable "vpc_id" {
  description = "Cielara VPC ID (vpc output: vpc_id)"
  type        = string
}

variable "vpc_cidr" {
  description = "Cielara VPC CIDR (vpc output: vpc_cidr); used for overlap validation and remote return routes"
  type        = string
}

variable "private_route_table_ids" {
  description = "Private route table IDs in the Cielara VPC (vpc output: private_route_table_ids)"
  type        = list(string)

  validation {
    condition     = length(var.private_route_table_ids) > 0
    error_message = "private_route_table_ids must list at least one route table."
  }
}

#################################################
# Naming + ownership tag — mirrors the vpc module
#################################################
variable "name_prefix" {
  description = "Prefix for peering / DNS resource names."
  type        = string
  default     = "cielara"
}

variable "cielara_client_id" {
  description = "Optional Cielara client ID, stamped into the cielara-client-id tag."
  type        = string
  default     = ""
}

#################################################
# Remote private EKS clusters to reach over VPC peering
#
# One entry per remote cluster. The map KEY is a short label used in resource
# names and as the for_each key (keep it stable — changing it recreates the link).
#
#   cluster_name   : remote EKS cluster name, e.g.
#                    aws eks list-clusters
#   remote_vpc_id  : VPC the remote cluster runs in, e.g.
#                    aws eks describe-cluster --name <n> --query 'cluster.resourcesVpcConfig.vpcId'
#   remote_vpc_cidr: CIDR of that VPC (must NOT overlap vpc_cidr), e.g.
#                    aws ec2 describe-vpcs --vpc-ids <id> --query 'Vpcs[0].CidrBlock'
#   api_endpoint   : private Kubernetes API hostname (no scheme), e.g.
#                    aws eks describe-cluster --name <n> --query 'cluster.endpoint' -o text
#                    with https:// stripped → xxxxx.gr7.<region>.eks.amazonaws.com
#   api_endpoint_ips : optional manual override when ENI discovery is not possible
#                      (cross-account). Private IPs of the EKS control-plane ENIs.
#   discover_endpoint_ips : when true (default) and api_endpoint_ips is empty,
#                      look up ENI private IPs via ec2:DescribeNetworkInterfaces
#                      (same account only).
#   remote_route_table_ids : optional remote VPC private route table IDs. When
#                      provided (same account), this module adds return routes
#                      (remote_vpc → vpc_cidr). Omit when the remote owner manages routes.
#################################################
variable "remote_clusters" {
  description = "Map of remote private EKS clusters to connect. Key = short stable label."
  type = map(object({
    cluster_name           = string
    cluster_region         = optional(string)
    remote_vpc_id          = string
    remote_vpc_cidr        = string
    api_endpoint           = string
    api_endpoint_ips       = optional(list(string))
    discover_endpoint_ips  = optional(bool, true)
    remote_route_table_ids = optional(list(string))
  }))
  default = {}

  validation {
    condition = alltrue([
      for k, c in var.remote_clusters : can(regex("\\.eks\\.amazonaws\\.com$", trimsuffix(replace(replace(c.api_endpoint, "https://", ""), "http://", ""), ".")))
    ])
    error_message = "Each remote_clusters[*].api_endpoint must be an EKS API hostname ending in .eks.amazonaws.com (scheme optional)."
  }

  validation {
    condition = alltrue([
      for k, c in var.remote_clusters : coalesce(c.cluster_region, var.region) == var.region
    ])
    error_message = "Cross-region remote clusters are not supported in v1; cluster_region must match var.region."
  }

  validation {
    # O(1) interval overlap: [start, end] ranges intersect iff a_start <= b_end && b_start <= a_end.
    # Inlined here (validation blocks cannot reference locals) — avoids pow(2, prefix_diff) enumeration.
    condition = alltrue([
      for k, c in var.remote_clusters : !(
        sum([for i, o in split(".", cidrhost(var.vpc_cidr, 0)) : tonumber(o) * pow(256, 3 - i)]) <= sum([for i, o in split(".", cidrhost(c.remote_vpc_cidr, -1)) : tonumber(o) * pow(256, 3 - i)])
        && sum([for i, o in split(".", cidrhost(c.remote_vpc_cidr, 0)) : tonumber(o) * pow(256, 3 - i)]) <= sum([for i, o in split(".", cidrhost(var.vpc_cidr, -1)) : tonumber(o) * pow(256, 3 - i)])
      )
    ])
    error_message = "Each remote_clusters[*].remote_vpc_cidr must not overlap vpc_cidr."
  }

  validation {
    condition = alltrue(flatten([
      for i in range(length(sort(keys(var.remote_clusters)))) : [
        for j in range(i + 1, length(sort(keys(var.remote_clusters)))) : !(
          sum([for ii, o in split(".", cidrhost(var.remote_clusters[sort(keys(var.remote_clusters))[i]].remote_vpc_cidr, 0)) : tonumber(o) * pow(256, 3 - ii)]) <= sum([for ii, o in split(".", cidrhost(var.remote_clusters[sort(keys(var.remote_clusters))[j]].remote_vpc_cidr, -1)) : tonumber(o) * pow(256, 3 - ii)])
          && sum([for ii, o in split(".", cidrhost(var.remote_clusters[sort(keys(var.remote_clusters))[j]].remote_vpc_cidr, 0)) : tonumber(o) * pow(256, 3 - ii)]) <= sum([for ii, o in split(".", cidrhost(var.remote_clusters[sort(keys(var.remote_clusters))[i]].remote_vpc_cidr, -1)) : tonumber(o) * pow(256, 3 - ii)])
        )
      ]
    ]))
    error_message = "remote_clusters[*].remote_vpc_cidr values must be pairwise non-overlapping (duplicate destinations break route tables)."
  }

}
