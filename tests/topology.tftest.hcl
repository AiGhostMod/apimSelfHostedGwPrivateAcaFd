# Every run is plan-only and every Azure provider is mocked. Provisioners never run.
mock_provider "azurerm" {
  mock_resource "azurerm_virtual_network" {
    defaults = {
      id            = "/subscriptions/87101dd8-0f2d-4b39-83ac-38aa3035a537/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/test-vnet"
      location      = "swedencentral"
      address_space = ["10.47.0.0/24"]
      dns_servers   = []
    }
  }

  mock_resource "azurerm_subnet" {
    defaults = {
      name                                          = "test-subnet"
      resource_group_name                           = "rg-test"
      virtual_network_name                          = "test-vnet"
      address_prefixes                              = ["10.47.0.32/27"]
      default_outbound_access_enabled               = false
      private_endpoint_network_policies             = "Disabled"
      private_link_service_network_policies_enabled = true
      service_endpoints                             = []
      service_endpoint_policy_ids                   = []
      delegation                                    = []
    }
  }

  mock_resource "azurerm_api_management" {
    override_during = plan
    defaults = {
      id                   = "/subscriptions/87101dd8-0f2d-4b39-83ac-38aa3035a537/resourceGroups/rg-test/providers/Microsoft.ApiManagement/service/test-apim"
      private_ip_addresses = ["10.47.0.4"]
    }
  }

  mock_resource "azurerm_container_app_environment" {
    override_during = plan
    defaults = {
      id                = "/subscriptions/87101dd8-0f2d-4b39-83ac-38aa3035a537/resourceGroups/rg-test/providers/Microsoft.App/managedEnvironments/test-aca"
      default_domain    = "test.swedencentral.azurecontainerapps.io"
      static_ip_address = "10.47.0.36"
    }
  }
}

mock_provider "azapi" {
  mock_data "azapi_resource" {
    defaults = {
      output = {
        properties = {
          state = "NotRegistered"
        }
      }
    }
  }
}

mock_provider "random" {
  override_during = plan
  mock_resource "random_id" {
    defaults = {
      hex = "1234abcd"
    }
  }
}

mock_provider "time" {}

variables {
  publisher_email = "operator@example.com"
}

