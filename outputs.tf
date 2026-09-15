output "resource_group_name" {
  description = "Resource group containing the complete lab, including its VNet."
  value       = azurerm_resource_group.lab.name
}

output "virtual_network_name" {
  description = "Terraform-owned virtual network containing every workload subnet."
  value       = azurerm_virtual_network.lab.name
}

output "subnet_ids" {
  description = "IDs of the APIM, ACA, Application Gateway, and Application Gateway Private Link subnets."
  value = {
    apim               = azurerm_subnet.apim.id
    aca                = azurerm_subnet.aca.id
    appgw              = azurerm_subnet.appgw.id
    appgw_private_link = azurerm_subnet.appgw_private_link.id
  }
}

output "apim_name" {
  description = "Classic Developer API Management service name."
  value       = azurerm_api_management.apim.name
}

output "apim_private_ip_addresses" {
  description = "Internal APIM virtual IPs used by the private DNS records."
  value       = azurerm_api_management.apim.private_ip_addresses
}

output "aca_environment_name" {
  description = "Private workload profiles Container Apps environment."
  value       = azurerm_container_app_environment.aca.name
}

output "mock_app_fqdn" {
  description = "Private mock backend app hostname; not a public Front Door origin."
  value       = azurerm_container_app.mock.ingress[0].fqdn
}

output "gateway_app_fqdn" {
  description = "Self-hosted gateway hostname inside the private ACA environment."
  value       = azurerm_container_app.gateway.ingress[0].fqdn
}

output "managed_endpoint_url" {
  description = "Front Door -> Private Link -> Application Gateway -> managed APIM."
  value       = "https://${azurerm_cdn_frontdoor_endpoint.managed.host_name}"
}

output "self_hosted_endpoint_url" {
  description = "Front Door -> Private Link -> ACA self-hosted gateway."
  value       = "https://${azurerm_cdn_frontdoor_endpoint.self_hosted.host_name}"
}
