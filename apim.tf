# Internal-mode classic APIM no longer requires a customer-owned public IP
# (May 2024): https://learn.microsoft.com/azure/api-management/api-management-using-with-internal-vnet
resource "azurerm_api_management" "apim" {
  name                 = "${local.name_prefix}-apim"
  location             = var.location
  resource_group_name  = azurerm_resource_group.lab.name
  publisher_name       = var.publisher_name
  publisher_email      = var.publisher_email
  sku_name             = "Developer_1"
  virtual_network_type = "Internal"
  gateway_disabled     = false
  tags                 = local.tags

  virtual_network_configuration {
    subnet_id = azurerm_subnet.apim.id
  }

  depends_on = [
    azurerm_subnet_network_security_group_association.apim,
    azurerm_subnet_nat_gateway_association.apim,
    azurerm_nat_gateway_public_ip_association.apim,
  ]
}

resource "azurerm_api_management_api" "mock" {
  name                  = "mock-api"
  resource_group_name   = azurerm_resource_group.lab.name
  api_management_name   = azurerm_api_management.apim.name
  revision              = "1"
  display_name          = "Mock API"
  path                  = ""
  protocols             = ["http", "https"]
  subscription_required = false
  # "External" app ingress publishes at the INTERNAL environment's private
  # load balancer, not the internet; managed APIM needs this VNet visibility.
  service_url = "https://${azurerm_container_app.mock.ingress[0].fqdn}"

  lifecycle {
    precondition {
      condition = (
        azurerm_container_app.mock.ingress[0].external_enabled &&
        azurerm_container_app_environment.aca.internal_load_balancer_enabled &&
        azurerm_container_app_environment.aca.public_network_access == "Disabled"
      )
      error_message = "Direct managed APIM backend access requires VNet-visible mock ingress in an internal, public-network-disabled ACA environment. Environment-only app ingress returns 404 from the APIM subnet."
    }
  }
}

resource "azurerm_api_management_api_operation" "get" {
  operation_id        = "get"
  api_name            = azurerm_api_management_api.mock.name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.lab.name
  display_name        = "GET /get"
  method              = "GET"
  url_template        = "/get"
}

resource "azurerm_api_management_api_operation" "post" {
  operation_id        = "post"
  api_name            = azurerm_api_management_api.mock.name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.lab.name
  display_name        = "POST /post"
  method              = "POST"
  url_template        = "/post"
}

resource "azurerm_api_management_gateway" "self_hosted" {
  name              = "self-hosted"
  api_management_id = azurerm_api_management.apim.id
  description       = "Single self-hosted gateway in the private Container Apps environment"

  location_data {
    name   = var.location
    region = var.location
  }
}

resource "azurerm_api_management_gateway_api" "mock" {
  gateway_id = azurerm_api_management_gateway.self_hosted.id
  # Azure canonicalizes gateway associations to the revisionless API ID.
  api_id = replace(azurerm_api_management_api.mock.id, "/;rev=[^/;]+$/", "")

  depends_on = [
    azurerm_api_management_api_operation.get,
    azurerm_api_management_api_operation.post,
  ]
}
