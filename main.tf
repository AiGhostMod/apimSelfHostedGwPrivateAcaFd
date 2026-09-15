resource "random_id" "suffix" {
  byte_length = 4
}

resource "azurerm_resource_group" "lab" {
  name     = "rg-${local.name_prefix}"
  location = var.location
  tags     = local.tags
}

resource "azurerm_virtual_network" "lab" {
  name                = local.virtual_network_name
  resource_group_name = azurerm_resource_group.lab.name
  location            = var.location
  address_space       = [local.virtual_network_cidr]
  dns_servers         = []
  tags                = local.tags
}
