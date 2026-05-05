# Section 4 — Containerization & ACR

> Fork the OpenTelemetry Demo, understand its microservices, build Docker images, and push them to Azure Container Registry (ACR).

---

## 4.1 About the OpenTelemetry Astronomy Shop

The OpenTelemetry Demo is a microservices e-commerce application (astronomy-themed online shop) with **15+ services** written in multiple languages — making it a realistic real-world example.

| Service | Language | Purpose |
|---------|---------|---------|
| frontend | TypeScript (Next.js) | Web storefront |
| frontendproxy | Envoy | API gateway |
| cartservice | C# | Shopping cart |
| checkoutservice | Go | Order processing |
| currencyservice | C++ | Currency conversion |
| emailservice | Ruby | Email notifications |
| featureflagservice | Elixir | Feature flags |
| frauddetectionservice | Kotlin (JVM) | Fraud detection |
| loadgenerator | Python | Traffic simulation |
| paymentservice | JavaScript (Node.js) | Payment processing |
| productcatalogservice | Go | Product catalog |
| quoteservice | PHP | Quote calculation |
| recommendationservice | Python | Product recommendations |
| shippingservice | Rust | Shipping calculation |
| adservice | Java | Ad serving |
| otelcollector | - | Telemetry pipeline |

---

## 4.2 Fork the OpenTelemetry Demo

```bash
# Option 1: Fork via GitHub CLI
gh repo fork open-telemetry/opentelemetry-demo \
  --clone \
  --fork-name opentelemetry-demo

cd opentelemetry-demo

# Option 2: Fork manually at:
# https://github.com/open-telemetry/opentelemetry-demo/fork
# Then clone your fork
git clone https://github.com/<your-username>/opentelemetry-demo.git
cd opentelemetry-demo
```

> **Why fork?** You need to modify the Dockerfiles and Helm values to push to your ACR instead of the public registry. Forking lets you customize while staying in sync with upstream.

---

## 4.3 Understanding the Existing Dockerfiles

The demo already has Dockerfiles for each service. Let's inspect a few:

```bash
# See all Dockerfiles
find src -name "Dockerfile" | sort

# Look at the frontend
cat src/frontend/Dockerfile

# Look at a Go service
cat src/checkoutservice/Dockerfile

# Look at a Java service
cat src/adservice/Dockerfile
```

Each service's Dockerfile follows multi-stage build best practices:
1. **Build stage** — compile/build the application
2. **Runtime stage** — minimal image with only the binary

---

## 4.4 Local Build Test (Single Service)

Test that you can build locally before automating:

```bash
# Build the product catalog service
docker build \
  -t acrdevopsproject.azurecr.io/productcatalogservice:local \
  src/productcatalogservice/

# Verify
docker images | grep productcatalogservice

# Quick smoke test
docker run --rm -p 3550:3550 \
  acrdevopsproject.azurecr.io/productcatalogservice:local &
sleep 5
curl -s http://localhost:3550/  || echo "Service started (check logs)"
docker stop $(docker ps -q --filter ancestor=acrdevopsproject.azurecr.io/productcatalogservice:local)
```

---

## 4.5 Push Images to ACR

### Login to ACR

```bash
# Login using Azure CLI managed identity (no password needed)
az acr login --name acrdevopsproject

# Verify login
docker info | grep Registry
```

### Build and Push All Services

```bash
#!/bin/bash
# scripts/build-push-all.sh

set -euo pipefail

ACR_NAME="acrdevopsproject"
ACR_SERVER="${ACR_NAME}.azurecr.io"
TAG="${1:-latest}"

# Services and their Dockerfile locations
declare -A SERVICES=(
  ["frontend"]="src/frontend"
  ["cartservice"]="src/cartservice/src"
  ["checkoutservice"]="src/checkoutservice"
  ["currencyservice"]="src/currencyservice"
  ["emailservice"]="src/emailservice"
  ["featureflagservice"]="src/featureflagservice"
  ["frauddetectionservice"]="src/frauddetectionservice"
  ["loadgenerator"]="src/loadgenerator"
  ["paymentservice"]="src/paymentservice"
  ["productcatalogservice"]="src/productcatalogservice"
  ["quoteservice"]="src/quoteservice"
  ["recommendationservice"]="src/recommendationservice"
  ["shippingservice"]="src/shippingservice"
  ["adservice"]="src/adservice"
  ["otelcollector"]="src/otelcollector"
)

echo "=== Building and pushing all services ==="
echo "ACR: $ACR_SERVER"
echo "Tag: $TAG"
echo ""

for SERVICE in "${!SERVICES[@]}"; do
  CONTEXT="${SERVICES[$SERVICE]}"
  IMAGE="${ACR_SERVER}/${SERVICE}:${TAG}"

  echo "--- Building: $SERVICE ---"

  docker build \
    --platform linux/amd64 \
    -t "$IMAGE" \
    "$CONTEXT"

  echo "--- Pushing: $SERVICE ---"
  docker push "$IMAGE"

  echo "✅ $SERVICE pushed: $IMAGE"
  echo ""
done

echo "=== All services pushed to ACR ==="
```

