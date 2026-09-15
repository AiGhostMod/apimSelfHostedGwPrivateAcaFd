variable "frontdoor_private_link_location" {
  type        = string
  default     = "swedencentral"
  description = "Front Door managed Private Link region, not necessarily the origin region. Sweden Central is supported: https://learn.microsoft.com/azure/frontdoor/private-link#region-availability"
}

locals {
  # AzureRM restricts target_type to an enum; use an allowed value as the actual
  # frontend name so the AppGW group ID and the provider validation both agree.
  appgw_private_frontend_name = "Gateway"
  edge_private_link_messages = {
    managed     = "${local.name_prefix}:afd:managed:appgw"
    self_hosted = "${local.name_prefix}:afd:self-hosted:aca"
  }
}

data "azapi_resource" "appgw_network_isolation" {
  # AzAPI matches the innermost provider namespace in the full Features API ID.
  type                   = "Microsoft.Network/features@2021-07-01"
  resource_id            = "/subscriptions/${var.subscription_id}/providers/Microsoft.Features/providers/Microsoft.Network/features/EnableApplicationGatewayNetworkIsolation"
  response_export_values = ["properties.state"]
}

# Private-only frontends do NOT support Application Gateway Private Link.
# Keep the conventional v2 public frontend for infrastructure, WITHOUT a listener.
# Do not register EnableApplicationGatewayNetworkIsolation for this deployment.
# https://learn.microsoft.com/azure/application-gateway/application-gateway-private-deployment#limitations--known-issues
resource "azurerm_public_ip" "appgw_infrastructure" {
  name                = "${local.name_prefix}-appgw-infrastructure"
  resource_group_name = azurerm_resource_group.lab.name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_application_gateway" "bridge" {
  name                = "${local.name_prefix}-bridge"
  resource_group_name = azurerm_resource_group.lab.name
  location            = var.location
  tags                = local.tags

  sku {
    name     = "Standard_v2"
    tier     = "Standard_v2"
    capacity = 1
  }
  gateway_ip_configuration {
    name      = "gateway"
    subnet_id = azurerm_subnet.appgw.id
  }
  frontend_ip_configuration {
    name                 = "infrastructure-only"
    public_ip_address_id = azurerm_public_ip.appgw_infrastructure.id
  }
  frontend_ip_configuration {
    name                            = local.appgw_private_frontend_name
    subnet_id                       = azurerm_subnet.appgw.id
    private_ip_address_allocation   = "Static"
    private_ip_address              = cidrhost(azurerm_subnet.appgw.address_prefixes[0], -2)
    private_link_configuration_name = "frontdoor"
  }
  private_link_configuration {
    name = "frontdoor"
    ip_configuration {
      name                          = "primary"
      primary                       = true
      subnet_id                     = azurerm_subnet.appgw_private_link.id
      private_ip_address_allocation = "Dynamic"
    }
  }
  frontend_port {
    name = "http"
    port = 80
  }
  http_listener {
    name                           = "private-http"
    frontend_ip_configuration_name = local.appgw_private_frontend_name
    frontend_port_name             = "http"
    protocol                       = "Http"
    host_name                      = local.apim_gateway_hostname
  }
  backend_address_pool {
    name  = "apim"
    fqdns = [local.apim_gateway_hostname]
  }
  backend_http_settings {
    name                  = "apim-https"
    cookie_based_affinity = "Disabled"
    port                  = 443
    protocol              = "Https"
    host_name             = local.apim_gateway_hostname
    request_timeout       = 60
    probe_name            = "apim-status"
  }
  probe {
    name                = "apim-status"
    protocol            = "Https"
    host                = local.apim_gateway_hostname
    path                = "/status-0123456789abcdef"
    interval            = 30
    timeout             = 30
    unhealthy_threshold = 3
    match {
      status_code = ["200"]
    }
  }
  request_routing_rule {
    name                       = "apim"
    priority                   = 100
    rule_type                  = "Basic"
    http_listener_name         = "private-http"
    backend_address_pool_name  = "apim"
    backend_http_settings_name = "apim-https"
  }
  lifecycle {
    precondition {
      condition     = contains(["NotRegistered", "Unregistered"], data.azapi_resource.appgw_network_isolation.output.properties.state)
      error_message = "This Private Link bridge requires conventional Application Gateway v2. Network isolation is registered or changing; coordinate with the subscription owner. This lab will not change shared feature registrations."
    }
  }

  depends_on = [
    azurerm_subnet_network_security_group_association.appgw,
    azurerm_private_dns_a_record.apim_gateway,
    azurerm_private_dns_zone_virtual_network_link.apim_gateway,
  ]
}

resource "azurerm_cdn_frontdoor_profile" "lab" {
  name                = "${local.name_prefix}-afd"
  resource_group_name = azurerm_resource_group.lab.name
  sku_name            = "Premium_AzureFrontDoor"
  tags                = local.tags
}

resource "azurerm_cdn_frontdoor_endpoint" "managed" {
  name                     = "${local.name_prefix}-managed"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.lab.id
  tags                     = local.tags
}