run "private_topology" {
  command = plan

  override_resource {
    target          = azurerm_api_management_api.mock
    override_during = plan
    values = {
      id = "/subscriptions/87101dd8-0f2d-4b39-83ac-38aa3035a537/resourceGroups/rg-test/providers/Microsoft.ApiManagement/service/test-apim/apis/mock-api;rev=1"
    }
  }

  assert {
    condition     = azurerm_api_management_gateway_api.mock.api_id == "/subscriptions/87101dd8-0f2d-4b39-83ac-38aa3035a537/resourceGroups/rg-test/providers/Microsoft.ApiManagement/service/test-apim/apis/mock-api"
    error_message = "Gateway associations must remove the API revision suffix without changing the resource ID prefix or API path."
  }

  assert {
    condition = (
      provider::azapi::parse_resource_id(
        split("@", data.azapi_resource.appgw_network_isolation.type)[0],
        data.azapi_resource.appgw_network_isolation.resource_id
      ).id == "/subscriptions/${var.subscription_id}/providers/Microsoft.Features/providers/Microsoft.Network/features/EnableApplicationGatewayNetworkIsolation"
    )
    error_message = "The feature lookup must preserve the full Microsoft.Features GET path and use its matching AzAPI resource type."
  }

  assert {
    condition = (
      azurerm_api_management.apim.sku_name == "Developer_1" &&
      azurerm_api_management.apim.virtual_network_type == "Internal"
    )
    error_message = "Preserve classic Developer capacity one in internal VNet mode."
  }

  assert {
    condition = (
      length(azurerm_virtual_network.lab.address_space) == 1 &&
      contains(azurerm_virtual_network.lab.address_space, "10.47.0.0/24") &&
      length(azurerm_virtual_network.lab.dns_servers) == 0 &&
      azurerm_virtual_network.lab.resource_group_name == azurerm_resource_group.lab.name &&
      length(azurerm_subnet.apim.address_prefixes) == 1 &&
      contains(azurerm_subnet.apim.address_prefixes, "10.47.0.0/27") &&
      azurerm_subnet.apim.virtual_network_name == azurerm_virtual_network.lab.name &&
      !azurerm_subnet.apim.default_outbound_access_enabled
    )
    error_message = "Terraform must create the VNet and APIM subnet in the workload resource group from the configured CIDR."
  }

  assert {
    condition = (
      length(azurerm_subnet.aca.address_prefixes) == 1 &&
      contains(azurerm_subnet.aca.address_prefixes, "10.47.0.32/27") &&
      azurerm_subnet.aca.virtual_network_name == azurerm_virtual_network.lab.name &&
      !azurerm_subnet.aca.default_outbound_access_enabled &&
      azurerm_subnet.aca.private_endpoint_network_policies == "Disabled" &&
      azurerm_subnet.aca.private_link_service_network_policies_enabled &&
      azurerm_subnet.aca.delegation[0].service_delegation[0].name == "Microsoft.App/environments"
    )
    error_message = "Create a dedicated ACA subnet with the required delegation and private networking settings."
  }

  assert {
    condition = (
      contains(azurerm_subnet.appgw.address_prefixes, "10.47.0.64/27") &&
      contains(azurerm_subnet.appgw_private_link.address_prefixes, "10.47.0.96/27") &&
      !azurerm_subnet.appgw_private_link.private_link_service_network_policies_enabled
    )
    error_message = "The bridge and its Private Link configuration need distinct dedicated subnets."
  }

  assert {
    condition = (
      azurerm_container_app_environment.aca.internal_load_balancer_enabled &&
      azurerm_container_app_environment.aca.public_network_access == "Disabled" &&
      length(azurerm_container_app_environment.aca.workload_profile) > 0
    )
    error_message = "ACA must be a private workload profiles environment, not legacy Consumption-only."
  }

  assert {
    condition = (
      azurerm_container_app.gateway.template[0].min_replicas == 1 &&
      azurerm_container_app.gateway.template[0].max_replicas == 1 &&
      azurerm_container_app.gateway.template[0].container[0].image == "mcr.microsoft.com/azure-api-management/gateway:v2" &&
      azurerm_container_app.gateway.ingress[0].external_enabled
    )
    error_message = "Run one official v2 gateway replica and expose it only through the private environment."
  }

  assert {
    condition = (
      azapi_resource_action.gateway_token.action == "generateToken" &&
      azapi_resource_action.gateway_token.when == "apply" &&
      length(azapi_resource_action.gateway_token.response_export_values) == 0 &&
      contains(azapi_resource_action.gateway_token.sensitive_response_export_values, "value")
    )
    error_message = "Generate the GatewayKey only during apply and mark its ARM response sensitive."
  }

  assert {
    condition = (
      azurerm_container_app.mock.ingress[0].external_enabled &&
      toset([for rule in azurerm_container_app.mock.ingress[0].ip_security_restriction : rule.ip_address_range]) == toset(["10.47.0.0/27", "10.47.0.32/27"]) &&
      alltrue([for rule in azurerm_container_app.mock.ingress[0].ip_security_restriction : rule.action == "Allow"]) &&
      !azurerm_api_management_api.mock.subscription_required &&
      azurerm_api_management_api.mock.path == "" &&
      azurerm_api_management_api_operation.get.method == "GET" &&
      azurerm_api_management_api_operation.get.url_template == "/get" &&
      azurerm_api_management_api_operation.post.method == "POST" &&
      azurerm_api_management_api_operation.post.url_template == "/post"
    )
    error_message = "Both gateways need the same subscription-free API and a VNet-visible, source-restricted mock."
  }

  assert {
    condition = (
      azurerm_private_dns_zone.apim_gateway.name == local.apim_gateway_hostname &&
      azurerm_private_dns_zone.apim_configuration.name == local.apim_configuration_hostname &&
      azurerm_private_dns_a_record.apim_gateway.records == toset(["10.47.0.4"]) &&
      azurerm_private_dns_a_record.apim_configuration.records == toset(["10.47.0.4"]) &&
      azurerm_private_dns_a_record.aca_wildcard.records == toset(["10.47.0.36"])
    )
    error_message = "Private DNS must use computed service addresses without shadowing all azure-api.net."
  }

  assert {
    condition = (
      azurerm_cdn_frontdoor_profile.lab.sku_name == "Premium_AzureFrontDoor" &&
      azurerm_cdn_frontdoor_endpoint.managed.name != azurerm_cdn_frontdoor_endpoint.self_hosted.name &&
      alltrue([for listener in azurerm_application_gateway.bridge.http_listener : listener.protocol == "Http"]) &&
      alltrue([for listener in azurerm_application_gateway.bridge.http_listener : listener.frontend_ip_configuration_name == "Gateway"]) &&
      alltrue([for backend in azurerm_application_gateway.bridge.backend_http_settings : backend.protocol == "Https" && backend.port == 443])
    )
    error_message = "Use Premium Front Door with separate paths, a private HTTP bridge listener, and HTTPS APIM backends."
  }

  assert {
    condition = (
      local.apim_nsg_rules.management.source == "ApiManagement" &&
      local.apim_nsg_rules.management.ports == ["3443"] &&
      local.apim_nsg_rules.sql.destination == "Sql" &&
      local.apim_nsg_rules.sql.ports == ["1433"] &&
      contains(local.apim_nsg_rules.monitor.ports, "1886") &&
      local.appgw_nsg_rules.private_link.source == "*" &&
      local.appgw_nsg_rules.private_link.ports == ["80"]
    )
    error_message = "Required APIM management, SQL, monitoring, and private bridge allowances must remain present."
  }

  assert {
    condition = alltrue([
      for rule in concat(
        values(azurerm_network_security_rule.apim),
        values(azurerm_network_security_rule.aca),
        values(azurerm_network_security_rule.appgw)
      ) :
      !contains(["azureplatformdns", "168.63.129.16", "168.63.129.16/32"], lower(rule.destination_address_prefix))
    ])
    error_message = "Platform DNS must remain implicit: AzurePlatformDNS Allow is invalid, and no explicit platform-DNS block or IP replacement is permitted."
  }

  assert {
    condition = alltrue([
      for rules in [
        azurerm_network_security_rule.apim,
        azurerm_network_security_rule.aca,
        azurerm_network_security_rule.appgw
      ] :
      rules["deny_other_in"].priority == 4096 &&
      rules["deny_other_in"].direction == "Inbound" &&
      rules["deny_other_in"].access == "Deny" &&
      rules["deny_other_in"].protocol == "*" &&
      rules["deny_other_in"].source_address_prefix == "*" &&
      rules["deny_other_in"].destination_address_prefix == "*" &&
      rules["deny_other_in"].source_port_range == "*" &&
      rules["deny_other_in"].destination_port_range == "*"
    ])
    error_message = "Removing invalid DNS rules must not weaken any subnet's custom inbound deny-all."
  }

  # Snapshot actual outbound rules, not the locals that generate them, so a DNS
  # workaround cannot silently add broad egress or renumber existing resources.
  assert {
    condition = {
      for key, rule in azurerm_network_security_rule.apim : key => [
        tostring(rule.priority), rule.access, rule.protocol,
        rule.source_address_prefix, rule.destination_address_prefix,
        join(",", sort(rule.destination_port_range != null ? [rule.destination_port_range] : tolist(rule.destination_port_ranges)))
      ] if rule.direction == "Outbound"
      } == {
      storage              = ["110", "Allow", "Tcp", "10.47.0.0/27", "Storage", "443"]
      sql                  = ["120", "Allow", "Tcp", "10.47.0.0/27", "Sql", "1433"]
      key_vault            = ["130", "Allow", "Tcp", "10.47.0.0/27", "AzureKeyVault", "443"]
      entra                = ["140", "Allow", "Tcp", "10.47.0.0/27", "AzureActiveDirectory", "443"]
      monitor              = ["150", "Allow", "Tcp", "10.47.0.0/27", "AzureMonitor", "1886,443"]
      event_hub            = ["160", "Allow", "Tcp", "10.47.0.0/27", "EventHub", "443,5671,5672"]
      backend              = ["170", "Allow", "Tcp", "10.47.0.0/27", "10.47.0.32/27", "443,80"]
      intra_subnet_out     = ["180", "Allow", "*", "10.47.0.0/27", "10.47.0.0/27", "*"]
      certificates_updates = ["190", "Allow", "Tcp", "10.47.0.0/27", "Internet", "443,80"]
      ntp                  = ["200", "Allow", "Udp", "10.47.0.0/27", "Internet", "123"]
      kms                  = ["210", "Allow", "Tcp", "10.47.0.0/27", "AzureCloud", "1688"]
      deny_other_out       = ["4096", "Deny", "*", "*", "*", "*"]
    }
    error_message = "APIM must retain exactly its existing custom egress and priority-4096 deny-all, minus the invalid DNS rule."
  }

  assert {
    condition = {
      for key, rule in azurerm_network_security_rule.aca : key => [
        tostring(rule.priority), rule.access, rule.protocol,
        rule.source_address_prefix, rule.destination_address_prefix,
        join(",", sort(rule.destination_port_range != null ? [rule.destination_port_range] : tolist(rule.destination_port_ranges)))
      ] if rule.direction == "Outbound"
      } == {
      mcr                = ["110", "Allow", "Tcp", "10.47.0.32/27", "MicrosoftContainerRegistry", "443"]
      mcr_cdn            = ["120", "Allow", "Tcp", "10.47.0.32/27", "AzureFrontDoor.FirstParty", "443"]
      acr                = ["130", "Allow", "Tcp", "10.47.0.32/27", "AzureContainerRegistry", "443"]
      storage            = ["140", "Allow", "Tcp", "10.47.0.32/27", "Storage", "443"]
      entra              = ["150", "Allow", "Tcp", "10.47.0.32/27", "AzureActiveDirectory", "443"]
      monitor            = ["160", "Allow", "Tcp", "10.47.0.32/27", "AzureMonitor", "443"]
      apim_configuration = ["170", "Allow", "Tcp", "10.47.0.32/27", "10.47.0.0/27", "443"]
      intra_subnet_out   = ["180", "Allow", "*", "10.47.0.32/27", "10.47.0.32/27", "*"]
      platform_https     = ["190", "Allow", "Tcp", "10.47.0.32/27", "Internet", "443,80"]
      ntp                = ["200", "Allow", "Udp", "10.47.0.32/27", "Internet", "123"]
      deny_other_out     = ["4096", "Deny", "*", "*", "*", "*"]
    }
    error_message = "ACA must retain exactly its existing custom egress and priority-4096 deny-all, minus the invalid DNS rule."
  }

  assert {
    condition = {
      for key, rule in azurerm_network_security_rule.appgw : key => [
        tostring(rule.priority), rule.access, rule.protocol,
        rule.source_address_prefix, rule.destination_address_prefix, rule.destination_port_range
      ] if rule.direction == "Outbound"
      } == {
      apim = ["110", "Allow", "Tcp", "10.47.0.64/27", "10.47.0.0/27", "443"]
    }
    error_message = "AppGW must retain its APIM rule and default infrastructure egress, without a replacement DNS rule or custom outbound deny."
  }
}

