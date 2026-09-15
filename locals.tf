locals {
  name_prefix = "${var.name_prefix}-${random_id.suffix.hex}"
  tags = merge(var.tags, {
    project    = "apim-self-hosted-lab"
    managed_by = "terraform"
  })

  virtual_network_name           = "${local.name_prefix}-vnet"
  virtual_network_cidr           = var.virtual_network_cidr
  apim_subnet_cidr               = cidrsubnet(var.virtual_network_cidr, 3, 0)
  aca_subnet_cidr                = cidrsubnet(var.virtual_network_cidr, 3, 1)
  appgw_subnet_cidr              = cidrsubnet(var.virtual_network_cidr, 3, 2)
  appgw_private_link_subnet_cidr = cidrsubnet(var.virtual_network_cidr, 3, 3)

  apim_gateway_hostname       = "${azurerm_api_management.apim.name}.azure-api.net"
  apim_configuration_hostname = "${azurerm_api_management.apim.name}.configuration.azure-api.net"
}
