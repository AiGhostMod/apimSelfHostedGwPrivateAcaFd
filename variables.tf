variable "subscription_id" {
  description = "Azure subscription where Terraform creates the complete lab, including its virtual network."
  type        = string
  default     = "87101dd8-0f2d-4b39-83ac-38aa3035a537"

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.subscription_id))
    error_message = "subscription_id must be an Azure subscription UUID."
  }
}

variable "tenant_id" {
  description = "Microsoft Entra tenant used by both Terraform providers."
  type        = string
  default     = "c7b3400e-014c-41bf-b6c1-111a3b1e933f"

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.tenant_id))
    error_message = "tenant_id must be a Microsoft Entra tenant UUID."
  }
}

variable "location" {
  description = "Azure region for the resource group, virtual network, and regional services."
  type        = string
  default     = "swedencentral"

  validation {
    condition     = length(trimspace(var.location)) > 0
    error_message = "location must not be empty."
  }
}

variable "virtual_network_cidr" {
  description = "IPv4 CIDR for the Terraform-owned VNet. Terraform derives four equal subnets from it; use a /16 through /24."
  type        = string
  default     = "10.47.0.0/24"

  validation {
    condition = (
      can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}/", var.virtual_network_cidr)) &&
      can(cidrsubnet(var.virtual_network_cidr, 3, 3)) &&
      try(tonumber(split("/", var.virtual_network_cidr)[1]), 33) >= 16 &&
      try(tonumber(split("/", var.virtual_network_cidr)[1]), 33) <= 24
    )
    error_message = "virtual_network_cidr must be a valid IPv4 /16 through /24 so each derived subnet is at least /27."
  }
}

variable "name_prefix" {
  description = "Short lowercase prefix; Terraform adds a stable random suffix."
  type        = string
  default     = "apimshglab"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{2,11}$", var.name_prefix))
    error_message = "Use 3-12 lowercase alphanumeric characters, starting with a letter."
  }
}

variable "publisher_name" {
  description = "APIM publisher display name."
  type        = string
  default     = "APIM self-hosted lab"

  validation {
    condition     = length(trimspace(var.publisher_name)) > 0
    error_message = "publisher_name must not be empty."
  }
}

variable "publisher_email" {
  description = "Real operational email address for APIM service notifications."
  type        = string

  validation {
    condition     = can(regex("^[^[:space:]@]+@[^[:space:]@]+\\.[^[:space:]@]+$", var.publisher_email))
    error_message = "Set publisher_email to a valid operational email address."
  }
}

variable "tags" {
  description = "Additional tags for newly created workload resources."
  type        = map(string)
  default     = {}
}
