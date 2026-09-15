resource "azurerm_subnet" "apim" {
  name                                          = "${local.name_prefix}-apim"
  virtual_network_name                          = azurerm_virtual_network.lab.name
  resource_group_name                           = azurerm_resource_group.lab.name
  address_prefixes                              = [local.apim_subnet_cidr]
  default_outbound_access_enabled               = false
  private_endpoint_network_policies             = "Disabled"
  private_link_service_network_policies_enabled = true
}

resource "azurerm_subnet" "aca" {
  name                                          = "${local.name_prefix}-aca"
  virtual_network_name                          = azurerm_virtual_network.lab.name
  resource_group_name                           = azurerm_resource_group.lab.name
  address_prefixes                              = [local.aca_subnet_cidr]
  default_outbound_access_enabled               = false
  private_endpoint_network_policies             = "Disabled"
  private_link_service_network_policies_enabled = true

  delegation {
    name = "container-apps"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }

  # Azure serializes subnet writes within a VNet.
  depends_on = [azurerm_subnet.apim]
}

resource "azurerm_subnet" "appgw" {
  name                                          = "${local.name_prefix}-appgw"
  virtual_network_name                          = azurerm_virtual_network.lab.name
  resource_group_name                           = azurerm_resource_group.lab.name
  address_prefixes                              = [local.appgw_subnet_cidr]
  default_outbound_access_enabled               = false
  private_endpoint_network_policies             = "Disabled"
  private_link_service_network_policies_enabled = true

  # Azure serializes subnet writes within a VNet.
  depends_on = [azurerm_subnet.aca]
}

resource "azurerm_subnet" "appgw_private_link" {
  name                                          = "${local.name_prefix}-appgw-pl"
  virtual_network_name                          = azurerm_virtual_network.lab.name
  resource_group_name                           = azurerm_resource_group.lab.name
  address_prefixes                              = [local.appgw_private_link_subnet_cidr]
  default_outbound_access_enabled               = false
  private_endpoint_network_policies             = "Disabled"
  private_link_service_network_policies_enabled = false

  depends_on = [azurerm_subnet.appgw]
}

resource "azurerm_network_security_group" "apim" {
  name                = "${local.name_prefix}-apim-nsg"
  resource_group_name = azurerm_resource_group.lab.name
  location            = var.location
  tags                = local.tags
}

resource "azurerm_network_security_group" "aca" {
  name                = "${local.name_prefix}-aca-nsg"
  resource_group_name = azurerm_resource_group.lab.name
  location            = var.location
  tags                = local.tags
}

resource "azurerm_network_security_group" "appgw" {
  name                = "${local.name_prefix}-appgw-nsg"
  resource_group_name = azurerm_resource_group.lab.name
  location            = var.location
  tags                = local.tags
}

