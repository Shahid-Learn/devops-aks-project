resource "azurerm_key_vault" "main" {
  name                       = "kv-devops-aks-${substr(md5(var.cluster_name), 0, 6)}"
  location                   = var.location
  resource_group_name        = var.resource_group_name
  tenant_id                  = var.tenant_id
  sku_name                   = "standard"
  purge_protection_enabled   = false # Set true for production
  soft_delete_retention_days = 7
  tags                       = var.tags

  # Allow GitHub Actions SP to manage secrets
  access_policy {
    tenant_id = var.tenant_id
    object_id = data.azurerm_client_config.current.object_id

    secret_permissions = ["Get", "List", "Set", "Delete", "Purge"]
  }
}

data "azurerm_client_config" "current" {}