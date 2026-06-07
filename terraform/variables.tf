variable "subscription_id" {
  type        = string
  description = "Azure Subscription ID (required by azurerm 4.x provider)"
}

variable "location" {
  type        = string
  default     = "swedencentral" # Region where rg-devops-aks was created in Section 2
  description = "Azure region for all resources"
}

variable "resource_group_name" {
  type        = string
  default     = "rg-devops-aks"
  description = "Name of the Azure Resource Group"
}

variable "cluster_name" {
  type        = string
  default     = "aks-devops-project"
  description = "AKS cluster name"
}

variable "kubernetes_version" {
  type        = string
  default     = "1.35.3"
  description = "AKS Kubernetes version"
}

variable "acr_name" {
  type        = string
  default     = "acrdevopsprojectd1e51ba4" # ACR name created in Section 2 (globally unique suffix)
  description = "Azure Container Registry name (must be globally unique)"
}

variable "node_vm_size_system" {
  type        = string
  default     = "Standard_B2ms" # Burstable — cheaper for learning; upgrade to D2s_v5 for prod
  description = "VM size for system node pool"
}

variable "node_vm_size_app" {
  type        = string
  default     = "Standard_D2s_v5" # General purpose — stable performance and better regional availability
  description = "VM size for app node pool"
}

variable "node_pool_max_pods_app" {
  type        = number
  default     = 40
  description = "Maximum pods per node for the AKS app node pool"
}

variable "tags" {
  type = map(string)
  default = {
    project     = "devops-aks-project"
    environment = "learning"
    managed_by  = "terraform"
  }
}