locals {
  # Platform DNS bypasses NSGs unless explicitly blocked with AzurePlatformDNS.
  # That service tag supports Deny only; no DNS rule is needed, even with deny-all.
  # HTTP(S) Internet egress intentionally covers certificate, update, and CDN
  # dependencies that cannot be expressed reliably with NSG service tags.
  apim_nsg_rules = {
    management           = { priority = 100, direction = "Inbound", protocol = "Tcp", source = "ApiManagement", destination = local.apim_subnet_cidr, ports = ["3443"], access = "Allow" }
    load_balancer        = { priority = 110, direction = "Inbound", protocol = "Tcp", source = "AzureLoadBalancer", destination = local.apim_subnet_cidr, ports = ["6390", "6391"], access = "Allow" }
    appgw                = { priority = 120, direction = "Inbound", protocol = "Tcp", source = local.appgw_subnet_cidr, destination = local.apim_subnet_cidr, ports = ["443"], access = "Allow" }
    configuration        = { priority = 130, direction = "Inbound", protocol = "Tcp", source = local.aca_subnet_cidr, destination = local.apim_subnet_cidr, ports = ["443"], access = "Allow" }
    intra_subnet_in      = { priority = 140, direction = "Inbound", protocol = "*", source = local.apim_subnet_cidr, destination = local.apim_subnet_cidr, ports = ["*"], access = "Allow" }
    deny_other_in        = { priority = 4096, direction = "Inbound", protocol = "*", source = "*", destination = "*", ports = ["*"], access = "Deny" }
    storage              = { priority = 110, direction = "Outbound", protocol = "Tcp", source = local.apim_subnet_cidr, destination = "Storage", ports = ["443"], access = "Allow" }
    sql                  = { priority = 120, direction = "Outbound", protocol = "Tcp", source = local.apim_subnet_cidr, destination = "Sql", ports = ["1433"], access = "Allow" }
    key_vault            = { priority = 130, direction = "Outbound", protocol = "Tcp", source = local.apim_subnet_cidr, destination = "AzureKeyVault", ports = ["443"], access = "Allow" }
    entra                = { priority = 140, direction = "Outbound", protocol = "Tcp", source = local.apim_subnet_cidr, destination = "AzureActiveDirectory", ports = ["443"], access = "Allow" }
    monitor              = { priority = 150, direction = "Outbound", protocol = "Tcp", source = local.apim_subnet_cidr, destination = "AzureMonitor", ports = ["1886", "443"], access = "Allow" }
    event_hub            = { priority = 160, direction = "Outbound", protocol = "Tcp", source = local.apim_subnet_cidr, destination = "EventHub", ports = ["5671", "5672", "443"], access = "Allow" }
    backend              = { priority = 170, direction = "Outbound", protocol = "Tcp", source = local.apim_subnet_cidr, destination = local.aca_subnet_cidr, ports = ["80", "443"], access = "Allow" }
    intra_subnet_out     = { priority = 180, direction = "Outbound", protocol = "*", source = local.apim_subnet_cidr, destination = local.apim_subnet_cidr, ports = ["*"], access = "Allow" }
    certificates_updates = { priority = 190, direction = "Outbound", protocol = "Tcp", source = local.apim_subnet_cidr, destination = "Internet", ports = ["80", "443"], access = "Allow" }
    ntp                  = { priority = 200, direction = "Outbound", protocol = "Udp", source = local.apim_subnet_cidr, destination = "Internet", ports = ["123"], access = "Allow" }
    kms                  = { priority = 210, direction = "Outbound", protocol = "Tcp", source = local.apim_subnet_cidr, destination = "AzureCloud", ports = ["1688"], access = "Allow" }
    deny_other_out       = { priority = 4096, direction = "Outbound", protocol = "*", source = "*", destination = "*", ports = ["*"], access = "Deny" }
  }

  aca_nsg_rules = {
    # Private Link traffic does not necessarily carry a VirtualNetwork source tag.
    private_ingress    = { priority = 100, direction = "Inbound", protocol = "Tcp", source = "*", destination = local.aca_subnet_cidr, ports = ["80", "443", "31080", "31443"], access = "Allow" }
    load_balancer      = { priority = 110, direction = "Inbound", protocol = "Tcp", source = "AzureLoadBalancer", destination = local.aca_subnet_cidr, ports = ["30000-32767"], access = "Allow" }
    intra_subnet_in    = { priority = 120, direction = "Inbound", protocol = "*", source = local.aca_subnet_cidr, destination = local.aca_subnet_cidr, ports = ["*"], access = "Allow" }
    deny_other_in      = { priority = 4096, direction = "Inbound", protocol = "*", source = "*", destination = "*", ports = ["*"], access = "Deny" }
    mcr                = { priority = 110, direction = "Outbound", protocol = "Tcp", source = local.aca_subnet_cidr, destination = "MicrosoftContainerRegistry", ports = ["443"], access = "Allow" }
    mcr_cdn            = { priority = 120, direction = "Outbound", protocol = "Tcp", source = local.aca_subnet_cidr, destination = "AzureFrontDoor.FirstParty", ports = ["443"], access = "Allow" }
    acr                = { priority = 130, direction = "Outbound", protocol = "Tcp", source = local.aca_subnet_cidr, destination = "AzureContainerRegistry", ports = ["443"], access = "Allow" }
    storage            = { priority = 140, direction = "Outbound", protocol = "Tcp", source = local.aca_subnet_cidr, destination = "Storage", ports = ["443"], access = "Allow" }
    entra              = { priority = 150, direction = "Outbound", protocol = "Tcp", source = local.aca_subnet_cidr, destination = "AzureActiveDirectory", ports = ["443"], access = "Allow" }
    monitor            = { priority = 160, direction = "Outbound", protocol = "Tcp", source = local.aca_subnet_cidr, destination = "AzureMonitor", ports = ["443"], access = "Allow" }
    apim_configuration = { priority = 170, direction = "Outbound", protocol = "Tcp", source = local.aca_subnet_cidr, destination = local.apim_subnet_cidr, ports = ["443"], access = "Allow" }
    intra_subnet_out   = { priority = 180, direction = "Outbound", protocol = "*", source = local.aca_subnet_cidr, destination = local.aca_subnet_cidr, ports = ["*"], access = "Allow" }
    platform_https     = { priority = 190, direction = "Outbound", protocol = "Tcp", source = local.aca_subnet_cidr, destination = "Internet", ports = ["80", "443"], access = "Allow" }
    ntp                = { priority = 200, direction = "Outbound", protocol = "Udp", source = local.aca_subnet_cidr, destination = "Internet", ports = ["123"], access = "Allow" }
    deny_other_out     = { priority = 4096, direction = "Outbound", protocol = "*", source = "*", destination = "*", ports = ["*"], access = "Deny" }
  }

  appgw_nsg_rules = {
    # Private Link preserves consumer addresses; AFD's managed subnet is not ours.
    # Only the private frontend has a listener, so this does not publish HTTP.
    private_link    = { priority = 100, direction = "Inbound", protocol = "Tcp", source = "*", destination = local.appgw_subnet_cidr, ports = ["80"], access = "Allow" }
    gateway_manager = { priority = 110, direction = "Inbound", protocol = "Tcp", source = "GatewayManager", destination = "*", ports = ["65200-65535"], access = "Allow" }
    load_balancer   = { priority = 120, direction = "Inbound", protocol = "*", source = "AzureLoadBalancer", destination = "*", ports = ["*"], access = "Allow" }
    intra_subnet    = { priority = 130, direction = "Inbound", protocol = "*", source = local.appgw_subnet_cidr, destination = local.appgw_subnet_cidr, ports = ["*"], access = "Allow" }
    deny_other_in   = { priority = 4096, direction = "Inbound", protocol = "*", source = "*", destination = "*", ports = ["*"], access = "Deny" }
    apim            = { priority = 110, direction = "Outbound", protocol = "Tcp", source = local.appgw_subnet_cidr, destination = local.apim_subnet_cidr, ports = ["443"], access = "Allow" }
    # Retain Azure's default outbound allow for Application Gateway infrastructure.
  }
}

