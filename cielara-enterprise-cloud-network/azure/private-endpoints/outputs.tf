output "private_endpoint_ids" {
  description = "Map of remote-cluster label -> private endpoint resource ID"
  value       = { for k, pe in azurerm_private_endpoint.remote_aks : k => pe.id }
}

output "private_endpoint_ips" {
  description = "Map of remote-cluster label -> private IP assigned to the endpoint in this VNet"
  value       = { for k, pe in azurerm_private_endpoint.remote_aks : k => pe.private_service_connection[0].private_ip_address }
}

output "connection_states" {
  description = "Map of remote-cluster label -> connection state. Starts 'Pending' until the remote cluster owner approves the manual connection."
  value       = { for k, pe in azurerm_private_endpoint.remote_aks : k => pe.private_service_connection[0].private_connection_resource_id }
}

output "private_dns_zone_ids" {
  description = "Map of DNS zone name -> zone resource ID (one per remote region)"
  value       = { for z, zone in azurerm_private_dns_zone.remote_aks : z => zone.id }
}
