# Section 6 — GitHub Actions CI/CD Pipelines

> Build a complete CI/CD automation pipeline using GitHub Actions. Personal GitHub repo → Azure infrastructure + AKS deployments using OIDC (no stored credentials).

---

## Prerequisites for CI/CD Workflows

Before running these workflows, ensure the following are completed:

1. **GitHub & Azure OIDC Setup** (from [Section 2](02-azure-github-setup.md)):
   - Service Principal created: `sp-github-actions-aks`
   - OIDC federated credentials configured (main branch, pull requests, production environment)
   - SP has Contributor role on resource group + ACR / AKS permissions
   
   > **Important:** GitHub Actions uses the **Service Principal (SP)** from Chapter 2 for authentication, NOT a UAMI. The SP_APP_ID is what you'll store as AZURE_CLIENT_ID.

2. **Azure Infrastructure** (from [Section 3](03-terraform-aks.md)):
   - `terraform apply` successfully deployed AKS cluster, ACR, and all resources
   - Note: AKS has `oidc_issuer_enabled = true` and `workload_identity_enabled = true` (platform enabled, but does NOT auto-create UAMI)

3. **Kubernetes Setup** (from [Section 5](05-kubernetes-manifests.md)):
   - Namespaces created: `otel-demo`, `monitoring`, `ingress-nginx`
   - NGINX Ingress Controller deployed
   - Secrets Store CSI Driver installed (for pod Workload Identity)
   - **Manual Workload Identity setup completed** (Section 5, Step 1.5):
     - User-Assigned Managed Identity (UAMI) created for **pods**
     - Federated credential configured (OIDC → Kubernetes service account mapping)
     - UAMI granted "Key Vault Secrets User" role
     - Secret stored in Azure Key Vault (`db-password`)
   - Prometheus + Grafana deployed with kube-prometheus-stack

4. **GitHub Configuration**:
   - Repository has GitHub Actions enabled
   - Set up the following **Secrets** (GitHub → Settings → Secrets → Actions):
     ```
     AZURE_CLIENT_ID          (from Service Principal in Chapter 2: SP_APP_ID)
     AZURE_TENANT_ID          (Azure Entra ID tenant ID)
     AZURE_SUBSCRIPTION_ID    (Azure subscription ID)
     ```
   - Set up the following **Variables** (GitHub → Settings → Variables → Actions):
     ```
     RESOURCE_GROUP           (Azure resource group name)
     ACR_NAME                 (Azure Container Registry name, without .azurecr.io)
     AKS_CLUSTER_NAME         (AKS cluster name)
     TF_STORAGE_ACCOUNT       (Storage account for Terraform state)
     TF_STATE_CONTAINER       (Container name for Terraform state, typically "tfstate")
     ```

> [!NOTE]
> **Clarification: SP vs UAMI**
> - **Service Principal (Chapter 2)** → Used by GitHub Actions runner for Terraform/Helm/ACR access
> - **User-Assigned Managed Identity (Chapter 5)** → Used by Kubernetes pods for Key Vault secret access
> - These are two different identities with different purposes and scopes.

> [!TIP]
> To retrieve the Service Principal values from Chapter 2:
> ```bash
> # Get SP App ID (use this as AZURE_CLIENT_ID)
> az ad sp list --display-name "sp-github-actions-aks" \
>   --query "[0].appId" -o tsv
> 
> # Get subscription ID
> az account show --query id
> 
> # Get resource names from Terraform outputs
> terraform output -json | jq '.[] | .value'
> ```

### Quick Setup: GitHub Actions Secrets & Variables

**Step 1: Create GitHub Actions Environment**

1. Go to repository → **Settings** → **Environments**
2. Click **New environment** → Name it `production`
3. Under "Deployment branches" → **Require branches to be deployed before releasing** (optional, for approval gates)

**Step 2: Add Secrets from Chapter 2 Service Principal** (Settings → **Secrets** → **Actions**)

```bash
# Retrieve the Service Principal created in Chapter 2
az ad sp list \
  --display-name "sp-github-actions-aks" \
  --query "[].{AppId:appId, TenantId:appOwnerTenantId}" \
  -o json

# Get subscription ID
az account show --query id -o tsv
```

Then in GitHub UI, add these secrets:
- `AZURE_CLIENT_ID` = SP_APP_ID (from Chapter 2)
- `AZURE_TENANT_ID` = Tenant ID
- `AZURE_SUBSCRIPTION_ID` = Subscription ID

**Step 3: Add Variables** (Settings → **Variables** → **Actions**)

```bash
# Get these from Terraform outputs or Azure
terraform output -json

# Then add in GitHub UI:
RESOURCE_GROUP          # e.g., "rg-aks-devops"
ACR_NAME                # e.g., "acrdevopsprojectd1e51ba4" (without .azurecr.io)
AKS_CLUSTER_NAME        # e.g., "aks-devops-project-v135"
TF_STORAGE_ACCOUNT      # e.g., "tfstateb8f3c86d" (backend storage account)
TF_STATE_CONTAINER      # e.g., "tfstate"
```

