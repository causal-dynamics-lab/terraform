# Offline plan-level tests for vnet_cidr validation and the derived subnet
# layout (including the new pe-subnet). mock_provider => no Azure creds.
# Run from azure/vnet:  terraform test

mock_provider "azurerm" {}

variables {
  subscription_id     = "00000000-0000-0000-0000-000000000000"
  tenant_id           = "00000000-0000-0000-0000-000000000000"
  resource_group_name = "rg"
  location            = "eastus2"
}

# The RG data source postcondition requires its location to equal var.location;
# pin the mocked data source (applies to every run) so plans don't trip on the
# random location the mock would otherwise generate.
override_data {
  target = data.azurerm_resource_group.main
  values = {
    location = "eastus2"
  }
}

# Default /20: subnets carve to the documented ranges; pe-subnet lands in the
# free 10.2.8.0/21 tail at 10.2.8.0/28.
run "default_cidr_derives_expected_subnets" {
  command = plan

  assert {
    condition     = azurerm_subnet.pe.address_prefixes[0] == "10.2.8.0/28"
    error_message = "pe-subnet should derive to 10.2.8.0/28 for the default 10.2.0.0/20"
  }

  assert {
    condition     = azurerm_subnet.pe.private_endpoint_network_policies == "Disabled"
    error_message = "pe-subnet must have private endpoint network policies disabled"
  }

  assert {
    condition     = azurerm_subnet.postgres.address_prefixes[0] == "10.2.1.64/28"
    error_message = "postgres-subnet drifted from its documented range (pe-subnet must not collide)"
  }
}

# Overlap with the Kubernetes service CIDR 10.1.0.0/16 must be rejected — base
# of the VNet equal to the service base.
run "rejects_service_cidr_overlap" {
  command = plan

  variables {
    vnet_cidr = "10.1.0.0/20"
  }

  expect_failures = [var.vnet_cidr]
}

# Non-base overlap: 10.1.16.0/20 sits inside 10.1.0.0/16 but its base is not
# 10.1.0.0. The old base-equality check missed this; the range check must catch it.
run "rejects_non_base_overlap_inside_service_cidr" {
  command = plan

  variables {
    vnet_cidr = "10.1.16.0/20"
  }

  expect_failures = [var.vnet_cidr]
}

# Superset overlap: 10.0.0.0/8 fully contains 10.1.0.0/16. Base (10.0.0.0) is
# not 10.1.0.0, but the ranges overlap, so it must be rejected.
run "rejects_supernet_containing_service_cidr" {
  command = plan

  variables {
    vnet_cidr = "10.0.0.0/8"
  }

  expect_failures = [var.vnet_cidr]
}

# A disjoint range just below the service CIDR (ends at 10.0.255.255) must pass —
# guards against an off-by-one in the range comparison.
run "accepts_disjoint_range_adjacent_below" {
  command = plan

  variables {
    vnet_cidr = "10.0.0.0/20"
  }

  assert {
    condition     = contains(azurerm_virtual_network.main.address_space, "10.0.0.0/20")
    error_message = "a disjoint range adjacent below the service CIDR should be accepted"
  }
}

# A block smaller than /20 can't fit the required subnets; must be rejected.
run "rejects_block_smaller_than_20" {
  command = plan

  variables {
    vnet_cidr = "10.2.0.0/24"
  }

  expect_failures = [var.vnet_cidr]
}
