# Section 6 — GitHub Actions CI/CD Pipelines

> Build a complete CI/CD automation pipeline using GitHub Actions. Personal GitHub repo → Azure infrastructure + AKS deployments using OIDC (no stored credentials).

---

## 6.1 Pipeline Overview

```
Developer pushes code
        │
        ├── Pull Request ──────▶ [terraform-plan.yml]
        │                            ├─ Terraform fmt/validate
        │                            ├─ Terraform plan (output in PR comment)
        │                            └─ Image vulnerability scan
        │
        └── Merge to main ────▶ [ci-build-push.yml]
                                     ├─ Build changed service images
                                     ├─ Push to ACR (tagged with git SHA)
                                     └─ Trigger ──▶ [cd-deploy.yml]
                                                        ├─ Requires approval (production)
                                                        ├─ Helm upgrade
                                                        └─ Health check
```

---

## 6.2 Workflow: Terraform Plan on PRs

`.github/workflows/terraform-plan.yml`

```yaml
name: Terraform Plan

on:
  pull_request:
    branches: [main]
    paths:
      - 'terraform/**'

permissions:
  id-token: write      # Required for OIDC
  contents: read
  pull-requests: write # To comment the plan on the PR

env:
  TF_VERSION: "1.9.8"
  ARM_CLIENT_ID: ${{ secrets.AZURE_CLIENT_ID }}
  ARM_TENANT_ID: ${{ secrets.AZURE_TENANT_ID }}
  ARM_SUBSCRIPTION_ID: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
  ARM_USE_OIDC: "true"

jobs:
  terraform-plan:
    name: Terraform Plan
    runs-on: ubuntu-latest
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
        run: |
          terraform init \
            -backend-config="resource_group_name=${{ vars.RESOURCE_GROUP }}" \
            -backend-config="storage_account_name=${{ vars.TF_STORAGE_ACCOUNT }}" \
            -backend-config="container_name=${{ vars.TF_STATE_CONTAINER }}" \
            -backend-config="key=aks-project.tfstate"

      - name: Terraform Validate
        run: terraform validate

      - name: Terraform Plan
        id: plan
        run: terraform plan -out=tfplan -no-color
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
            *Pushed by: @${{ github.actor }}, Action: \`${{ github.event_name }}\`*`;

            github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: output
            })

      - name: Terraform Plan Status
        if: steps.plan.outcome == 'failure'
        run: exit 1
```

---

## 6.3 Workflow: Terraform Apply on Main Merge

`.github/workflows/terraform-apply.yml`

```yaml
name: Terraform Apply

on:
  push:
    branches: [main]
    paths:
      - 'terraform/**'
  workflow_dispatch:   # Allow manual trigger

permissions:
  id-token: write
  contents: read

env:
  TF_VERSION: "1.9.8"
  ARM_CLIENT_ID: ${{ secrets.AZURE_CLIENT_ID }}
  ARM_TENANT_ID: ${{ secrets.AZURE_TENANT_ID }}
  ARM_SUBSCRIPTION_ID: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
  ARM_USE_OIDC: "true"

jobs:
  terraform-apply:
    name: Terraform Apply
    runs-on: ubuntu-latest
    environment: production     # Requires manual approval!
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

      - name: Terraform Init
        run: |
          terraform init \
            -backend-config="resource_group_name=${{ vars.RESOURCE_GROUP }}" \
            -backend-config="storage_account_name=${{ vars.TF_STORAGE_ACCOUNT }}" \
            -backend-config="container_name=${{ vars.TF_STATE_CONTAINER }}" \
            -backend-config="key=aks-project.tfstate"

      - name: Terraform Apply
        run: terraform apply -auto-approve

      - name: Get Terraform Outputs
        id: tf_outputs
        run: |
          echo "aks_cluster=$(terraform output -raw aks_cluster_name)" >> $GITHUB_OUTPUT
          echo "acr_server=$(terraform output -raw acr_login_server)" >> $GITHUB_OUTPUT
```

---

## 6.4 Workflow: CI — Build & Push Images

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
          fetch-depth: 2

      - name: Detect changed service directories
        id: changes
        run: |
          if [ "${{ github.event.inputs.services }}" != "" ]; then
            # Manual trigger with specified services
            SERVICES=$(echo "${{ github.event.inputs.services }}" | tr ',' '\n' | jq -R -s -c 'split("\n")[:-1]')
          else
            # Detect from git diff
            CHANGED=$(git diff --name-only HEAD~1 HEAD | grep '^src/' | cut -d'/' -f2 | sort -u | jq -R -s -c 'split("\n")[:-1]')
            SERVICES=$CHANGED
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
    name: Trigger Deployment
    runs-on: ubuntu-latest
    needs: build-push
    if: github.ref == 'refs/heads/main' && needs.build-push.result == 'success'

    steps:
      - name: Trigger CD workflow
        uses: actions/github-script@v7
        with:
          script: |
            await github.rest.actions.createWorkflowDispatch({
              owner: context.repo.owner,
              repo: context.repo.repo,
              workflow_id: 'cd-deploy.yml',
              ref: 'main',
              inputs: {
                image_tag: context.sha.substring(0, 7)
              }
            });
```

---

## 6.5 Workflow: CD — Deploy to AKS

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
  4. Helm upgrade --atomic
     (auto-rollback on failure)
  5. Smoke test
  6. Summary report
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

---

## Summary Checklist

- [x] Terraform plan workflow — runs on PR
- [x] Terraform apply workflow — runs on merge (with approval)
- [x] CI build workflow — detects changed services, builds & pushes
- [x] CD deploy workflow — Helm upgrade with approval gate
- [x] Image vulnerability scanning with Trivy
- [x] OIDC authentication (no stored credentials)
- [x] Smoke test after deploy
- [x] Deployment summary report

**Next:** [07 — Observability](07-observability.md)
