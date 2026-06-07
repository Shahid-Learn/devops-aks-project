# Section 3 — Terraform AKS Infrastructure

> Provision the complete Azure infrastructure using Terraform: networking, AKS cluster, ACR, and Key Vault. Terraform state is stored in Azure Blob Storage.

---

## 3.1 What We Will Build

```
Azure Resource Group: rg-devops-aks
│
├── Virtual Network (VNet)
│   ├── AKS Subnet (10.0.0.0/22)
│   └── (Reserved for future use)
│
├── AKS Cluster
│   ├── System node pool (Standard_B2ms × 1)   ← cost-optimised for learning
│   ├── App node pool   (Standard_D2s_v5 × 2–4, autoscale)
│   ├── OIDC Issuer enabled
│   ├── Workload Identity enabled
│   └── Managed Identity (for ACR pull)
│
├── Azure Container Registry (ACR)
│   └── Attached to AKS (no imagePullSecrets needed)
│
└── Azure Key Vault
    └── Stores app secrets (DB passwords, API keys)
```

---

## 3.2 Terraform Project Structure

```
terraform/
├── providers.tf       ← Azure provider + backend config
├── variables.tf       ← Input variables
├── main.tf            ← Calls modules
├── outputs.tf         ← Cluster name, ACR URL, etc.
└── modules/
    ├── networking/    ← VNet + Subnets
    ├── acr/           ← Azure Container Registry
    ├── aks/           ← AKS cluster
    └── keyvault/      ← Azure Key Vault
```

---

## 3.3 Terraform Files

### `terraform/providers.tf`

```hcl
terraform {
  required_version = ">= 1.15.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"   # Allows all 4.x updates, not 5.x
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy    = true
      recover_soft_deleted_key_vaults = true
    }
  }
  subscription_id = var.subscription_id  # Required in azurerm 4.x
}

provider "azuread" {}
```

### `terraform/backend.tf`

> Separated from `providers.tf` so the backend config is easy to find and modify independently.

```hcl
terraform {
  backend "azurerm" {
    resource_group_name  = "rg-devops-aks"
    storage_account_name = "<your-storage-account>"  # from Section 2
    container_name       = "tfstate"
    key                  = "aks-project.tfstate"
  }
}
```

### `terraform/variables.tf`

```hcl
variable "subscription_id" {
  type        = string
  description = "Azure Subscription ID (required by azurerm 4.x provider)"
}

variable "location" {
  type        = string
  default     = "swedencentral"   # Region where rg-devops-aks was created in Section 2
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
  default     = "1.30"
  description = "AKS Kubernetes version"
}

variable "acr_name" {
  type        = string
  default     = "acrdevopsprojectd1e51ba4"   # ACR name created in Section 2 (globally unique suffix)
  description = "Azure Container Registry name (must be globally unique)"
}

variable "node_vm_size_system" {
  type        = string
  default     = "Standard_B2ms"   # Burstable — cheaper for learning; upgrade to D2s_v5 for prod
  description = "VM size for system node pool"
}

variable "node_vm_size_app" {
  type        = string
  default     = "Standard_D2s_v5" # General purpose — stable performance and better regional availability
  description = "VM size for app node pool"
}

variable "tags" {
  type = map(string)
  default = {
    project     = "devops-aks-project"
    environment = "learning"
    managed_by  = "terraform"
  }
}
```

### `terraform/main.tf`

```hcl
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
  subnet_id           = module.networking.aks_subnet_id
  acr_id              = module.acr.acr_id
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
```

### `terraform/outputs.tf`

```hcl
output "aks_cluster_name" {
  value = module.aks.cluster_name
}

output "aks_cluster_endpoint" {
  value     = module.aks.kube_config.0.host
  sensitive = true
}

output "acr_login_server" {
  value = module.acr.login_server
}

output "oidc_issuer_url" {
  value = module.aks.oidc_issuer_url
}

output "keyvault_uri" {
  value = module.keyvault.vault_uri
}

output "get_credentials_command" {
  value = "az aks get-credentials --resource-group ${var.resource_group_name} --name ${module.aks.cluster_name} --overwrite-existing"
}
```

---

## 3.4 Networking Module

### `terraform/modules/networking/main.tf`

```hcl
resource "azurerm_virtual_network" "main" {
  name                = "vnet-${var.cluster_name}"
  address_space       = ["10.0.0.0/16"]
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_subnet" "aks" {
  name                 = "snet-aks"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.0.0/22"]
}
```

### `terraform/modules/networking/outputs.tf`

```hcl
output "aks_subnet_id" {
  value = azurerm_subnet.aks.id
}
```

### `terraform/modules/networking/variables.tf`

```hcl
variable "location"            { type = string }
variable "resource_group_name" { type = string }
variable "cluster_name"        { type = string  default = "aks-devops-project" }
variable "tags"                { type = map(string) default = {} }
```

