resource "azurerm_kubernetes_cluster" "main" {
  name                = var.cluster_name
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_prefix          = var.cluster_name
  kubernetes_version  = var.kubernetes_version
  tags                = var.tags

  # System node pool — always on, runs system pods
  # 1 node is sufficient for learning (not HA, but saves ~$60/month)
  default_node_pool {
    name                         = "system"
    node_count                   = 1
    vm_size                      = var.node_vm_size_system
    vnet_subnet_id               = var.subnet_id
    os_disk_size_gb              = 64 # Reduced from 128 — saves on managed disk cost
    type                         = "VirtualMachineScaleSets"
    only_critical_addons_enabled = true # Taint: only system pods here
    upgrade_settings {
      max_surge = "10%"
    }
  }

  # Use SystemAssigned managed identity
  identity {
    type = "SystemAssigned"
  }

  # Enable OIDC issuer for Workload Identity
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  # Network config
  # VNet: 10.0.0.0/16, AKS subnet: 10.0.0.0/22
  # Service CIDR must not overlap with any subnet — use a separate range
  network_profile {
    network_plugin    = "azure"
    network_policy    = "azure"
    load_balancer_sku = "standard"
    outbound_type     = "loadBalancer"
    service_cidr      = "10.1.0.0/16"
    dns_service_ip    = "10.1.0.10"
  }

  # Azure AD RBAC — simplified in azurerm 4.x
  azure_active_directory_role_based_access_control {
    tenant_id          = var.tenant_id
    azure_rbac_enabled = true
  }

  lifecycle {
    ignore_changes = [
      default_node_pool[0].node_count, # Allow autoscaler to manage
    ]
  }
}

# App node pool — runs your workloads
resource "azurerm_kubernetes_cluster_node_pool" "app" {
  name                  = "app"
  temporary_name_for_rotation = "approt"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.main.id
  vm_size               = var.node_vm_size_app
  max_pods              = var.node_pool_max_pods_app
  vnet_subnet_id        = var.subnet_id
  #   os_disk_size_gb       = 128
  mode = "User"

  # Autoscaling profile for sandbox workloads
  # Note: azurerm 4.x renamed enable_auto_scaling → auto_scaling_enabled
  auto_scaling_enabled = true
  min_count            = 2
  max_count            = 4
  node_count           = 2
  os_disk_size_gb      = 64 # Reduced from 128

  node_labels = {
    "workload-type" = "app"
  }

  upgrade_settings {
    max_surge = "10%"
  }

  tags = var.tags

  lifecycle {
    ignore_changes = [
      node_count, # Allow cluster autoscaler to manage live node count
    ]
  }
}

# Grant AKS managed identity permission to pull from ACR
resource "azurerm_role_assignment" "aks_acr_pull" {
  principal_id                     = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
  role_definition_name             = "AcrPull"
  scope                            = var.acr_id
  skip_service_principal_aad_check = true
}