> [!NOTE]
> If you skipped Chapter 2, you need to go back and create the Service Principal with OIDC federation before GitHub Actions can authenticate to Azure.

---

## 6.1 Unified Pipeline Overview

```
Developer pushes code
        │
        ├── Pull Request ──────▶ [terraform.yml]
        │   (on: pull_request)      │
        │                           ├─ terraform-plan-pr
        │                           │   ├─ Plan
        │                           │   ├─ Comment on PR
        │                           │   └─ Review + approve
        │                           
        └── Merge to main ────▶ [terraform.yml]
            (on: push)             │
                                   ├─ terraform-plan-main
                                   │   ├─ Plan
                                   │   └─ Upload tfplan artifact
                                   │
                                   ├─ terraform-apply-main
                                   │   ├─ Download tfplan artifact
                                   │   ├─ Manual approval gate
                                   │   └─ Apply (using saved plan)
                                   │
                                   ├─ [ci-build-push.yml] (CI separately)
                                   │   ├─ Build changed service images
                                   │   ├─ Push to ACR
                                   │   └─ Trigger cd-deploy.yml
                                   │
                                   └─ [cd-deploy.yml] (CD separately)
                                       ├─ Approval gate
                                       ├─ Helm upgrade
                                       └─ Smoke test
```

**Key improvement:** Terraform plan and apply are now in a single workflow file with 3 jobs:
- **Job 1** (PR only): Plan for review, comment on PR
- **Job 2** (main only): Plan, save tfplan artifact
- **Job 3** (main only): Approval gate → Download artifact → Apply exact saved plan

This ensures apply uses the same plan state as reviewed on main.

---

## 6.2 Unified Workflow: Terraform Plan (PR) + Plan & Apply (Main)

File: `.github/workflows/terraform.yml`

This single workflow handles both pull request planning and main branch plan/apply:

```yaml
name: Terraform

on:
  pull_request:
    branches: [main]
    paths:
      - 'terraform/**'
  push:
    branches: [main]
    paths:
      - 'terraform/**'
  workflow_dispatch:   # Allow manual trigger

permissions:
  id-token: write      # OIDC
  contents: read
  pull-requests: write # Comment on PR

env:
  TF_VERSION: "1.9.8"
  ARM_CLIENT_ID: ${{ secrets.AZURE_CLIENT_ID }}
  ARM_TENANT_ID: ${{ secrets.AZURE_TENANT_ID }}
  ARM_SUBSCRIPTION_ID: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
  ARM_USE_OIDC: "true"

jobs:
  # JOB 1: Plan on Pull Request (for review)
  terraform-plan-pr:
    name: Plan on PR
    runs-on: ubuntu-latest
    if: github.event_name == 'pull_request'
    defaults:
      run:
        working-directory: terraform

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Azure Login via OIDC
        uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: ${{ env.TF_VERSION }}

      - name: Terraform Format Check
        run: terraform fmt -check -recursive
        continue-on-error: true

      - name: Terraform Init
        run: terraform init

      - name: Terraform Validate
        run: terraform validate

      - name: Terraform Plan
        id: plan
        run: terraform plan -no-color
        continue-on-error: true

      - name: Comment Plan on PR
        uses: actions/github-script@v7
        if: github.event_name == 'pull_request'
        with:
          script: |
            const output = `#### Terraform Plan 📖
            \`\`\`
            ${{ steps.plan.outputs.stdout }}
            \`\`\`
            *Pushed by: @${{ github.actor }}*`;

            github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: output
            })

      - name: Terraform Plan Status
        if: steps.plan.outcome == 'failure'
        run: exit 1

  # JOB 2: Plan on Main (save artifact)
  terraform-plan-main:
    name: Plan on Main
    runs-on: ubuntu-latest
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    defaults:
      run:
        working-directory: terraform
    outputs:
      plan_exists: ${{ steps.plan.outcome == 'success' }}

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Azure Login via OIDC
        uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: ${{ env.TF_VERSION }}

      - name: Terraform Init
        run: terraform init

      - name: Terraform Plan
        id: plan
        run: terraform plan -out=tfplan
        continue-on-error: true

      - name: Upload tfplan artifact
        uses: actions/upload-artifact@v4
        with:
          name: tfplan
          path: terraform/tfplan
          retention-days: 1

      - name: Terraform Plan Status
        if: steps.plan.outcome == 'failure'
        run: exit 1

  # JOB 3: Apply on Main (using saved plan)
  terraform-apply-main:
    name: Apply on Main
    runs-on: ubuntu-latest
    needs: terraform-plan-main
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    environment: production     # Requires manual approval!
    defaults:
      run:
        working-directory: terraform

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Download tfplan artifact
        uses: actions/download-artifact@v4
        with:
          name: tfplan
          path: terraform/

      - name: Azure Login via OIDC
        uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: ${{ env.TF_VERSION }}

      - name: Terraform Init
        run: terraform init

      - name: Terraform Apply (using saved plan)
        run: terraform apply -no-color tfplan

      - name: Get Terraform Outputs
        id: tf_outputs
        run: |
          echo "aks_cluster=$(terraform output -raw aks_cluster_name)" >> $GITHUB_OUTPUT
          echo "acr_server=$(terraform output -raw acr_login_server)" >> $GITHUB_OUTPUT

      - name: Create deployment summary
        if: always()
        run: |
          echo "## Terraform Apply Summary" >> $GITHUB_STEP_SUMMARY
          echo "| Item | Value |" >> $GITHUB_STEP_SUMMARY
          echo "|------|-------|" >> $GITHUB_STEP_SUMMARY
          echo "| Cluster | ${{ steps.tf_outputs.outputs.aks_cluster }} |" >> $GITHUB_STEP_SUMMARY
          echo "| ACR | ${{ steps.tf_outputs.outputs.acr_server }} |" >> $GITHUB_STEP_SUMMARY
          echo "| Applied by | @${{ github.actor }} |" >> $GITHUB_STEP_SUMMARY
          echo "| Timestamp | $(date -u) |" >> $GITHUB_STEP_SUMMARY
