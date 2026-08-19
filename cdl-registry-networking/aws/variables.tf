#################################################
# Region
#################################################
variable "region" {
  # us-east-1 mirrors the Cielara Enterprise default region. The VPC (and the
  # Cielara Enterprise deployment adopting it) must live in the same region you
  # hand back.
  description = "AWS region the VPC is created in (e.g. us-east-1)"
  type        = string
  default     = "us-east-1"
}

#################################################
# Naming + ownership tag
#################################################
variable "name_prefix" {
  description = "Prefix for human-readable resource names (VPC, NAT, route tables). The network is handed back and adopted by ID, so names are cosmetic."
  type        = string
  default     = "cielara"
}

variable "cielara_client_id" {
  description = "Optional Cielara client ID. When set, it's stamped into the cielara-client-id tag for identifying the network in your account. Not required — the network is handed back and adopted by ID."
  type        = string
  default     = ""
}

#################################################
# Network sizing
#################################################
variable "vpc_cidr" {
  # Sized like the Azure module's vnet_cidr (10.2.0.0/20): a /20 (4096
  # addresses) comfortably holds two private /22 node subnets (EKS nodes AND
  # pods draw IPs from them under the AWS VPC CNI, so they are the big ones)
  # and two public /26 load-balancer subnets, with the tail left free for
  # growth. Far less of your internal address space than a /16.
  description = "CIDR for the Cielara Enterprise VPC (a /20 is recommended). Private node subnets are carved at +2 bits (/22 each for a /20), public load-balancer subnets at +6 bits (/26 each)."
  type        = string
  default     = "10.2.0.0/20"

  validation {
    # Public subnets are carved 6 bits below the base and AWS Application Load
    # Balancers require at least a /27 per subnet, so /21 is the hard floor —
    # but a /21 also halves the node subnets to /23 (~500 usable IPs each),
    # which the pod-dense VPC CNI can exhaust. Require /20 or larger; bigger
    # blocks (/19, /18, …) are fine — the subnets just scale up.
    condition     = tonumber(split("/", var.vpc_cidr)[1]) <= 20
    error_message = "vpc_cidr must be /20 or larger (e.g. /20, /19, /18). A smaller block carves the public subnets below /27 (the AWS ALB minimum) and leaves too little pod IP space in the node subnets."
  }
}

variable "availability_zones" {
  description = "Exactly two availability zones to spread the subnets across. Leave empty to use the region's first two available AZs. EKS and RDS Multi-AZ both require two distinct AZs."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.availability_zones) == 0 || length(var.availability_zones) == 2
    error_message = "availability_zones must be empty (auto-select) or list exactly two AZs."
  }
}

variable "ha_nat" {
  description = "One NAT gateway per AZ (true) or a single shared NAT gateway (false). Single is cheaper; per-AZ survives an AZ outage. You own egress for this network — Cielara Enterprise does not add NAT capacity to an adopted VPC."
  type        = bool
  default     = false
}
