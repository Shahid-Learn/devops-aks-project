terraform {
  backend "azurerm" {
    resource_group_name  = "rg-devops-aks"
    storage_account_name = "stterraformaks93cdfbee"
    container_name       = "tfstate"
    key                  = "aks-project.tfstate"
  }
}
