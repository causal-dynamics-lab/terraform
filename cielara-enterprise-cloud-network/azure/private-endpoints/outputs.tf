output "private_endpoint_ids" {
  description = "Map of remote-cluster label -> private endpoint resource ID"
  value       = { for k, pe in azurerm_private_endpoint.remote_aks : k => pe.id }
}

output "private_endpoint_ips" {
  description = "Map of remote-cluster label -> private IP assigned to the endpoint in this VNet"
  value       = { for k, pe in azurerm_private_endpoint.remote_aks : k => pe.private_service_connection[0].private_ip_address }
}

# Note: azurerm_private_endpoint does not export the Pending/Approved connection
# state for a manual connection — it lives on the producer side. Check it with
# `az network private-endpoint-connection show` against the remote PLS, not here.

output "private_dns_zone_ids" {
  description = "Map of DNS zone name -> zone resource ID (one per remote region)"
  value       = { for z, zone in azurerm_private_dns_zone.remote_aks : z => zone.id }
}
