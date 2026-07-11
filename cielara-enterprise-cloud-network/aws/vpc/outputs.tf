#################################################
# Raw outputs
#
# The Cielara Enterprise setup adopts the network by ID (VPC ID + subnet IDs
# — the AWS-native handles), so the handback carries IDs, not names.
#################################################
output "region" {
  description = "AWS region the network lives in"
  value       = var.region
}

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "VPC CIDR block (for remote-cluster-connectivity overlap checks)"
  value       = var.vpc_cidr
}

output "private_route_table_ids" {
  description = "Private route table IDs — one per NAT gateway (shared or per-AZ); used by remote-cluster-connectivity for peering routes"
  value       = aws_route_table.private[*].id
}

output "private_subnet_ids" {
  description = "Private subnet IDs (EKS nodes, RDS, EFS) — one per AZ"
  value       = aws_subnet.private[*].id
}

output "public_subnet_ids" {
  description = "Public subnet IDs (internet-facing load balancers) — one per AZ"
  value       = aws_subnet.public[*].id
}

#################################################
# Handback
#
# Single JSON blob to hand back to Cielara. `terraform output -raw handback`
# prints exactly this; paste it into your Cielara Enterprise setup.
#################################################
output "handback" {
  description = "JSON blob of network IDs to hand back to Cielara. Run: terraform output -raw handback"
  value = jsonencode({
    region             = var.region
    vpc_id             = aws_vpc.main.id
    private_subnet_ids = aws_subnet.private[*].id
    public_subnet_ids  = aws_subnet.public[*].id
  })
}
