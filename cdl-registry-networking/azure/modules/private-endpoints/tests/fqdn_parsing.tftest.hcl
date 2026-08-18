# Offline plan-level tests for the FQDN -> (DNS zone, A-record host) parsing in
# main.tf locals. mock_provider means no Azure creds and no network calls.
# Run from azure/private-endpoints:  terraform test

mock_provider "azurerm" {}

variables {
  subscription_id     = "00000000-0000-0000-0000-000000000000"
  tenant_id           = "00000000-0000-0000-0000-000000000000"
  resource_group_name = "rg"
  vnet_name           = "cielara-vnet"
}

# The mock provider generates non-parseable fake IDs for data sources, which
# azurerm rejects when they feed subnet_id / virtual_network_id. Pin valid IDs
# (applies to every run) so the plan exercises the real parsing logic.
override_data {
  target = data.azurerm_virtual_network.main
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/cielara-vnet"
  }
}

override_data {
  target = data.azurerm_subnet.pe
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/cielara-vnet/subnets/pe-subnet"
  }
}

# A single cluster: zone name and record host are sliced from the FQDN around
# the "privatelink" label.
run "parses_zone_and_record_from_fqdn" {
  command = plan

  variables {
    remote_clusters = {
      a = {
        cluster_id = "/subscriptions/x/resourceGroups/rg-a/providers/Microsoft.ContainerService/managedClusters/aks-a"
        fqdn       = "myaks-abc.0123-guid.privatelink.eastus2.azmk8s.io"
      }
    }
  }

  assert {
    condition     = azurerm_private_dns_zone.remote_aks["privatelink.eastus2.azmk8s.io"].name == "privatelink.eastus2.azmk8s.io"
    error_message = "DNS zone name not parsed correctly from the FQDN"
  }

  assert {
    condition     = azurerm_private_dns_a_record.remote_aks["a"].name == "myaks-abc.0123-guid"
    error_message = "A-record host name not parsed correctly from the FQDN"
  }

  assert {
    condition     = azurerm_private_dns_a_record.remote_aks["a"].zone_name == "privatelink.eastus2.azmk8s.io"
    error_message = "A record is not attached to the parsed zone"
  }

  assert {
    condition     = azurerm_private_endpoint.remote_aks["a"].private_service_connection[0].is_manual_connection == false
    error_message = "default connection should be auto-approve (manual only for cross-tenant)"
  }

  assert {
    condition     = contains(azurerm_private_endpoint.remote_aks["a"].private_service_connection[0].subresource_names, "management")
    error_message = "AKS API-server PE must target the 'management' subresource"
  }
}

# Two clusters in the SAME region must share ONE DNS zone (zone is keyed by zone
# name, deduped via toset), while each still gets its own A record + endpoint.
run "clusters_in_same_region_share_one_zone" {
  command = plan

  variables {
    remote_clusters = {
      a = {
        cluster_id = "/subscriptions/x/resourceGroups/rg/providers/Microsoft.ContainerService/managedClusters/aks"
        fqdn       = "myaks-a.guid-a.privatelink.eastus2.azmk8s.io"
      }
      b = {
        cluster_id = "/subscriptions/x/resourceGroups/rg/providers/Microsoft.ContainerService/managedClusters/aks"
        fqdn       = "myaks-b.guid-b.privatelink.eastus2.azmk8s.io"
      }
    }
  }

  # Both A records land in the single shared eastus2 zone.
  assert {
    condition     = azurerm_private_dns_a_record.remote_aks["a"].zone_name == azurerm_private_dns_a_record.remote_aks["b"].zone_name
    error_message = "two clusters in the same region should resolve to the same DNS zone"
  }

  assert {
    condition     = azurerm_private_dns_a_record.remote_aks["a"].name == "myaks-a.guid-a"
    error_message = "cluster a A-record host not parsed correctly"
  }

  assert {
    condition     = azurerm_private_dns_a_record.remote_aks["b"].name == "myaks-b.guid-b"
    error_message = "cluster b A-record host not parsed correctly"
  }
}

# Clusters in DIFFERENT regions get distinct zones, parsed independently.
run "clusters_in_different_regions_get_distinct_zones" {
  command = plan

  variables {
    remote_clusters = {
      a = {
        cluster_id = "/subscriptions/x/resourceGroups/rg/providers/Microsoft.ContainerService/managedClusters/aks"
        fqdn       = "myaks-a.guid-a.privatelink.eastus2.azmk8s.io"
      }
      b = {
        cluster_id = "/subscriptions/x/resourceGroups/rg/providers/Microsoft.ContainerService/managedClusters/aks"
        fqdn       = "myaks-b.guid-b.privatelink.westus3.azmk8s.io"
      }
    }
  }

  assert {
    condition     = azurerm_private_dns_a_record.remote_aks["a"].zone_name == "privatelink.eastus2.azmk8s.io"
    error_message = "eastus2 zone not parsed for cluster a"
  }

  assert {
    condition     = azurerm_private_dns_a_record.remote_aks["b"].zone_name == "privatelink.westus3.azmk8s.io"
    error_message = "westus3 zone not parsed for cluster b"
  }
}

# A malformed FQDN (no "privatelink" label) must be rejected by variable
# validation, not silently mis-parsed.
run "rejects_fqdn_without_privatelink_label" {
  command = plan

  variables {
    remote_clusters = {
      bad = {
        cluster_id = "/subscriptions/x/resourceGroups/rg/providers/Microsoft.ContainerService/managedClusters/aks"
        fqdn       = "myaks.example.azmk8s.io"
      }
    }
  }

  expect_failures = [var.remote_clusters]
}