resource "azurerm_network_security_rule" "apim" {
  for_each = local.apim_nsg_rules

  name                        = each.key
  priority                    = each.value.priority
  direction                   = each.value.direction
  access                      = each.value.access
  protocol                    = each.value.protocol
  source_port_range           = "*"
  destination_port_range      = length(each.value.ports) == 1 ? each.value.ports[0] : null
  destination_port_ranges     = length(each.value.ports) > 1 ? each.value.ports : null
  source_address_prefix       = each.value.source
  destination_address_prefix  = each.value.destination
  resource_group_name         = azurerm_resource_group.lab.name
  network_security_group_name = azurerm_network_security_group.apim.name
}

resource "azurerm_network_security_rule" "aca" {
  for_each = local.aca_nsg_rules

  name                        = each.key
  priority                    = each.value.priority
  direction                   = each.value.direction
  access                      = each.value.access
  protocol                    = each.value.protocol
  source_port_range           = "*"
  destination_port_range      = length(each.value.ports) == 1 ? each.value.ports[0] : null
  destination_port_ranges     = length(each.value.ports) > 1 ? each.value.ports : null
  source_address_prefix       = each.value.source
  destination_address_prefix  = each.value.destination
  resource_group_name         = azurerm_resource_group.lab.name
  network_security_group_name = azurerm_network_security_group.aca.name
}

