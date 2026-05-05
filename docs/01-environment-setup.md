# Section 1 — Environment Setup

> Install and configure all local tools needed for the project on a Windows machine (WSL2 recommended).

---

## 1.1 Prerequisites Overview

| Tool | Purpose | Install Method |
|------|---------|---------------|
| WSL2 + Ubuntu | Linux environment on Windows | Windows feature |
| Azure CLI | Manage Azure resources | winget / apt |
| Terraform | Infrastructure as Code | tfenv / apt |
| kubectl | Kubernetes CLI | az aks install-cli |
| Helm | K8s package manager | apt / script |
| Docker Desktop | Local container builds | winget |
| Git | Version control | winget |
| GitHub CLI (`gh`) | GitHub automation | winget / apt |
| VS Code | Editor | winget |
| kubelogin | AKS AAD authentication | GitHub release |

---

## 1.2 WSL2 Setup (Windows)

```powershell
# Run in PowerShell as Administrator
wsl --install
wsl --set-default-version 2
wsl --install -d Ubuntu-22.04
```

After install, open Ubuntu from Start Menu and set a username/password.

```bash
# Inside WSL — update packages
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl wget unzip git jq
```

---

## 1.3 Azure CLI

```bash
# Install in WSL Ubuntu
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# Verify
az version

# Login with your official Azure account
az login
# A browser will open — sign in with your official Azure credentials

# Set the subscription you want to use
az account list --output table
az account set --subscription "<your-subscription-id>"
az account show
```

> **Note:** You will be using your **official Azure account** for all `az` commands. Your personal GitHub account handles the code repository only.

---

## 1.4 Terraform

```bash
# Install tfenv (Terraform version manager — best practice)
git clone --depth=1 https://github.com/tfutils/tfenv.git ~/.tfenv
echo 'export PATH="$HOME/.tfenv/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc

# Install latest stable Terraform
tfenv install 1.9.8
tfenv use 1.9.8

# Verify
terraform version
```

---

## 1.5 kubectl

```bash
# Install via Azure CLI (keeps version aligned with AKS)
sudo az aks install-cli

# Or install directly
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# Verify
kubectl version --client
```

---

## 1.6 Helm

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Verify
helm version

# Add commonly used repos
helm repo add stable https://charts.helm.sh/stable
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update
```

---

## 1.7 Docker Desktop (Windows)

1. Download from https://www.docker.com/products/docker-desktop/
2. Install and enable WSL2 backend in settings
3. Enable "Use the WSL 2 based engine"
4. Restart Docker Desktop

```bash
# Verify inside WSL
docker version
docker run hello-world
```

---

## 1.8 GitHub CLI

```bash
# Install gh CLI
type -p curl >/dev/null || sudo apt install curl -y
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
sudo apt update && sudo apt install gh -y

# Login with your personal GitHub account
gh auth login
# Choose: GitHub.com → HTTPS → Login with web browser
```

---

## 1.9 kubelogin (for AKS AAD authentication)

```bash
# Download latest release
curl -LO https://github.com/Azure/kubelogin/releases/latest/download/kubelogin-linux-amd64.zip
unzip kubelogin-linux-amd64.zip
sudo mv bin/linux_amd64/kubelogin /usr/local/bin/

# Verify
kubelogin --version
```

---

## 1.10 Configure Git

```bash
git config --global user.name "Your Name"
git config --global user.email "your-personal-email@example.com"
git config --global init.defaultBranch main
git config --global core.editor "code --wait"

# Verify
git config --list
```

---

## 1.11 Environment Verification Script

Run this to confirm everything is installed:

```bash
#!/bin/bash
echo "=== Checking DevOps Tools ==="

check_tool() {
    if command -v "$1" &> /dev/null; then
        echo "✅ $1: $($1 $2 2>&1 | head -1)"
    else
        echo "❌ $1: NOT FOUND"
    fi
}

check_tool az version
check_tool terraform version
check_tool kubectl version --client --short
check_tool helm version --short
check_tool docker version --format '{{.Client.Version}}'
check_tool git --version
check_tool gh --version
check_tool kubelogin --version
check_tool jq --version

echo ""
echo "=== Azure Login Status ==="
az account show --query "{Subscription:name, SubscriptionId:id, State:state}" 2>/dev/null || echo "❌ Not logged in to Azure"

echo ""
echo "=== GitHub Auth Status ==="
gh auth status 2>&1 | head -5
```

Save as `scripts/verify-tools.sh` and run:
```bash
chmod +x scripts/verify-tools.sh
./scripts/verify-tools.sh
```

---

## 1.12 Folder Structure Setup

```bash
# From the repo root
mkdir -p terraform/modules/{aks,acr,networking,keyvault}
mkdir -p k8s/{namespaces,otel-demo,monitoring,ingress,secrets}
mkdir -p .github/workflows
mkdir -p docs
mkdir -p scripts

echo "Folder structure created!"
ls -la
```

---

## Summary

After completing this section you should have:
- [x] WSL2 + Ubuntu running on Windows
- [x] Azure CLI installed and logged in to official Azure account
- [x] Terraform installed via tfenv
- [x] kubectl and Helm installed
- [x] Docker Desktop running with WSL2 backend
- [x] GitHub CLI authenticated to personal GitHub account
- [x] kubelogin for AKS auth
- [x] Project folder structure created

**Next:** [02 — Azure & GitHub Setup](02-azure-github-setup.md)
