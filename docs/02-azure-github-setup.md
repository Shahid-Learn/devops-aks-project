# Section 2 — Azure & GitHub Setup

> Configure Azure for AKS hosting and set up OIDC federation between your personal GitHub and your official Azure account. **No long-lived secrets are stored in GitHub.**

---

## 2.1 Why OIDC Instead of Credentials?

Traditional approach (insecure):
```
GitHub Secrets → Store Azure client_secret → Use in Actions
# Problem: Secret expires, can leak, needs rotation
```

OIDC approach (recommended):
```
GitHub Actions → Requests short-lived OIDC token → Azure validates token
# Azure trusts GitHub's identity provider — no secrets stored
```

This is the **Microsoft recommended** approach for GitHub Actions + Azure integration.

---

## 2.2 Azure Setup — Resource Group & Service Principal

### Step 1: Set Variables

```bash
# Edit these to match your setup
# Note: | tr -d '\r' strips Windows carriage returns that break scope strings in WSL
export AZURE_SUBSCRIPTION_ID=$(az account show --query id -o tsv | tr -d '\r')
export AZURE_TENANT_ID=$(az account show --query tenantId -o tsv | tr -d '\r')
export AZURE_LOCATION="swedencentral"              # Use the region closest to you
export RESOURCE_GROUP="rg-devops-aks"
export SP_NAME="sp-github-actions-aks"
export GITHUB_ORG="Shahid-Learn"                   # Your personal GitHub username (not an org)
export GITHUB_REPO="devops-aks-project"

# Verify values are clean (no trailing \r)
echo "Subscription: [$AZURE_SUBSCRIPTION_ID]"
echo "Tenant:       [$AZURE_TENANT_ID]"
```

### Step 2: Create Resource Group

```bash
az group create \
  --name "$RESOURCE_GROUP" \
  --location "$AZURE_LOCATION" \
  --tags project=devops-aks-project environment=learning

echo "✅ Resource group created: $RESOURCE_GROUP"
```

### Step 3: Create Service Principal

```bash
# Create the SP (do NOT use --json-auth or --sdk-auth — both are deprecated)
# Role assignment is done separately in Step 4 to avoid scope string issues
az ad sp create-for-rbac --name "$SP_NAME"
```

> **Note:** This creates the SP without a role assignment. We assign the role separately
> in Step 4 using the object ID — this avoids CLI issues with scope string parsing in WSL.

### Step 4: Note the SP IDs and assign role

```bash
# Get both AppId and ObjectId together
az ad sp list \
  --display-name "$SP_NAME" \
  --query "[].{DisplayName:displayName, AppId:appId, ObjectId:id}" \
  -o table

# Set variables using the values from the table above
export SP_APP_ID="<AppId from output>"
export SP_OBJECT_ID="<ObjectId from output>"

echo "SP App ID:    $SP_APP_ID"
echo "SP Object ID: $SP_OBJECT_ID"

# Assign Contributor role using ObjectId (not AppId — avoids lookup errors)
az role assignment create \
  --assignee-object-id "$SP_OBJECT_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Contributor" \
  --scope "/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP"

# Verify
az role assignment list \
  --assignee "$SP_OBJECT_ID" \
  --query "[].{Role:roleDefinitionName, Scope:scope}" \
  -o table
```

---

## 2.3 Configure OIDC Federation (No Secrets!)

This lets GitHub Actions authenticate to Azure without storing any Azure secret in GitHub.

### Step 5: Create Federated Credentials

```bash
# For the main branch (production deployments)
az ad app federated-credential create \
  --id "$SP_APP_ID" \
  --parameters '{
    "name": "github-main-branch",
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "repo:'"$GITHUB_ORG"'/'"$GITHUB_REPO"':ref:refs/heads/main",
    "audiences": ["api://AzureADTokenExchange"],
    "description": "GitHub Actions main branch"
  }'

# For pull requests (plan-only)
az ad app federated-credential create \
  --id "$SP_APP_ID" \
  --parameters '{
    "name": "github-pull-requests",
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "repo:'"$GITHUB_ORG"'/'"$GITHUB_REPO"':pull_request",
    "audiences": ["api://AzureADTokenExchange"],
    "description": "GitHub Actions pull requests"
  }'

# For specific environment (e.g., production)
az ad app federated-credential create \
  --id "$SP_APP_ID" \
  --parameters '{
    "name": "github-env-production",
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "repo:'"$GITHUB_ORG"'/'"$GITHUB_REPO"':environment:production",
    "audiences": ["api://AzureADTokenExchange"],
    "description": "GitHub Actions production environment"
  }'

echo "✅ OIDC federated credentials configured"
```

### Step 6: Additional Role Assignments

```bash
# Always use --assignee-object-id + --assignee-principal-type to avoid CLI lookup errors

# ACR push/pull permissions
az role assignment create \
  --assignee-object-id "$SP_OBJECT_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "AcrPush" \
  --scope "/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP"

# For AKS management
az role assignment create \
  --assignee-object-id "$SP_OBJECT_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Azure Kubernetes Service Cluster Admin Role" \
  --scope "/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP"

echo "✅ Role assignments done"
```

---

## 2.4 GitHub Repository Setup

### Step 7: Create GitHub Repository

```bash
# Using GitHub CLI (authenticated to personal account)
gh repo create devops-aks-project \
  --public \
  --description "End-to-end DevOps project: OpenTelemetry demo on AKS" \
  --clone

cd devops-aks-project
```