run "gateway_association_later_api_revision" {
  command = plan

  override_resource {
    target          = azurerm_api_management_api.mock
    override_during = plan
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000042/resourceGroups/rg-other/providers/Microsoft.ApiManagement/service/other-apim/apis/another-api;rev=12"
    }
  }

  assert {
    condition     = azurerm_api_management_gateway_api.mock.api_id == "/subscriptions/00000000-0000-0000-0000-000000000042/resourceGroups/rg-other/providers/Microsoft.ApiManagement/service/other-apim/apis/another-api"
    error_message = "Canonicalization must handle non-first revisions and derive the entire association ID from the API resource, not hardcoded deployment names."
  }
}

run "gateway_association_already_revisionless" {
  command = plan

  override_resource {
    target          = azurerm_api_management_api.mock
    override_during = plan
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000043/resourceGroups/rg-canonical/providers/Microsoft.ApiManagement/service/canonical-apim/apis/revisionless-api"
    }
  }

  assert {
    condition     = azurerm_api_management_gateway_api.mock.api_id == azurerm_api_management_api.mock.id
    error_message = "An already revisionless API resource ID must remain unchanged in the gateway association."
  }
}

run "custom_vnet_cidr_derives_all_subnets" {
  command = plan

  variables {
    virtual_network_cidr = "10.99.0.0/23"
  }

  assert {
    condition = (
      contains(azurerm_virtual_network.lab.address_space, "10.99.0.0/23") &&
      contains(azurerm_subnet.apim.address_prefixes, "10.99.0.0/26") &&
      contains(azurerm_subnet.aca.address_prefixes, "10.99.0.64/26") &&
      contains(azurerm_subnet.appgw.address_prefixes, "10.99.0.128/26") &&
      contains(azurerm_subnet.appgw_private_link.address_prefixes, "10.99.0.192/26")
    )
    error_message = "A custom VNet CIDR must deterministically derive four distinct in-VNet subnets."
  }
}