resource "azurerm_network_security_rule" "appgw" {
  for_each = local.appgw_nsg_rules

  name                        = each.key
  priority                    = each.value.priority
  direction                   = each.value.direction
  access                      = each.value.access
  protocol                    = each.value.protocol
  source_port_range           = "*"
  destination_port_range      = length(each.value.ports) == 1 ? each.value.ports[0] : null
  destination_port_ranges     = length(each.value.ports) > 1 ? each.value.ports : null
  source_address_prefix       = each.value.source
  destination_address_prefix  = each.value.destination
  resource_group_name         = azurerm_resource_group.lab.name
  network_security_group_name = azurerm_network_security_group.appgw.name
}

resource "azurerm_subnet_network_security_group_association" "apim" {
  subnet_id                 = azurerm_subnet.apim.id
  network_security_group_id = azurerm_network_security_group.apim.id

  depends_on = [azurerm_network_security_rule.apim, azurerm_subnet.appgw_private_link]
}

resource "azurerm_subnet_network_security_group_association" "aca" {
  subnet_id                 = azurerm_subnet.aca.id
  network_security_group_id = azurerm_network_security_group.aca.id

  depends_on = [azurerm_network_security_rule.aca, azurerm_subnet_network_security_group_association.apim]
}

resource "azurerm_subnet_network_security_group_association" "appgw" {
  subnet_id                 = azurerm_subnet.appgw.id
  network_security_group_id = azurerm_network_security_group.appgw.id

  depends_on = [azurerm_network_security_rule.appgw, azurerm_subnet_network_security_group_association.aca]
}

resource "azurerm_public_ip" "egress" {
  for_each = toset(["apim", "aca"])

  name                = "${local.name_prefix}-${each.key}-egress"
  resource_group_name = azurerm_resource_group.lab.name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_nat_gateway" "egress" {
  for_each = toset(["apim", "aca"])

  name                    = "${local.name_prefix}-${each.key}-nat"
  resource_group_name     = azurerm_resource_group.lab.name
  location                = var.location
  sku_name                = "Standard"
  idle_timeout_in_minutes = 10
  tags                    = local.tags
}

resource "azurerm_nat_gateway_public_ip_association" "apim" {
  nat_gateway_id       = azurerm_nat_gateway.egress["apim"].id
  public_ip_address_id = azurerm_public_ip.egress["apim"].id
}

resource "azurerm_nat_gateway_public_ip_association" "aca" {
  nat_gateway_id       = azurerm_nat_gateway.egress["aca"].id
  public_ip_address_id = azurerm_public_ip.egress["aca"].id
}

resource "azurerm_subnet_nat_gateway_association" "apim" {
  subnet_id      = azurerm_subnet.apim.id
  nat_gateway_id = azurerm_nat_gateway.egress["apim"].id

  depends_on = [
    azurerm_nat_gateway_public_ip_association.apim,
    azurerm_subnet_network_security_group_association.appgw,
  ]

}

resource "azurerm_subnet_nat_gateway_association" "aca" {
  subnet_id      = azurerm_subnet.aca.id
  nat_gateway_id = azurerm_nat_gateway.egress["aca"].id

  depends_on = [
    azurerm_nat_gateway_public_ip_association.aca,
    azurerm_subnet_nat_gateway_association.apim,
  ]

}