```

---

## 6.3 Workflow: CI — Build & Push Images

This workflow belongs in the **application source repository**, not necessarily this infrastructure repository.

For your setup, the right home is the repo that contains the microservice source tree:

- https://github.com/Shahid-Learn/opentelemetry-demo/tree/main/src

Why: this workflow detects changes under `src/`, builds service images from those folders, and pushes them to ACR. In your setup the `src/` tree lives in the application repository, so this workflow should be created there and should trigger deployment in the infra repo after a successful push on `main`.

Before using this workflow in the application repo, add these settings there:

- **Secrets**
  - `AZURE_CLIENT_ID`
  - `AZURE_TENANT_ID`
  - `AZURE_SUBSCRIPTION_ID`
  - `INFRA_REPO_DISPATCH_TOKEN`  
    Fine-grained PAT or GitHub App token with permission to run workflows in `Shahid-Learn/devops-aks-project`
- **Variables**
  - `ACR_NAME`
  - `INFRA_REPO_OWNER` = `Shahid-Learn`
  - `INFRA_REPO_NAME` = `devops-aks-project`

`.github/workflows/ci-build-push.yml`

```yaml
name: CI — Build and Push Images

on:
  push:
    branches: [main]
    paths:
      - 'src/**'
  pull_request:
    branches: [main]
    paths:
      - 'src/**'
  workflow_dispatch:
    inputs:
      services:
        description: 'Comma-separated list of services to build (leave empty for all changed)'
        required: false

permissions:
  id-token: write
  contents: read
  security-events: write   # For vulnerability scan results

env:
  ACR_SERVER: ${{ vars.ACR_NAME }}.azurecr.io

concurrency:
  group: ci-build-${{ github.ref }}
  cancel-in-progress: true

