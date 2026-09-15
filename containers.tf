variable "acr_role_propagation_wait" {
  description = "Wait after AcrPull assignment before deploying apps; increase if Azure RBAC propagation is slow."
  type        = string
  default     = "180s"
  validation {
    condition     = can(regex("^[1-9][0-9]*(s|m)$", var.acr_role_propagation_wait))
    error_message = "Use a positive duration in seconds or minutes, such as 180s or 5m."
  }
}

locals {
  mock_build_files = sort(concat(
    ["Dockerfile", "requirements.txt", ".dockerignore"],
    [
      for name in fileset("${path.module}/mock-api", "app/**") : name
      if !strcontains(name, "/__pycache__/") && !endswith(name, ".pyc")
    ]
  ))
  mock_image_hash = sha256(jsonencode({
    for name in local.mock_build_files : name => filesha256("${path.module}/mock-api/${name}")
  }))
  mock_image = "${azurerm_container_registry.acr.login_server}/mock-api:${local.mock_image_hash}"
}

resource "azurerm_log_analytics_workspace" "aca" {
  name                = "${local.name_prefix}-logs"
  location            = var.location
  resource_group_name = azurerm_resource_group.lab.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.tags
}

resource "azurerm_container_app_environment" "aca" {
  name                           = "${local.name_prefix}-aca"
  location                       = var.location
  resource_group_name            = azurerm_resource_group.lab.name
  infrastructure_subnet_id       = azurerm_subnet.aca.id
  internal_load_balancer_enabled = true
  public_network_access          = "Disabled"
  logs_destination               = "log-analytics"
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.aca.id
  tags                           = local.tags

  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }

  depends_on = [
    azurerm_subnet_network_security_group_association.aca,
    azurerm_subnet_nat_gateway_association.aca,
    azurerm_nat_gateway_public_ip_association.aca,
  ]
}

resource "azurerm_container_registry" "acr" {
  name                = "${replace(local.name_prefix, "-", "")}acr"
  resource_group_name = azurerm_resource_group.lab.name
  location            = var.location
  sku                 = "Basic"
  admin_enabled       = false
  tags                = local.tags
}

resource "azurerm_user_assigned_identity" "acr_pull" {
  name                = "${local.name_prefix}-acr-pull"
  location            = var.location
  resource_group_name = azurerm_resource_group.lab.name
  tags                = local.tags
}

resource "azurerm_role_assignment" "acr_pull" {
  scope                            = azurerm_container_registry.acr.id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_user_assigned_identity.acr_pull.principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

resource "time_sleep" "acr_pull" {
  create_duration = var.acr_role_propagation_wait
  triggers = {
    assignment_id = azurerm_role_assignment.acr_pull.id
    principal_id  = azurerm_user_assigned_identity.acr_pull.principal_id
    wait          = var.acr_role_propagation_wait
  }
}

resource "terraform_data" "mock_image" {
  triggers_replace = {
    registry_id = azurerm_container_registry.acr.id
    content     = local.mock_image_hash
    builder     = filesha256("${path.module}/scripts/build-image.sh")
  }

  provisioner "local-exec" {
    command     = "bash scripts/build-image.sh"
    working_dir = path.module
    environment = {
      AZURE_SUBSCRIPTION_ID = var.subscription_id
      ACR_NAME              = azurerm_container_registry.acr.name
      IMAGE_TAG             = local.mock_image_hash
    }
  }
}

resource "azurerm_container_app" "mock" {
  name                         = "${local.name_prefix}-mock"
  container_app_environment_id = azurerm_container_app_environment.aca.id
  resource_group_name          = azurerm_resource_group.lab.name
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"
  tags                         = local.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.acr_pull.id]
  }

  registry {
    server   = azurerm_container_registry.acr.login_server
    identity = azurerm_user_assigned_identity.acr_pull.id
  }

  # "External" publishes at the INTERNAL environment's private load balancer,
  # not the internet. false would make managed APIM in another subnet get 404.
  ingress {
    external_enabled           = true
    allow_insecure_connections = false
    target_port                = 8080
    transport                  = "http"
    ip_security_restriction {
      name             = "managed-apim"
      description      = "Managed APIM gateway in the existing dedicated subnet."
      action           = "Allow"
      ip_address_range = local.apim_subnet_cidr
    }
    ip_security_restriction {
      name             = "self-hosted-apim"
      description      = "Self-hosted gateway in this ACA environment."
      action           = "Allow"
      ip_address_range = local.aca_subnet_cidr
    }
    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = 1
    max_replicas = 1
    container {
      name   = "mock-api"
      image  = local.mock_image
      cpu    = 0.25
      memory = "0.5Gi"

      readiness_probe {
        transport               = "HTTP"
        port                    = 8080
        path                    = "/health"
        interval_seconds        = 10
        success_count_threshold = 1
      }
      liveness_probe {
        transport        = "HTTP"
        port             = 8080
        path             = "/health"
        initial_delay    = 10
        interval_seconds = 30
      }
    }
  }

  depends_on = [terraform_data.mock_image, time_sleep.acr_pull]
}
