# Offline plan-level tests for the destroy-time leftover cleanup wiring.
# mock_provider => no AWS creds. Run from this directory:  terraform test

mock_provider "aws" {
  override_data {
    target = data.aws_availability_zones.available
    values = {
      names = ["us-east-2a", "us-east-2b", "us-east-2c"]
    }
  }
}

override_resource {
  target          = aws_vpc.main
  override_during = plan
  values = {
    id = "vpc-0123456789abcdef0"
  }
}

override_resource {
  target          = aws_subnet.private
  override_during = plan
  values = {
    id = "subnet-0private"
  }
}

override_resource {
  target          = aws_subnet.public
  override_during = plan
  values = {
    id = "subnet-0public"
  }
}

variables {
  region = "us-east-2"
}

# The script gets this module's region, VPC and all four subnets — the scope
# it is allowed to clean — and nothing it would have to look up itself.
run "cleanup_scoped_to_this_network" {
  command = plan

  assert {
    condition     = terraform_data.cluster_leftovers.input.region == "us-east-2"
    error_message = "cleanup must run in the module's region"
  }

  assert {
    condition     = terraform_data.cluster_leftovers.input.vpc_id == "vpc-0123456789abcdef0"
    error_message = "cleanup must be scoped to this module's VPC"
  }

  assert {
    condition     = terraform_data.cluster_leftovers.input.subnet_ids == "subnet-0private,subnet-0private,subnet-0public,subnet-0public"
    error_message = "cleanup must cover every private and public subnet of this module"
  }

  assert {
    condition     = endswith(terraform_data.cluster_leftovers.input.script, "/cleanup-cluster-leftovers.sh")
    error_message = "cleanup must point at the module's script"
  }

  assert {
    condition     = terraform_data.cluster_leftovers.input.bash == "bash"
    error_message = "bash defaults to bash on PATH off Windows"
  }
}

run "bash_path_override" {
  command = plan

  variables {
    bash_path = "C:/tools/Git/bin/bash.exe"
  }

  assert {
    condition     = terraform_data.cluster_leftovers.input.bash == "C:/tools/Git/bin/bash.exe"
    error_message = "bash_path must override the detected bash"
  }
}