run "reject_too_small_vnet" {
  command = plan

  variables {
    virtual_network_cidr = "10.99.0.0/25"
  }

  expect_failures = [var.virtual_network_cidr]
}

run "reject_incompatible_appgw_network_isolation" {
  command = plan

  override_data {
    target = data.azapi_resource.appgw_network_isolation
    values = {
      output = { properties = { state = "Registered" } }
    }
  }

  expect_failures = [azurerm_application_gateway.bridge]
}

run "accept_unregistered_appgw_network_isolation" {
  command = plan

  override_data {
    target = data.azapi_resource.appgw_network_isolation
    values = {
      output = { properties = { state = "Unregistered" } }
    }
  }

  assert {
    condition = (
      alltrue([
        for rule in concat(
          values(azurerm_network_security_rule.apim),
          values(azurerm_network_security_rule.aca),
          values(azurerm_network_security_rule.appgw)
        ) :
        !contains(["azureplatformdns", "168.63.129.16", "168.63.129.16/32"], lower(rule.destination_address_prefix))
      ]) &&
      azurerm_network_security_rule.apim["deny_other_out"].access == "Deny" &&
      azurerm_network_security_rule.apim["deny_other_out"].priority == 4096 &&
      azurerm_network_security_rule.aca["deny_other_out"].access == "Deny" &&
      azurerm_network_security_rule.aca["deny_other_out"].priority == 4096 &&
      alltrue([for rule in values(azurerm_network_security_rule.appgw) : rule.access == "Allow" if rule.direction == "Outbound"])
    )
    error_message = "The supported Unregistered isolation state must also preserve implicit platform DNS and each subnet's existing egress posture."
  }
}

