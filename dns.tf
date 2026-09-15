# Per-hostname zones avoid shadowing unrelated azure-api.net services in this VNet.
resource "azurerm_private_dns_zone" "apim_gateway" {
  name                = local.apim_gateway_hostname
  resource_group_name = azurerm_resource_group.lab.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone" "apim_configuration" {
  name                = local.apim_configuration_hostname
  resource_group_name = azurerm_resource_group.lab.name
  tags                = local.tags
}

resource "azurerm_private_dns_a_record" "apim_gateway" {
  name                = "@"
  zone_name           = azurerm_private_dns_zone.apim_gateway.name
  resource_group_name = azurerm_resource_group.lab.name
  ttl                 = 60
  records             = azurerm_api_management.apim.private_ip_addresses
  tags                = local.tags
}

resource "azurerm_private_dns_a_record" "apim_configuration" {
  name                = "@"
  zone_name           = azurerm_private_dns_zone.apim_configuration.name
  resource_group_name = azurerm_resource_group.lab.name
  ttl                 = 60
  records             = azurerm_api_management.apim.private_ip_addresses
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "apim_gateway" {
  name                  = "${local.name_prefix}-apim"
  resource_group_name   = azurerm_resource_group.lab.name
  private_dns_zone_name = azurerm_private_dns_zone.apim_gateway.name
  virtual_network_id    = azurerm_virtual_network.lab.id
  registration_enabled  = false
  tags                  = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "apim_configuration" {
  name                  = "${local.name_prefix}-configuration"
  resource_group_name   = azurerm_resource_group.lab.name
  private_dns_zone_name = azurerm_private_dns_zone.apim_configuration.name
  virtual_network_id    = azurerm_virtual_network.lab.id
  registration_enabled  = false
  tags                  = local.tags
}

resource "azurerm_private_dns_zone" "aca" {
  name                = azurerm_container_app_environment.aca.default_domain
  resource_group_name = azurerm_resource_group.lab.name
  tags                = local.tags
}

resource "azurerm_private_dns_a_record" "aca_wildcard" {
  name                = "*"
  zone_name           = azurerm_private_dns_zone.aca.name
  resource_group_name = azurerm_resource_group.lab.name
  ttl                 = 60
  records             = [azurerm_container_app_environment.aca.static_ip_address]
  tags                = local.tags
}

resource "azurerm_private_dns_a_record" "aca_apex" {
  name                = "@"
  zone_name           = azurerm_private_dns_zone.aca.name
  resource_group_name = azurerm_resource_group.lab.name
  ttl                 = 60
  records             = [azurerm_container_app_environment.aca.static_ip_address]
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "aca" {
  name                  = "${local.name_prefix}-aca"
  resource_group_name   = azurerm_resource_group.lab.name
  private_dns_zone_name = azurerm_private_dns_zone.aca.name
  virtual_network_id    = azurerm_virtual_network.lab.id
  registration_enabled  = false
  tags                  = local.tags
}
