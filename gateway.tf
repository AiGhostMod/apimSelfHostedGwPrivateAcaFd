variable "gateway_token_rotation_id" {
  type        = string
  default     = "initial"
  description = "Change and apply at least every 29 days to issue a new 30-day GatewayKey token and roll the gateway revision. Keep the chosen value stable between rotations."

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$", var.gateway_token_rotation_id))
    error_message = "Use 1-64 letters, digits, underscores or hyphens, starting with a letter or digit."
  }
}

# Start the validity window only after the slow APIM and mock provisioning.
# No timestamp() expression: ordinary plans must not regenerate credentials.
resource "time_static" "gateway_token" {
  triggers = {
    rotation_id = var.gateway_token_rotation_id
    gateway_id  = azurerm_api_management_gateway.self_hosted.id
  }

  depends_on = [
    azurerm_api_management_gateway_api.mock,
    azurerm_private_dns_a_record.apim_configuration,
    azurerm_private_dns_zone_virtual_network_link.apim_configuration,
  ]

  lifecycle {
    replace_triggered_by = [azurerm_api_management_gateway.self_hosted]
  }
}

# The stable Generate Token API caps expiry at 30 days.
# https://learn.microsoft.com/rest/api/apimanagement/gateway/generate-token?view=rest-apimanagement-2024-05-01
# Secrets remain in Terraform state: protect state and never enable TF_LOG.
resource "azapi_resource_action" "gateway_token" {
  type        = "Microsoft.ApiManagement/service/gateways@2024-05-01"
  resource_id = azurerm_api_management_gateway.self_hosted.id
  action      = "generateToken"
  method      = "POST"
  when        = "apply"

  body = {
    keyType = "primary"
    expiry  = timeadd(time_static.gateway_token.rfc3339, "720h")
  }

  response_export_values           = []
  sensitive_response_export_values = ["value"]
}

resource "azurerm_container_app" "gateway" {
  name                         = "${local.name_prefix}-gateway"
  resource_group_name          = azurerm_resource_group.lab.name
  container_app_environment_id = azurerm_container_app_environment.aca.id
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"
  tags                         = local.tags

  secret {
    name  = "gateway-token"
    value = sensitive("GatewayKey ${azapi_resource_action.gateway_token.sensitive_output.value}")
  }

  ingress {
    external_enabled           = true
    allow_insecure_connections = false
    target_port                = 8080
    transport                  = "http"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = 1
    max_replicas = 1

    container {
      name   = "gateway"
      image  = "mcr.microsoft.com/azure-api-management/gateway:v2"
      cpu    = 1
      memory = "2Gi"

      env {
        name  = "config.service.endpoint"
        value = "https://${local.apim_configuration_hostname}"
      }

      env {
        name        = "config.service.auth"
        secret_name = "gateway-token"
      }

      # Secret changes alone don't restart existing ACA revisions. A nonsecret
      # issuance marker changes the revision whenever a fresh token is issued.
      env {
        name  = "GATEWAY_TOKEN_ISSUED_AT"
        value = time_static.gateway_token.rfc3339
      }

      # Official v2 Helm probes use this HTTP endpoint on port 8080.
      # https://github.com/Azure/api-management-self-hosted-gateway/blob/main/helm-charts/azure-api-management-gateway/values.yaml
      startup_probe {
        transport               = "HTTP"
        port                    = 8080
        path                    = "/status-0123456789abcdef"
        interval_seconds        = 10
        timeout                 = 5
        failure_count_threshold = 60
      }

      readiness_probe {
        transport               = "HTTP"
        port                    = 8080
        path                    = "/status-0123456789abcdef"
        interval_seconds        = 10
        timeout                 = 5
        success_count_threshold = 1
        failure_count_threshold = 3
      }

      liveness_probe {
        transport               = "HTTP"
        port                    = 8080
        path                    = "/status-0123456789abcdef"
        interval_seconds        = 30
        timeout                 = 5
        failure_count_threshold = 3
      }
    }
  }

  depends_on = [
    azurerm_api_management_gateway_api.mock,
    azurerm_container_app.mock,
    azurerm_container_registry.acr,
    azurerm_private_dns_a_record.apim_gateway,
    azurerm_private_dns_a_record.apim_configuration,
    azurerm_private_dns_a_record.aca_wildcard,
    azurerm_private_dns_a_record.aca_apex,
    azurerm_private_dns_zone_virtual_network_link.apim_gateway,
    azurerm_private_dns_zone_virtual_network_link.apim_configuration,
    azurerm_private_dns_zone_virtual_network_link.aca,
  ]
}