> Or create manually at https://github.com/new

### Step 8: Set GitHub Secrets

```bash
# These are NOT sensitive — they are IDs, not secrets
# That is the beauty of OIDC!

gh secret set AZURE_CLIENT_ID     --body "$SP_APP_ID"
gh secret set AZURE_TENANT_ID     --body "$AZURE_TENANT_ID"
gh secret set AZURE_SUBSCRIPTION_ID --body "$AZURE_SUBSCRIPTION_ID"

echo "✅ GitHub secrets configured"
```

> **Note:** With OIDC, you only store 3 non-sensitive IDs (not passwords or keys). The actual authentication happens via token exchange at runtime.

### Step 9: Set GitHub Variables (Non-Sensitive Config)

```bash
gh variable set AZURE_LOCATION     --body "$AZURE_LOCATION"
gh variable set RESOURCE_GROUP     --body "$RESOURCE_GROUP"
gh variable set AKS_CLUSTER_NAME   --body "aks-devops-project"
gh variable set ACR_NAME           --body "acrdevopsproject"   # globally unique

echo "✅ GitHub variables configured"
```

### Step 10: Create GitHub Environment with Protection Rules

```bash
# Create production environment with required reviewers
gh api \
  --method PUT \
  -H "Accept: application/vnd.github+json" \
  /repos/$GITHUB_ORG/$GITHUB_REPO/environments/production \
  --field wait_timer=0

echo "✅ GitHub environment 'production' created"
echo "   Go to: https://github.com/$GITHUB_ORG/$GITHUB_REPO/settings/environments"
echo "   Add yourself as required reviewer for production"
```

---

## 2.5 Azure Storage for Terraform State

Terraform state must be stored remotely so it can be shared between local development and GitHub Actions.

```bash
# Create storage account for Terraform state
STORAGE_ACCOUNT="stterraformaks$(openssl rand -hex 4)"
CONTAINER_NAME="tfstate"

az storage account create \
  --name "$STORAGE_ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$AZURE_LOCATION" \
  --sku Standard_LRS \
  --encryption-services blob \
  --min-tls-version TLS1_2 \
  --allow-blob-public-access false

az storage container create \
  --name "$CONTAINER_NAME" \
  --account-name "$STORAGE_ACCOUNT"

# Enable versioning for state file protection
az storage account blob-service-properties update \
  --account-name "$STORAGE_ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" \
  --enable-versioning true

echo "Storage Account: $STORAGE_ACCOUNT"
echo "Container:       $CONTAINER_NAME"

# Save these to GitHub variables
gh variable set TF_STORAGE_ACCOUNT --body "$STORAGE_ACCOUNT"
gh variable set TF_STATE_CONTAINER --body "$CONTAINER_NAME"
```

---

## 2.6 ACR (Azure Container Registry) Pre-Create

```bash
ACR_NAME="acrdevopsproject"   # Must be globally unique — change if needed

az acr create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$ACR_NAME" \
  --sku Basic \
  --admin-enabled false \
  --location "$AZURE_LOCATION"

# Enable ACR tasks (needed for GitHub Actions push)
az acr update --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP"

echo "ACR Login Server: $(az acr show --name $ACR_NAME --query loginServer -o tsv)"
```

---

## 2.7 Verify Everything

```bash
# Verify SP exists
az ad sp show --id "$SP_APP_ID" --query "{Name:displayName, AppId:appId}" -o table

# Verify federated credentials
az ad app federated-credential list --id "$SP_APP_ID" -o table

# Verify role assignments
az role assignment list --assignee "$SP_OBJECT_ID" -o table

# Verify storage account
az storage account show --name "$STORAGE_ACCOUNT" --query "name" -o tsv

# Verify ACR
az acr show --name "$ACR_NAME" --query "loginServer" -o tsv

# Verify GitHub secrets
gh secret list
gh variable list
```

---

## 2.8 How OIDC Auth Works in GitHub Actions

```yaml
# In your workflow file:
permissions:
  id-token: write   # Required for OIDC
  contents: read

steps:
  - name: Azure Login via OIDC
    uses: azure/login@v2
    with:
      client-id: ${{ secrets.AZURE_CLIENT_ID }}
      tenant-id: ${{ secrets.AZURE_TENANT_ID }}
      subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
      # No client-secret needed! GitHub gets a short-lived OIDC token
      # and Azure validates it against the federated credential we configured
```

**Token flow:**
1. GitHub Actions generates a short-lived OIDC JWT token signed by GitHub
2. `azure/login` action sends that token to Azure AD
3. Azure validates: "Is this from `repo:org/repo:ref:refs/heads/main`? Yes → trust it"
4. Azure issues a short-lived access token (valid for 1 hour)
5. The workflow uses this token for all subsequent Azure operations

---

## Summary Checklist

- [x] Azure Resource Group created
- [x] Service Principal created with Contributor role
- [x] OIDC federated credentials configured (main, PR, production)
- [x] GitHub repo created and initialized
- [x] GitHub secrets set (CLIENT_ID, TENANT_ID, SUBSCRIPTION_ID)
- [x] GitHub variables set (location, resource group, cluster name, ACR name)
- [x] GitHub `production` environment created
- [x] Terraform state storage account created in Azure
- [x] ACR created

**Next:** [03 — Terraform AKS](03-terraform-aks.md)