---

## 3.5 ACR Module

### `terraform/modules/acr/main.tf`

```hcl
resource "azurerm_container_registry" "main" {
  name                = var.acr_name
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "Basic"
  admin_enabled       = false    # Use managed identity, not admin creds
  tags                = var.tags
}
```

### `terraform/modules/acr/outputs.tf`

```hcl
output "acr_id" {
  value = azurerm_container_registry.main.id
}

output "login_server" {
  value = azurerm_container_registry.main.login_server
}
```

### `terraform/modules/acr/variables.tf`

```hcl
variable "location"            { type = string }
variable "resource_group_name" { type = string }
variable "acr_name"            { type = string }
variable "tags"                { type = map(string) default = {} }
```

---

## 3.6 AKS Module

### `terraform/modules/aks/main.tf`

```hcl
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
    name                = "system"
    node_count          = 1
    vm_size             = var.node_vm_size_system
    vnet_subnet_id      = var.subnet_id
    os_disk_size_gb     = 64    # Reduced from 128 — saves on managed disk cost
    type                = "VirtualMachineScaleSets"
    only_critical_addons_enabled = true  # Taint: only system pods here
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
      default_node_pool[0].node_count,  # Allow autoscaler to manage
    ]
  }
}

# App node pool — runs your workloads
resource "azurerm_kubernetes_cluster_node_pool" "app" {
  name                  = "app"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.main.id
  vm_size               = var.node_vm_size_app
  vnet_subnet_id        = var.subnet_id
  os_disk_size_gb       = 128
  mode                  = "User"

  # Autoscaling profile for sandbox workloads
  # Note: azurerm 4.x renamed enable_auto_scaling → auto_scaling_enabled
  auto_scaling_enabled = true
  min_count            = 2
  max_count            = 4
  node_count           = 2
  os_disk_size_gb      = 64   # Reduced from 128

  node_labels = {
    "workload-type" = "app"
  }

  tags = var.tags
}

  > **Pod Density Note (AKS):**
  > - The per-node pod limit is controlled by node pool `maxPods` (kubelet setting).
  > - A node can hit `Too many pods` even when CPU/memory still looks available.
  > - In this project, app nodes showed allocatable `30` pods per node.
  >
  > Check current value:
  >
  > ```bash
  > az aks nodepool show \
  >   --resource-group rg-devops-aks \
  >   --cluster-name aks-devops-project \
  >   --name app \
  >   --query maxPods -o tsv
  > ```
  >
  > If needed, update with subnet/IP planning in mind (Azure CNI assigns pod IPs):
  >
  > ```bash
  > az aks nodepool update \
  >   --resource-group rg-devops-aks \
  >   --cluster-name aks-devops-project \
  >   --name app \
  >   --max-pods 50
  > ```

# Grant AKS managed identity permission to pull from ACR
resource "azurerm_role_assignment" "aks_acr_pull" {
  principal_id                     = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
  role_definition_name             = "AcrPull"
  scope                            = var.acr_id
  skip_service_principal_aad_check = true
}
```

### `terraform/modules/aks/outputs.tf`

```hcl
output "cluster_name" {
  value = azurerm_kubernetes_cluster.main.name
}

output "kube_config" {
  value     = azurerm_kubernetes_cluster.main.kube_config
  sensitive = true
}

output "oidc_issuer_url" {
  value = azurerm_kubernetes_cluster.main.oidc_issuer_url
}

output "kubelet_identity_object_id" {
  value = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
}
```

### `terraform/modules/aks/variables.tf`

```hcl
variable "location"            { type = string }
variable "resource_group_name" { type = string }
variable "cluster_name"        { type = string }
variable "kubernetes_version"  { type = string }
variable "node_vm_size_system" { type = string }
variable "node_vm_size_app"    { type = string }
variable "subnet_id"           { type = string }
variable "acr_id"              { type = string }
variable "tags"                { type = map(string) default = {} }
```

---

## 3.7 Key Vault Module

### `terraform/modules/keyvault/main.tf`

```hcl
resource "azurerm_key_vault" "main" {
  name                       = "kv-devops-aks-${substr(md5(var.cluster_name), 0, 6)}"
  location                   = var.location
  resource_group_name        = var.resource_group_name
  tenant_id                  = var.tenant_id
  sku_name                   = "standard"
  purge_protection_enabled   = false  # Set true for production
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
```

### `terraform/modules/keyvault/outputs.tf`

```hcl
output "vault_uri" {
  value = azurerm_key_vault.main.vault_uri
}

output "vault_name" {
  value = azurerm_key_vault.main.name
}
```

### `terraform/modules/keyvault/variables.tf`

