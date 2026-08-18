# Offline plan-level tests for api_endpoint normalization, CIDR overlap, and
# region constraints. mock_provider => no AWS creds and no network calls.
# Run from aws/remote-cluster-connectivity:  terraform test

mock_provider "aws" {}

variables {
  region                  = "us-east-2"
  vpc_id                  = "vpc-0123456789abcdef0"
  vpc_cidr                = "10.2.0.0/20"
  private_route_table_ids = ["rtb-0aaa1111", "rtb-0bbb2222"]
}

override_data {
  target = data.aws_vpc.consumer
  values = {
    cidr_block = "10.2.0.0/20"
  }
}

# Manual api_endpoint_ips: scheme stripped, A record points at supplied IPs.
run "strips_scheme_and_uses_manual_endpoint_ips" {
  command = plan

  variables {
    remote_clusters = {
      a = {
        cluster_name           = "prod-eks"
        remote_vpc_id          = "vpc-remote111"
        remote_vpc_cidr        = "10.10.0.0/20"
        api_endpoint           = "https://ABC123.gr7.us-east-2.eks.amazonaws.com"
        api_endpoint_ips       = ["10.10.1.10", "10.10.2.20"]
        discover_endpoint_ips  = false
        remote_route_table_ids = ["rtb-remote1"]
      }
    }
  }

  assert {
    condition     = aws_route53_zone.cluster_api["a"].name == "ABC123.gr7.us-east-2.eks.amazonaws.com"
    error_message = "api_endpoint hostname should have https:// stripped"
  }

  assert {
    condition     = sort(tolist(aws_route53_record.cluster_api["a"].records)) == sort(["10.10.1.10", "10.10.2.20"])
    error_message = "A record should use supplied api_endpoint_ips"
  }

  assert {
    condition     = aws_vpc_peering_connection.remote["a"].auto_accept == true
    error_message = "v1 peering should auto-accept in same account"
  }

  assert {
    condition     = length(aws_route.consumer) == 2
    error_message = "should add one consumer route per private route table"
  }

  assert {
    condition     = length(aws_route.remote_return) == 1
    error_message = "should add remote return route when remote_route_table_ids is set"
  }
}

# ENI discovery path: no api_endpoint_ips supplied, A record uses the private
# IPs of the control-plane ENIs found in the remote VPC.
run "discovers_endpoint_ips_from_enis" {
  command = plan

  variables {
    remote_clusters = {
      a = {
        cluster_name    = "prod-eks"
        remote_vpc_id   = "vpc-remote111"
        remote_vpc_cidr = "10.10.0.0/20"
        api_endpoint    = "ABC123.gr7.us-east-2.eks.amazonaws.com"
      }
    }
  }

  override_data {
    target = data.aws_network_interfaces.eks_cp["a"]
    values = {
      ids = ["eni-0aaa1111", "eni-0bbb2222"]
    }
  }

  override_data {
    target = data.aws_network_interface.eks_cp_eni["a/eni-0aaa1111"]
    values = {
      private_ip = "10.10.1.10"
    }
  }

  override_data {
    target = data.aws_network_interface.eks_cp_eni["a/eni-0bbb2222"]
    values = {
      private_ip = "10.10.2.20"
    }
  }

  assert {
    condition     = sort(tolist(aws_route53_record.cluster_api["a"].records)) == sort(["10.10.1.10", "10.10.2.20"])
    error_message = "A record should use the discovered ENI private IPs"
  }
}

# Overlapping remote VPC CIDR must be rejected.
run "rejects_overlapping_remote_vpc_cidr" {
  command = plan

  variables {
    remote_clusters = {
      bad = {
        cluster_name          = "prod"
        remote_vpc_id         = "vpc-remote"
        remote_vpc_cidr       = "10.2.4.0/22"
        api_endpoint          = "ABC.gr7.us-east-2.eks.amazonaws.com"
        api_endpoint_ips      = ["10.10.1.1"]
        discover_endpoint_ips = false
      }
    }
  }

  expect_failures = [var.remote_clusters]
}

# Two remote clusters with the same CIDR break consumer route tables at apply time.
run "rejects_overlapping_remote_cidrs_among_clusters" {
  command = plan

  variables {
    remote_clusters = {
      a = {
        cluster_name          = "prod-a"
        remote_vpc_id         = "vpc-a"
        remote_vpc_cidr       = "10.10.0.0/20"
        api_endpoint          = "A.gr7.us-east-2.eks.amazonaws.com"
        api_endpoint_ips      = ["10.10.1.1"]
        discover_endpoint_ips = false
      }
      b = {
        cluster_name          = "prod-b"
        remote_vpc_id         = "vpc-b"
        remote_vpc_cidr       = "10.10.0.0/20"
        api_endpoint          = "B.gr7.us-east-2.eks.amazonaws.com"
        api_endpoint_ips      = ["10.10.1.2"]
        discover_endpoint_ips = false
      }
    }
  }

  expect_failures = [var.remote_clusters]
}

# Cross-region clusters are rejected in v1.
run "rejects_cross_region_cluster" {
  command = plan

  variables {
    remote_clusters = {
      bad = {
        cluster_name          = "prod"
        cluster_region        = "us-west-2"
        remote_vpc_id         = "vpc-remote"
        remote_vpc_cidr       = "10.10.0.0/20"
        api_endpoint          = "ABC.gr7.us-west-2.eks.amazonaws.com"
        api_endpoint_ips      = ["10.10.1.1"]
        discover_endpoint_ips = false
      }
    }
  }

  expect_failures = [var.remote_clusters]
}

# A non-EKS hostname must be rejected by variable validation.
run "rejects_non_eks_api_endpoint" {
  command = plan

  variables {
    remote_clusters = {
      bad = {
        cluster_name          = "prod"
        remote_vpc_id         = "vpc-remote"
        remote_vpc_cidr       = "10.10.0.0/20"
        api_endpoint          = "api.example.com"
        api_endpoint_ips      = ["10.10.1.1"]
        discover_endpoint_ips = false
      }
    }
  }

  expect_failures = [var.remote_clusters]
}