run "reject_registering_appgw_network_isolation" {
  command = plan

  override_data {
    target = data.azapi_resource.appgw_network_isolation
    values = {
      output = { properties = { state = "Registering" } }
    }
  }

  expect_failures = [azurerm_application_gateway.bridge]
}

run "reject_unregistering_appgw_network_isolation" {
  command = plan

  override_data {
    target = data.azapi_resource.appgw_network_isolation
    values = {
      output = { properties = { state = "Unregistering" } }
    }
  }

  expect_failures = [azurerm_application_gateway.bridge]
}

run "reject_pending_appgw_network_isolation" {
  command = plan

  override_data {
    target = data.azapi_resource.appgw_network_isolation
    values = {
      output = { properties = { state = "Pending" } }
    }
  }

  expect_failures = [azurerm_application_gateway.bridge]
}

run "reject_unknown_appgw_network_isolation_state" {
  command = plan

  override_data {
    target = data.azapi_resource.appgw_network_isolation
    values = {
      output = { properties = { state = "UnexpectedState" } }
    }
  }

  expect_failures = [azurerm_application_gateway.bridge]
}

run "reject_excessively_large_vnet" {
  command = plan

  variables {
    virtual_network_cidr = "10.0.0.0/15"
  }

  expect_failures = [var.virtual_network_cidr]
}