jobs:
  detect-changes:
    name: Detect Changed Services
    runs-on: ubuntu-latest
    outputs:
      services: ${{ steps.changes.outputs.services }}

    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Detect changed service directories
        id: changes
        run: |
          if [ "${{ github.event_name }}" = "workflow_dispatch" ] && [ "${{ github.event.inputs.services }}" != "" ]; then
            # Manual trigger with specified services
            SERVICES=$(echo "${{ github.event.inputs.services }}" | tr ',' '\n' | jq -R -s -c 'split("\n")[:-1]')
          else
            # Detect from git diff for PRs and direct pushes
            if [ "${{ github.event_name }}" = "pull_request" ]; then
              BASE_SHA="${{ github.event.pull_request.base.sha }}"
              HEAD_SHA="${{ github.event.pull_request.head.sha }}"
            else
              BASE_SHA="${{ github.event.before }}"
              HEAD_SHA="${{ github.sha }}"
            fi

            CHANGED=$(git diff --name-only "$BASE_SHA" "$HEAD_SHA" | grep '^src/' || true)
            if [ -z "$CHANGED" ]; then
              SERVICES='[]'
            else
              SERVICES=$(echo "$CHANGED" | cut -d'/' -f2 | sort -u | jq -R -s -c 'split("\n")[:-1]')
            fi
          fi
          echo "services=$SERVICES" >> $GITHUB_OUTPUT
          echo "Changed services: $SERVICES"

  build-push:
    name: Build & Push — ${{ matrix.service }}
    runs-on: ubuntu-latest
    needs: detect-changes
    if: needs.detect-changes.outputs.services != '[]'

    strategy:
      matrix:
        service: ${{ fromJson(needs.detect-changes.outputs.services) }}
      fail-fast: false    # Build other services even if one fails

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Azure Login via OIDC
        uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

      - name: Login to ACR
        run: az acr login --name ${{ vars.ACR_NAME }}

      - name: Set image tags
        id: meta
        run: |
          SHA=$(echo ${{ github.sha }} | cut -c1-7)
          echo "sha_tag=$SHA" >> $GITHUB_OUTPUT
          echo "image=${{ env.ACR_SERVER }}/${{ matrix.service }}" >> $GITHUB_OUTPUT
          echo "full_image=${{ env.ACR_SERVER }}/${{ matrix.service }}:$SHA" >> $GITHUB_OUTPUT

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Build and push image
        uses: docker/build-push-action@v5
        with:
          context: src/${{ matrix.service }}
          push: ${{ github.ref == 'refs/heads/main' }}    # Only push on main
          tags: |
            ${{ steps.meta.outputs.image }}:${{ steps.meta.outputs.sha_tag }}
            ${{ steps.meta.outputs.image }}:latest
          cache-from: type=registry,ref=${{ steps.meta.outputs.image }}:buildcache
          cache-to: type=registry,ref=${{ steps.meta.outputs.image }}:buildcache,mode=max
          platforms: linux/amd64

      - name: Scan image for vulnerabilities
        if: github.ref == 'refs/heads/main'
        uses: aquasecurity/trivy-action@master
        with:
          image-ref: ${{ steps.meta.outputs.full_image }}
          format: sarif
          output: trivy-results.sarif
          severity: HIGH,CRITICAL
          exit-code: '0'   # Don't fail build, just report

      - name: Upload vulnerability scan results
        if: github.ref == 'refs/heads/main'
        uses: github/codeql-action/upload-sarif@v3
        with:
          sarif_file: trivy-results.sarif

  trigger-deploy:
    name: Trigger Infra Repo Deployment
    runs-on: ubuntu-latest
    needs: build-push
    if: github.ref == 'refs/heads/main' && needs.build-push.result == 'success'

    steps:
      - name: Trigger infra repo CD workflow
        uses: actions/github-script@v8
        env:
          IMAGE_TAG: ${{ github.sha }}
          INFRA_REPO_OWNER: ${{ vars.INFRA_REPO_OWNER }}
          INFRA_REPO_NAME: ${{ vars.INFRA_REPO_NAME }}
        with:
          github-token: ${{ secrets.INFRA_REPO_DISPATCH_TOKEN }}
          script: |
            await github.rest.actions.createWorkflowDispatch({
              owner: process.env.INFRA_REPO_OWNER,
              repo: process.env.INFRA_REPO_NAME,
              workflow_id: 'cd-deploy.yml',
              ref: 'main',
              inputs: {
                image_tag: process.env.IMAGE_TAG.substring(0, 7),
                environment: 'production'
              }
            });
```

### How to read this workflow

Think of it as three stages:

1. `detect-changes`
   Finds which service folders under `src/` changed.

2. `build-push`
   Creates one parallel job per changed service using a matrix.

3. `trigger-deploy`
  Only on `main`, tells the **infra repo** CD workflow to deploy the new image tag.

### Why the source repo matters

This line assumes the repository contains one folder per service under `src/`:

```yaml
context: src/${{ matrix.service }}
```

That means each matrix item must resolve to a real folder such as:

- `src/frontend`
- `src/cart`
- `src/recommendation`
- `src/load-generator`

In your upstream source repo, that assumption is valid because `src/` contains service directories like `frontend`, `cart`, `checkout`, `recommendation`, `payment`, `shipping`, and others.

### Stage 1: Detect changed services

```yaml
      - name: Detect changed service directories
        id: changes
        run: |
          if [ "${{ github.event.inputs.services }}" != "" ]; then
            SERVICES=$(echo "${{ github.event.inputs.services }}" | tr ',' '\n' | jq -R -s -c 'split("\n")[:-1]')
          else
            CHANGED=$(git diff --name-only HEAD~1 HEAD | grep '^src/' | cut -d'/' -f2 | sort -u | jq -R -s -c 'split("\n")[:-1]')
            SERVICES=$CHANGED
          fi
          echo "services=$SERVICES" >> $GITHUB_OUTPUT