```hcl
variable "location"            { type = string }
variable "resource_group_name" { type = string }
variable "cluster_name"        { type = string }
variable "tenant_id"           { type = string }
variable "aks_oidc_issuer_url" { type = string }
variable "tags"                { type = map(string) default = {} }
```

---

## 3.8 Running Terraform Locally

```bash
cd terraform/

# Initialize (connects to Azure storage backend)
terraform init \
  -backend-config="resource_group_name=rg-devops-aks" \
  -backend-config="storage_account_name=<your-storage-account>" \
  -backend-config="container_name=tfstate" \
  -backend-config="key=aks-project.tfstate"

# Format and validate
terraform fmt -recursive
terraform validate

# Plan — review before applying
terraform plan -out=tfplan

# Apply
terraform apply tfplan

# Get outputs
terraform output
terraform output get_credentials_command
```

---

## 3.9 Connect kubectl to AKS

```bash
# Get credentials — newer az CLI versions auto-convert kubeconfig (no need to run kubelogin separately)
az aks get-credentials \
  --resource-group rg-devops-aks \
  --name aks-devops-project \
  --overwrite-existing

# If kubeconfig was NOT auto-converted (older az CLI), run this:
# kubelogin convert-kubeconfig -l azurecli

# Grant your user cluster admin access (azure_rbac_enabled=true requires explicit Azure RBAC)
AKS_ID=$(az aks show --resource-group rg-devops-aks --name aks-devops-project --query id -o tsv | tr -d '\r')

USER_OBJECT_ID=$(az ad signed-in-user show --query id -o tsv | tr -d '\r')

az role assignment create \
  --assignee-object-id "$USER_OBJECT_ID" \
  --assignee-principal-type User \
  --role "Azure Kubernetes Service RBAC Cluster Admin" \
  --scope "$AKS_ID"

# Verify connection
kubectl get nodes
kubectl get nodes -o wide

# Check node pools
kubectl get nodes --show-labels | grep workload-type
```

---

## 3.10 Cost Estimates

### Learning Setup (what we use)

| Resource | SKU | Approx. Monthly Cost |
|---------|-----|---------------------|
| AKS System pool (1× B2ms) | Standard_B2ms | ~$60 |
| AKS App pool (2–4× D2s_v5) | Standard_D2s_v5 | ~$60–$120 |
| ACR | Basic | ~$5 |
| Load Balancer | Standard | ~$18 |
| Storage (TF state) | LRS | ~$1 |
| Key Vault | Standard | ~$4 |
| **Total (min app pool size = 2)** | | **~$148/month** |
| **Total (max app pool size = 4)** | | **~$208/month** |

### If upgrading to higher-capacity D-series

| Resource | SKU | Approx. Monthly Cost |
|---------|-----|---------------------|
| AKS System pool (2× D2s_v5) | Standard_D2s_v5 | ~$120 |
| AKS App pool (1–3× D4s_v5) | Standard_D4s_v5 | ~$120–$360 |
| **Total (min)** | | **~$240/month** |

> **Cost Saving Tips:**
> - Keep autoscaler at min 2 / max 4 during active learning to avoid scheduling bottlenecks
> - D-series gives predictable CPU and avoids dependency on BS-family quota approvals
> - Delete cluster entirely when not using for >1 week (`terraform destroy` then `terraform apply` to recreate in ~10 min)

```bash
# ── SCALE DOWN (end of session) ──────────────────────────────────────────────
# Autoscaler must be disabled before manual scaling to 0
az aks nodepool update \
  --resource-group rg-devops-aks \
  --cluster-name aks-devops-project \
  --name app \
  --disable-cluster-autoscaler

az aks nodepool scale \
  --resource-group rg-devops-aks \
  --cluster-name aks-devops-project \
  --name app --node-count 0

# ── SCALE BACK UP (start of session) ─────────────────────────────────────────
az aks nodepool scale \
  --resource-group rg-devops-aks \
  --cluster-name aks-devops-project \
  --name app --node-count 1

# Re-enable autoscaler after scaling back up
az aks nodepool update \
  --resource-group rg-devops-aks \
  --cluster-name aks-devops-project \
  --name app \
  --enable-cluster-autoscaler \
  --min-count 1 \
  --max-count 2
```

> **Note:** `az aks nodepool scale` fails with "Cannot scale cluster autoscaler enabled node pool" if autoscaler is active.
> Always disable autoscaler first, scale, then re-enable. This is a known AKS limitation.

---

## Summary Checklist

- [x] Terraform backend configured (Azure Blob Storage)
- [x] Networking module (VNet + Subnets)
- [x] ACR module (container registry)
- [x] AKS module (cluster + app node pool + autoscaler)
- [x] Key Vault module
- [x] AKS-to-ACR role assignment (no imagePullSecrets needed)
- [x] OIDC issuer + Workload Identity enabled on AKS
- [x] kubectl connected to AKS

**Next:** [04 — Containerization](04-containerization.md)