```bash
chmod +x scripts/build-push-all.sh
az acr login --name acrdevopsproject
./scripts/build-push-all.sh v1.0.0
```

---

## 4.6 Verify Images in ACR

```bash
# List all repositories
az acr repository list --name acrdevopsproject --output table

# List tags for a specific image
az acr repository show-tags \
  --name acrdevopsproject \
  --repository frontend \
  --output table

# Check image details
az acr manifest list-metadata \
  --registry acrdevopsproject \
  --name frontend \
  --output table
```

---

## 4.7 Image Naming Strategy

Use a consistent image tagging strategy for CI/CD:

| Tag | When Used | Example |
|-----|----------|---------|
| `latest` | Local dev only | `acr.io/frontend:latest` |
| `<git-sha>` | CI builds (immutable) | `acr.io/frontend:abc1234` |
| `v<semver>` | Release tags | `acr.io/frontend:v1.2.0` |
| `<branch>-<sha>` | Feature branches | `acr.io/frontend:feat-cart-abc1234` |

In GitHub Actions:
```yaml
- name: Get image tag
  id: meta
  run: |
    SHA=$(echo ${{ github.sha }} | cut -c1-7)
    echo "tag=$SHA" >> $GITHUB_OUTPUT
    echo "full_tag=${{ vars.ACR_NAME }}.azurecr.io/frontend:$SHA" >> $GITHUB_OUTPUT
```

---

## 4.8 ACR Security Best Practices

```bash
# Enable vulnerability scanning (Defender for Containers)
az acr update --name acrdevopsproject \
  --resource-group rg-devops-aks

# Enable content trust (image signing) — optional for learning
az acr config content-trust update \
  --registry acrdevopsproject \
  --status enabled

# View scan results
az acr manifest list-metadata \
  --registry acrdevopsproject \
  --name frontend

# Cleanup old images (run periodically)
az acr run \
  --registry acrdevopsproject \
  --cmd "acr purge --filter 'frontend:.*' --untagged --ago 7d" \
  /dev/null
```

---

## 4.9 Docker Compose for Local Development

The OpenTelemetry demo has a `docker-compose.yml` for running everything locally. Use it to verify everything works before deploying to AKS:

```bash
# From the opentelemetry-demo repo root
docker compose up --build -d

# Wait 2-3 minutes for all services to start
docker compose ps

# Access the frontend
# http://localhost:8080

# Access Grafana
# http://localhost:8080/grafana

# Access Jaeger
# http://localhost:8080/jaeger

# Stop
docker compose down
```

---

## 4.10 Using ACR Build Tasks (Alternative to Local Build)

Instead of building locally, you can use ACR Build Tasks — useful when your local machine doesn't have enough RAM:

```bash
# Build frontend in the cloud using ACR Tasks
az acr build \
  --registry acrdevopsproject \
  --image frontend:v1.0.0 \
  --file src/frontend/Dockerfile \
  .

# This builds in Azure — uses cloud compute, not your laptop!
```

---

## Summary Checklist

- [x] OpenTelemetry Demo forked to personal GitHub
- [x] All service Dockerfiles reviewed
- [x] Local build test passed (at least one service)
- [x] Docker Compose verified locally
- [x] ACR login configured
- [x] All images built and pushed to ACR with version tags
- [x] Images verified in ACR portal/CLI
- [x] Image tagging strategy decided (git SHA)

**Next:** [05 — Kubernetes Manifests](05-kubernetes-manifests.md)
