#################################################
# Locals — subnet layout
#
# Sized for the Cielara Enterprise workload, derived from var.vpc_cidr
# (default 10.2.0.0/20 = 4096 addresses, mirroring the Azure module). EKS runs
# the AWS VPC CNI (pods draw IPs from the node subnets), so the private
# subnets are the big ones:
#   private[0..1]  <cidr> +2 bits  (/22 for a /20, 1024 each)  EKS nodes + pods
#   public[0..1]   <cidr> +6 bits  (/26 for a /20, 64 each)    ALB/NLB only
# For the default 10.2.0.0/20: private 10.2.0.0/22 + 10.2.4.0/22, public
# 10.2.8.0/26 + 10.2.8.64/26; the rest (10.2.8.128 – 10.2.15.255) is left free
# for growth. All nodes (and RDS + EFS) live in the private subnets; the
# public pair exists only for NAT gateways and internet-facing load balancers.
#################################################
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = length(var.availability_zones) == 2 ? var.availability_zones : slice(data.aws_availability_zones.available.names, 0, 2)

  private_subnet_cidrs = [cidrsubnet(var.vpc_cidr, 2, 0), cidrsubnet(var.vpc_cidr, 2, 1)]
  public_subnet_cidrs  = [cidrsubnet(var.vpc_cidr, 6, 32), cidrsubnet(var.vpc_cidr, 6, 33)]

  nat_count = var.ha_nat ? length(local.azs) : 1

  # cielara-client-id is an optional ownership/audit tag — added only when a
  # client ID is provided. The network is handed back (and adopted) by ID, so
  # the tag is a nice-to-have for identifying the network in your account, not
  # a functional input.
  tags = merge(
    {
      Project   = "cielara"
      ManagedBy = "cielara-enterprise-cloud-network"
    },
    var.cielara_client_id != "" ? { "cielara-client-id" = var.cielara_client_id } : {}
  )
}

#################################################
# VPC
#
# DNS hostnames + support are hard EKS requirements (nodes register by
# private DNS name; RDS endpoints resolve in-VPC).
#################################################
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.tags, { Name = "${var.name_prefix}-vpc" })
}

#################################################
# Subnets
#
# The kubernetes.io/role/* tags are how the in-cluster AWS Load Balancer
# Controller auto-discovers where to place load balancers — they are part of
# the handback contract, do not remove them. The cluster-scoped tag
# (kubernetes.io/cluster/<name> = shared) is NOT stamped here: the cluster
# name is generated at deploy time, so the Cielara deployment adds that one
# tag to these subnets itself (and removes it again on teardown).
#################################################
resource "aws_subnet" "private" {
  count = length(local.azs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = local.private_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(local.tags, {
    Name                              = "${var.name_prefix}-private-${local.azs[count.index]}"
    "kubernetes.io/role/internal-elb" = "1"
  })
}

resource "aws_subnet" "public" {
  count = length(local.azs)

  vpc_id                  = aws_vpc.main.id
  cidr_block              = local.public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = merge(local.tags, {
    Name                     = "${var.name_prefix}-public-${local.azs[count.index]}"
    "kubernetes.io/role/elb" = "1"
  })
}

#################################################
# Egress — IGW for the public subnets, NAT for the private ones
#
# The private subnets MUST have a default route to a NAT gateway (or equivalent
# egress) before the Cielara deployment runs: nodes pull images and reach AWS
# APIs from the private subnets. You own egress for this network — the Cielara
# deployment never adds NAT capacity to an adopted VPC.
#################################################
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.tags, { Name = "${var.name_prefix}-igw" })
}

resource "aws_eip" "nat" {
  count  = local.nat_count
  domain = "vpc"

  tags = merge(local.tags, { Name = "${var.name_prefix}-nat-${count.index}" })
}

resource "aws_nat_gateway" "main" {
  count = local.nat_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = merge(local.tags, { Name = "${var.name_prefix}-nat-${count.index}" })

  depends_on = [aws_internet_gateway.main]
}

# Public route table: one, shared by both public subnets, default route → IGW.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(local.tags, { Name = "${var.name_prefix}-public-rt" })
}

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Private route tables: one per NAT gateway. With a single NAT both private
# subnets share rt[0]; with HA NAT each private subnet uses its own AZ's NAT.
resource "aws_route_table" "private" {
  count  = local.nat_count
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[count.index].id
  }

  tags = merge(local.tags, { Name = "${var.name_prefix}-private-rt-${count.index}" })
}

resource "aws_route_table_association" "private" {
  count = length(aws_subnet.private)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[var.ha_nat ? count.index : 0].id
}

# No IAM here: the Cielara deployer role is granted everything it needs
# (including describing and tagging these subnets) once by prepare-eks.sh,
# run by an IAM admin. This module needs no IAM permissions beyond EC2.