resource "azurerm_cdn_frontdoor_endpoint" "self_hosted" {
  name                     = "${local.name_prefix}-self-hosted"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.lab.id
  tags                     = local.tags
}

resource "azurerm_cdn_frontdoor_origin_group" "managed" {
  name                     = "managed"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.lab.id
  session_affinity_enabled = false
  load_balancing {}
  health_probe {
    interval_in_seconds = 30
    path                = "/status-0123456789abcdef"
    protocol            = "Http"
    request_type        = "GET"
  }
}

resource "azurerm_cdn_frontdoor_origin_group" "self_hosted" {
  name                     = "self-hosted"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.lab.id
  session_affinity_enabled = false
  load_balancing {}
  health_probe {
    interval_in_seconds = 30
    path                = "/get"
    protocol            = "Https"
    request_type        = "GET"
  }
}

resource "azurerm_cdn_frontdoor_origin" "managed" {
  name                           = "appgw"
  cdn_frontdoor_origin_group_id  = azurerm_cdn_frontdoor_origin_group.managed.id
  host_name                      = local.apim_gateway_hostname
  origin_host_header             = local.apim_gateway_hostname
  certificate_name_check_enabled = true
  http_port                      = 80
  https_port                     = 443
  enabled                        = true
  private_link {
    private_link_target_id = azurerm_application_gateway.bridge.id
    # Application Gateway's group ID is its frontend configuration name, not "sites".
    target_type     = local.appgw_private_frontend_name
    location        = var.frontdoor_private_link_location
    request_message = local.edge_private_link_messages.managed
  }
}

resource "azurerm_cdn_frontdoor_origin" "self_hosted" {
  name                           = "aca"
  cdn_frontdoor_origin_group_id  = azurerm_cdn_frontdoor_origin_group.self_hosted.id
  host_name                      = azurerm_container_app.gateway.ingress[0].fqdn
  origin_host_header             = azurerm_container_app.gateway.ingress[0].fqdn
  certificate_name_check_enabled = true
  http_port                      = 80
  https_port                     = 443
  enabled                        = true
  private_link {
    private_link_target_id = azurerm_container_app_environment.aca.id
    target_type            = "managedEnvironments"
    location               = var.frontdoor_private_link_location
    request_message        = local.edge_private_link_messages.self_hosted
  }
  depends_on = [azurerm_private_dns_zone_virtual_network_link.aca]
}

resource "terraform_data" "approve_private_endpoints" {
  for_each = {
    managed = {
      target_id = azurerm_application_gateway.bridge.id
      origin_id = azurerm_cdn_frontdoor_origin.managed.id
      kind      = "appgw"
    }
    self_hosted = {
      target_id = azurerm_container_app_environment.aca.id
      origin_id = azurerm_cdn_frontdoor_origin.self_hosted.id
      kind      = "aca"
    }
  }
  triggers_replace = [
    each.value.target_id,
    each.value.origin_id,
    local.edge_private_link_messages[each.key],
    var.frontdoor_private_link_location,
    filesha256("${path.module}/scripts/approve-private-endpoints.sh"),
  ]
  lifecycle {
    replace_triggered_by = [
      azurerm_cdn_frontdoor_origin.managed,
      azurerm_cdn_frontdoor_origin.self_hosted,
    ]
  }
  provisioner "local-exec" {
    command = "bash \"$APPROVAL_SCRIPT\""
    environment = {
      APPROVAL_SCRIPT = "${path.module}/scripts/approve-private-endpoints.sh"
      TARGET_ID       = each.value.target_id
      TARGET_KIND     = each.value.kind
      REQUEST_MESSAGE = local.edge_private_link_messages[each.key]
      SUBSCRIPTION_ID = var.subscription_id
      TENANT_ID       = var.tenant_id
    }
  }
}

resource "azurerm_cdn_frontdoor_route" "managed" {
  name                          = "managed"
  cdn_frontdoor_endpoint_id     = azurerm_cdn_frontdoor_endpoint.managed.id
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.managed.id
  cdn_frontdoor_origin_ids      = [azurerm_cdn_frontdoor_origin.managed.id]
  patterns_to_match             = ["/*"]
  supported_protocols           = ["Http", "Https"]
  forwarding_protocol           = "HttpOnly"
  https_redirect_enabled        = true
  link_to_default_domain        = true
  # No cache block or origin_path: preserve API paths and never cache responses.
  depends_on = [terraform_data.approve_private_endpoints]
}

resource "azurerm_cdn_frontdoor_route" "self_hosted" {
  name                          = "self-hosted"
  cdn_frontdoor_endpoint_id     = azurerm_cdn_frontdoor_endpoint.self_hosted.id
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.self_hosted.id
  cdn_frontdoor_origin_ids      = [azurerm_cdn_frontdoor_origin.self_hosted.id]
  patterns_to_match             = ["/*"]
  supported_protocols           = ["Http", "Https"]
  forwarding_protocol           = "HttpsOnly"
  https_redirect_enabled        = true
  link_to_default_domain        = true
  depends_on                    = [terraform_data.approve_private_endpoints]
}
