# Need to have "RoleManagement.ReadWrite.Director" or "Directory.ReadWrite.All" 
# (https://registry.terraform.io/providers/hashicorp/azuread/latest/docs/resources/directory_role_assignment)

terraform {
  # backend "azurerm" {}
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "=3.19.1"
    }
  }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy = true
    }
  }
}

variable "environment" {
  type = string
  default = "stg"
}

data "azurerm_client_config" "current" {}

locals {
  app = "aadpodidentitydemo"
}

resource "azurerm_resource_group" "infra" {
  name     = "rg-infra-${local.app}-${var.environment}"
  location = "eastus2"
}

# AKS
resource "azurerm_kubernetes_cluster" "infra" {
  name                = "aks-${local.app}-${var.environment}"
  location            = azurerm_resource_group.infra.location
  resource_group_name = azurerm_resource_group.infra.name
  dns_prefix          = "aks${local.app}${var.environment}"

  default_node_pool {
    name       = "default"
    node_count = 3
    vm_size    = "Standard_B2s" # x3 = ~$100
  }

  identity {
    type = "UserAssigned"
    identity_ids = [
        azurerm_user_assigned_identity.svc.id
    ]
  }
}

resource "azurerm_resource_group" "svc" {
  name     = "rg-svc-${local.app}-${var.environment}"
  location = "eastus2"
}

# Storage
resource "azurerm_storage_account" "svc" {
  name                     = "sa${local.app}${var.environment}"
  resource_group_name      = azurerm_resource_group.svc.name
  location                 = azurerm_resource_group.svc.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

# User Assigned Identity
resource "azurerm_user_assigned_identity" "svc" {
  location            = azurerm_resource_group.svc.location
  resource_group_name = azurerm_resource_group.svc.name

  name = "svc-managed-identity"
}

##################
# THE GOOD STUFF #
##################

# Get resource id of the node resource group (MG_...)
data "azurerm_resource_group" "node_resource_group" {
  name = azurerm_kubernetes_cluster.infra.node_resource_group
}

# AAD Pod Identity Role Assignments
resource "azurerm_role_assignment" "managed_id_operator_to_node_rg" {
  scope                = data.azurerm_resource_group.node_resource_group.id
  role_definition_name = "Managed Identity Operator"
  principal_id         = azurerm_kubernetes_cluster.infra.kubelet_identity[0].object_id
}

resource "azurerm_role_assignment" "vm_contributor_to_node_rg" {
  scope                = data.azurerm_resource_group.node_resource_group.id
  role_definition_name = "Virtual Machine Contributor"
  principal_id         = azurerm_kubernetes_cluster.infra.kubelet_identity[0].object_id
}

resource "azurerm_role_assignment" "managed_id_operator_to_svc_rg" {
  scope                = azurerm_resource_group.svc.id
  role_definition_name = "Managed Identity Operator"
  principal_id         = azurerm_kubernetes_cluster.infra.kubelet_identity[0].object_id
}

# Print Outputs
output "aks_kubelet_identity_object_id" {
  value = azurerm_kubernetes_cluster.infra.kubelet_identity[0].object_id
}

output "aks_node_rg_id" {
  value = data.azurerm_resource_group.node_resource_group.id
}