```

What it does:

- `git diff --name-only HEAD~1 HEAD`
  lists files changed in the latest comparison.
- `grep '^src/'`
  keeps only source repo paths under `src/`.
- `cut -d'/' -f2`
  extracts the service folder name.
- `sort -u`
  removes duplicates.
- `jq -R -s -c 'split("\n")[:-1]'`
  converts the list into JSON for the GitHub Actions matrix.

Example:

If these files changed:

```text
src/frontend/main.go
src/frontend/Dockerfile
src/cart/app.py
```

Then the job output becomes:

```json
["cart","frontend"]
```

That JSON is passed into the matrix job.

### Stage 2: Build one image per changed service

This part is the key:

```yaml
strategy:
  matrix:
    service: ${{ fromJson(needs.detect-changes.outputs.services) }}
```

If the previous job outputs:

```json
["cart","frontend","recommendation"]
```

GitHub Actions starts three parallel jobs:

- build `cart`
- build `frontend`
- build `recommendation`

Each job uses the current matrix value via `${{ matrix.service }}`.

### Detailed explanation of the image parameters

#### 1. `ACR_SERVER`

```yaml
env:
  ACR_SERVER: ${{ vars.ACR_NAME }}.azurecr.io
```

Builds the registry hostname from the GitHub variable.

Example:

- `ACR_NAME=acrdevopsprojectd1e51ba4`
- `ACR_SERVER=acrdevopsprojectd1e51ba4.azurecr.io`

This avoids repeating the registry host in every step.

#### 2. `Set image tags`

```yaml
      - name: Set image tags
        id: meta
        run: |
          SHA=$(echo ${{ github.sha }} | cut -c1-7)
          echo "sha_tag=$SHA" >> $GITHUB_OUTPUT
          echo "image=${{ env.ACR_SERVER }}/${{ matrix.service }}" >> $GITHUB_OUTPUT
          echo "full_image=${{ env.ACR_SERVER }}/${{ matrix.service }}:$SHA" >> $GITHUB_OUTPUT
```

This produces three values:

- `sha_tag`
  Short git commit SHA such as `52a8a76`
- `image`
  Repository path such as `acrdevopsprojectd1e51ba4.azurecr.io/frontend`
- `full_image`
  Full image reference such as `acrdevopsprojectd1e51ba4.azurecr.io/frontend:52a8a76`

Why use SHA tags:

- immutable and traceable
- easy rollback to a known commit
- matches the deployment model you already use in Chapter 5

#### 3. `context`

```yaml
context: src/${{ matrix.service }}
```

This tells Docker which folder to send as the build context.

Example for `frontend`:

```text
src/frontend
```

That folder should contain the Dockerfile or all files needed by the Dockerfile.

Practical meaning:

- only that service folder is built
- not the whole monorepo
- faster builds
- fewer accidental cross-service dependencies

#### 4. `push`

```yaml
push: ${{ github.ref == 'refs/heads/main' }}
```

Behavior:

- on pull request: build only, do not push
- on `main`: build and push

This is a good safety pattern because PR validation checks whether the image can build without publishing unreviewed images.

#### 5. `tags`

```yaml
tags: |
  ${{ steps.meta.outputs.image }}:${{ steps.meta.outputs.sha_tag }}
  ${{ steps.meta.outputs.image }}:latest
```

Two tags are pushed for the same image:

- `frontend:52a8a76`
  deterministic release tag
- `frontend:latest`
  moving convenience tag

Recommendation:

- deploy with the SHA tag
- use `latest` only for manual testing or convenience

This matches your deployment pattern, where CD passes `image_tag` as the short SHA.

#### 6. `cache-from`

```yaml
cache-from: type=registry,ref=${{ steps.meta.outputs.image }}:buildcache
```

This tells Buildx to pull previous build cache from the registry if it exists.

Effect:

- reused layers make rebuilds faster
- especially useful when only a small part of the service changed

#### 7. `cache-to`

```yaml
cache-to: type=registry,ref=${{ steps.meta.outputs.image }}:buildcache,mode=max
```

This pushes updated build cache back to ACR.

Meaning of `mode=max`:

- export as much cache metadata as possible
- best reuse on future builds
- trades some extra registry storage for faster CI

#### 8. `platforms`

```yaml
platforms: linux/amd64
```

This forces the built image architecture.

Why it matters:

- AKS nodes typically run Linux amd64 images
- prevents accidental architecture mismatch when the builder host differs

If you later need multi-arch builds, this can become:

```yaml
platforms: linux/amd64,linux/arm64
```

but for AKS learning setup, `linux/amd64` is the right default.

### Stage 3: Vulnerability scan and deploy trigger

After the image is pushed on `main`:

- Trivy scans the exact pushed image reference
- SARIF is uploaded to GitHub Security
- `trigger-deploy` dispatches the CD workflow with the same short SHA

That is the handoff between CI and CD:

- CI decides what image was produced
- CD in the infra repo decides when and where to deploy it

### Example end-to-end flow

Assume you change only:

```text
src/frontend/... 
src/cart/...
```

Then this workflow does:

1. Detect changed services: `["cart","frontend"]`
2. Build image `acr.../cart:<sha>`
3. Build image `acr.../frontend:<sha>`
4. Push both images if branch is `main`
5. Scan both images
6. Trigger CD with `image_tag=<sha>`

### Important repo-design note

Because your source code is in a separate repo, the clean split is:

1. **Source repo** (`opentelemetry-demo`)
   Contains `ci-build-push.yml`

2. **Infra repo** (`devops-aks-project`)
   Contains Terraform, Kubernetes manifests, and `cd-deploy.yml`

In that model, CI in the source repo should trigger CD in the infra repo. The workflow above uses **cross-repo `workflow_dispatch`** because your infra repo already exposes `cd-deploy.yml` as a manual workflow.

The current chapter now shows the real split-repo flow you can implement directly. If you later want a more GitOps-style handoff, the next evolution would be updating a values file or opening an automated PR in the infra repo instead of dispatching the workflow directly.

> [!TIP]
> For learning, start with cross-repo `workflow_dispatch` because it matches the deploy workflow you already validated in Section 6.2. The main change from the same-repo example is not the Docker build logic. The main change is how CI notifies the infra repo to deploy the new SHA.

---

## 6.4 Workflow: CD — Deploy to AKS

`.github/workflows/cd-deploy.yml`

```yaml
name: CD — Deploy to AKS

