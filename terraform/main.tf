data "azurerm_client_config" "current" {}

# Reference the existing resource group (created manually in Section 2)
data "azurerm_resource_group" "main" {
  name = var.resource_group_name
}

module "networking" {
  source              = "./modules/networking"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

module "acr" {
  source              = "./modules/acr"
  location            = var.location
  resource_group_name = var.resource_group_name
  acr_name            = var.acr_name
  tags                = var.tags
}

module "aks" {
  source              = "./modules/aks"
  location            = var.location
  resource_group_name = var.resource_group_name
  cluster_name        = var.cluster_name
  kubernetes_version  = var.kubernetes_version
  node_vm_size_system = var.node_vm_size_system
  node_vm_size_app    = var.node_vm_size_app
  node_pool_max_pods_app = var.node_pool_max_pods_app
  subnet_id           = module.networking.aks_subnet_id
  acr_id              = module.acr.acr_id
  tenant_id           = data.azurerm_client_config.current.tenant_id
  tags                = var.tags
}

module "keyvault" {
  source              = "./modules/keyvault"
  location            = var.location
  resource_group_name = var.resource_group_name
  cluster_name        = var.cluster_name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  aks_oidc_issuer_url = module.aks.oidc_issuer_url
  tags                = var.tags
}