on:
  workflow_dispatch:
    inputs:
      image_tag:
        description: 'Image tag (git SHA) to deploy'
        required: true
      environment:
        description: 'Target environment'
        required: false
        default: 'production'
        type: choice
        options:
          - production

permissions:
  id-token: write
  contents: read
  deployments: write

jobs:
  deploy:
    name: Deploy to AKS
    runs-on: ubuntu-latest
    environment: ${{ github.event.inputs.environment }}   # Requires manual approval

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Azure Login via OIDC
        uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

      - name: Get AKS credentials
        uses: azure/aks-set-context@v3
        with:
          resource-group: ${{ vars.RESOURCE_GROUP }}
          cluster-name: ${{ vars.AKS_CLUSTER_NAME }}

      - name: Setup Helm
        uses: azure/setup-helm@v3
        with:
          version: 'v3.14.0'

      - name: Deploy OTel Demo with Helm
        run: |
          helm upgrade --install otel-demo open-telemetry/opentelemetry-demo \
            --namespace otel-demo \
            --create-namespace \
            --values k8s/otel-demo/values.yaml \
            --set "default.image.tag=${{ github.event.inputs.image_tag }}" \
            --set "default.image.repository=${{ vars.ACR_NAME }}.azurecr.io" \
            --wait \
            --timeout 10m \
            --atomic    # Rollback on failure

      - name: (Optional) Apply HPA
        run: |
          if [ -f "k8s/otel-demo/hpa-frontend.yaml" ]; then
            echo "Applying frontend HPA..."
            kubectl apply -f k8s/otel-demo/hpa-frontend.yaml
          else
            echo "HPA file not found, skipping"
          fi
        continue-on-error: true

      - name: (Optional) Apply Resource Quotas
        run: |
          if [ -f "k8s/namespaces/resource-quota.yaml" ]; then
            echo "Applying resource quotas..."
            kubectl apply -f k8s/namespaces/resource-quota.yaml
          else
            echo "Resource quota file not found, skipping"
          fi
        continue-on-error: true

      - name: Verify deployment
        run: |
          echo "=== Deployment Status ==="
          kubectl get pods -n otel-demo
          kubectl rollout status deployment -n otel-demo --timeout=5m

      - name: Run smoke test
        run: |
          INGRESS_IP=$(kubectl get service ingress-nginx-controller \
            -n ingress-nginx \
            -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

          echo "Testing http://$INGRESS_IP ..."
          STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://$INGRESS_IP" --max-time 30)

          if [ "$STATUS" -eq 200 ]; then
            echo "✅ Smoke test passed: HTTP $STATUS"
          else
            echo "❌ Smoke test failed: HTTP $STATUS"
            exit 1
          fi

      - name: Create deployment summary
        if: always()
        run: |
          echo "## Deployment Summary" >> $GITHUB_STEP_SUMMARY
          echo "| Item | Value |" >> $GITHUB_STEP_SUMMARY
          echo "|------|-------|" >> $GITHUB_STEP_SUMMARY
          echo "| Environment | ${{ github.event.inputs.environment }} |" >> $GITHUB_STEP_SUMMARY
          echo "| Image Tag | ${{ github.event.inputs.image_tag }} |" >> $GITHUB_STEP_SUMMARY
          echo "| Cluster | ${{ vars.AKS_CLUSTER_NAME }} |" >> $GITHUB_STEP_SUMMARY
          echo "| Deployed by | @${{ github.actor }} |" >> $GITHUB_STEP_SUMMARY
          echo "| Timestamp | $(date -u) |" >> $GITHUB_STEP_SUMMARY
```

---

## 6.5 Optional: HPA and Resource Quotas

The CD workflow includes optional steps to deploy HPA and resource quotas if they exist in the repo:

### HPA Deployment

If `k8s/otel-demo/hpa-frontend.yaml` exists, the workflow applies it after Helm upgrade:

```bash
kubectl apply -f k8s/otel-demo/hpa-frontend.yaml
```

**Purpose:** Automatically scale frontend replicas based on CPU utilization (1-6 replicas, target 65% CPU).

**Configure:** Edit `k8s/otel-demo/hpa-frontend.yaml` to adjust:
- `minReplicas` / `maxReplicas` — replica bounds
- `averageUtilization` — CPU target threshold
- `behavior.scaleUp/scaleDown` — scaling aggressiveness and timing

> See [Section 5.8](05-kubernetes-manifests.md#58-horizontalpodautoscaler-optional) for full HPA documentation and playground.

### Resource Quotas Deployment

If `k8s/namespaces/resource-quota.yaml` exists, the workflow applies it:

```bash
kubectl apply -f k8s/namespaces/resource-quota.yaml
```

**Purpose:** Prevent resource starvation by setting hard limits on CPU, memory, and pod count per namespace.

**Recommended values** (for otel-demo namespace):
```yaml
spec:
  hard:
    requests.cpu: "4"              # 4 cores reserved
    requests.memory: "10Gi"        # 10 GB reserved
    limits.cpu: "8"                # 8 cores hard cap
    limits.memory: "16Gi"          # 16 GB hard cap
    pods: "60"                     # max 60 pods in namespace
```

> See [Section 5.7](05-kubernetes-manifests.md#57-resource-quotas) for quota calculation based on actual cluster metrics.

### Conditional Logic

Both steps use `continue-on-error: true` — if files don't exist or apply fails, deployment continues. This allows:
- Rolling out HPA gradually (e.g., test on branch before merging to main)
- Deploying without quotas on first run
- Easy enable/disable by adding/removing files

---

## 6.6 Reusable Workflow — Azure Login

Extract common steps into a reusable workflow:

`.github/workflows/reusable-azure-login.yml`

```yaml
name: Reusable — Azure Login

on:
  workflow_call:
    secrets:
      AZURE_CLIENT_ID:
        required: true
      AZURE_TENANT_ID:
        required: true
      AZURE_SUBSCRIPTION_ID:
        required: true

jobs:
  # This is just for documentation — use azure/login@v2 in each workflow
  # GitHub Actions doesn't support reusable login steps directly
  placeholder:
    runs-on: ubuntu-latest
    steps:
      - run: echo "Use azure/login@v2 in each workflow"
```

---

## 6.7 Complete CI/CD Flow Diagram

```
Code Push to main
        │
        ▼
[ci-build-push.yml]
  1. Detect changed services (git diff)
  2. For each changed service (parallel matrix):
     a. Azure Login (OIDC)
     b. ACR Login
     c. Docker build (with layer caching)
     d. Push to ACR with SHA tag
     e. Trivy vulnerability scan
  3. All builds pass?
        │ YES
        ▼
[Trigger cd-deploy.yml]
  1. Wait for manual approval (GitHub Environment rule)
        │ APPROVED
        ▼
  2. Azure Login (OIDC)
  3. Get AKS credentials
  4. Helm upgrade --atomic (app services)
  5. (Optional) Apply HPA
  6. (Optional) Apply Resource Quotas
  7. Smoke test
  8. Summary report
```

---

## 6.8 GitHub Actions Tips & Best Practices

| Practice | Why |
|---------|-----|
| Use `--atomic` in Helm upgrades | Auto-rollback on failed deployment |
| Pin action versions to SHA | Prevent supply chain attacks |
| Use `fail-fast: false` in matrix | Other services still deploy if one fails |
| Use `environment:` for production | Requires manual approval before deploy |
| Store only IDs in secrets (OIDC) | No passwords = no secret rotation |
| Use `cache-from/cache-to` in Docker build | Faster builds (layer caching via ACR) |
| Add `workflow_dispatch` to all workflows | Allows manual re-runs |
| Use `GITHUB_STEP_SUMMARY` | Rich deployment summaries in Actions UI |

> [!NOTE]
> Corporate TLS interception issues (for example Zscaler CA trust problems during `docker build`/`az acr login`) are usually local-machine or self-hosted-runner concerns. GitHub-hosted runners typically do not sit behind your corporate proxy, so these issues are less common there. If you move to self-hosted runners inside corporate network, apply the same certificate trust patterns documented in [PRE-ACR-BUILD-CHECKLIST.md](PRE-ACR-BUILD-CHECKLIST.md).

| Environment | Typical TLS behavior | What you should do |
|---|---|---|
| Local machine (WSL2 + corporate proxy) | Most likely to hit cert/trust errors during build/login | Apply WSL and Docker build trust fixes from [PRE-ACR-BUILD-CHECKLIST.md](PRE-ACR-BUILD-CHECKLIST.md) |
| GitHub-hosted runners | Usually not behind corporate interception proxy | Standard workflow is typically enough; no special Zscaler handling needed |
| Self-hosted runners (inside corporate network) | Can hit same cert issues as local machine | Install corporate CA chain on runner host and in build contexts; follow checklist patterns |

---

## 6.9 Recommended Two-Repo Architecture (App Team + Platform Team)

Use this operating model for your setup:

- **App repo (`opentelemetry-demo`)** owns source code and image CI
- **Infra repo (`devops-aks-project`)** owns Terraform, Helm values, deployment workflows, and approvals

High-level flow:

1. Developer merges code in app repo
2. App CI builds/scans images and pushes to ACR with immutable SHA tag (or digest)
3. App CI notifies infra repo (cross-repo workflow dispatch)
4. Infra CD runs with environment approval gate and deploys to AKS

### Why this is recommended

- Keeps clear ownership boundaries between application and platform teams
- Preserves audit trail and approval history in infra repo
- Reduces blast radius (app repo cannot directly mutate infra beyond allowed interface)
- Supports easy migration to GitOps later

### Phased rollout (recommended path)

#### Phase 1 - Basic (start here)

- App repo CI builds changed services under `src/`
- App repo pushes images to ACR on `main`
- App repo dispatches infra repo `cd-deploy.yml` with `image_tag`

This is the quickest path and matches your current Chapter 6 implementation.

#### Phase 2 - Promotion PR (next)

- App repo CI resolves immutable image digest after push
- App repo CI opens PR in infra repo updating image references
- Platform/release team reviews and merges PR
- Infra repo CD deploys approved digest

Why this is better:

- Deploys are tied to reviewed Git changes in infra repo
- Stronger traceability and rollback (revert promotion PR)
- Avoids drifting mutable tags

#### Phase 3 - GitOps (target)

- Flux watches infra repo desired state
- Promotion updates Git (manually or automated image update policy)
- Flux reconciles cluster from Git state

Why this is ideal at scale:

- Pull-based reconciliation and drift correction
- Strong separation of duties and compliance posture
- Clear environment promotion strategy via branches/folders

### Day-1 setup checklist for split repos

In **app repo**:

- Secrets: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `INFRA_REPO_DISPATCH_TOKEN`
- Variables: `ACR_NAME`, `INFRA_REPO_OWNER`, `INFRA_REPO_NAME`
- Workflow: `.github/workflows/ci-build-push.yml`

In **infra repo**:

- Workflow: `.github/workflows/cd-deploy.yml`
- Environment: `production` with required reviewers
- Variables: `RESOURCE_GROUP`, `AKS_CLUSTER_NAME`, `ACR_NAME`
- Cluster policy manifests: quotas/limits aligned with actual workload footprint

### Guardrails to keep from day 1

- Use OIDC (no static credentials)
- Pin action versions (prefer commit SHA pins over tags in production repos)
- Keep deployment approval gate in infra repo
- Prefer immutable image references for production promotion
- Keep app CI and infra CD logs/summaries as release evidence

---

## Summary Checklist

**Prerequisites:**
- [x] Azure infrastructure deployed (Terraform, Chapter 3)
- [x] Kubernetes namespaces, RBAC, Ingress, monitoring (Chapter 5)
- [x] Workload Identity setup (UAMI, federated credential, Key Vault access)
- [x] GitHub Actions secrets configured (AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID)
- [x] GitHub Actions variables configured (RESOURCE_GROUP, ACR_NAME, AKS_CLUSTER_NAME, etc.)

**Unified Terraform Workflow** (single `.github/workflows/terraform.yml`):
- [x] Job 1 — PR plan: `terraform plan` → comment on PR (for review)
- [x] Job 2 — Main plan: `terraform plan -out=tfplan` → upload artifact (on merge to main)
- [x] Job 3 — Main apply: download artifact → `terraform apply tfplan` (approval gate before apply)
- [x] Ensures apply uses exact reviewed plan (no re-plan at apply time)

**CI/CD Workflows:**
- [x] CI build workflow — detects changed services, builds & pushes to ACR
- [x] CD deploy workflow — Helm upgrade with approval gate
- [x] Image vulnerability scanning with Trivy
- [x] OIDC authentication (no stored credentials)
- [x] Smoke test after deploy
- [x] Deployment summary report

**Optional Enhancements:**
- [x] HPA deployment (frontend auto-scaling, 1-6 replicas, 65% CPU target)
- [x] Resource quotas (namespace-level CPU, memory, pod limits)

**Next:** [07 — Observability](07-observability.md)
