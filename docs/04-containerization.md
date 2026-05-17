# Section 4 — Containerization & ACR

> Fork the OpenTelemetry Demo, understand its microservices, build Docker images, and push them to Azure Container Registry (ACR).

> Need deeper hands-on Dockerfile and Compose understanding first? See [Section 10 — Containerization and Docker Compose Learning Lab](10-containerization-docker-compose-learning-lab.md).

---

## 4.1 About the OpenTelemetry Astronomy Shop

The OpenTelemetry Demo is a microservices e-commerce application (astronomy-themed online shop) with custom application services, official infrastructure services, and client apps.

### Custom Application Services (build from source with Dockerfiles)

| Service | Language | Purpose |
|---------|---------|---------|
| frontend | TypeScript (Next.js) | Web storefront |
| frontendproxy | Envoy | API gateway / reverse proxy |
| cartservice | C# (.NET) | Shopping cart |
| checkoutservice | Go | Order processing |
| currencyservice | C++ | Currency conversion |
| emailservice | Ruby | Email notifications |
| featureflagservice | Elixir | Feature flag UI (flagd) |
| frauddetectionservice | Kotlin (JVM) | Fraud detection |
| loadgenerator | Python | Traffic simulation |
| paymentservice | JavaScript (Node.js) | Payment processing |
| productcatalogservice | Go | Product catalog |
| productreviewsservice | Python | Product reviews |
| quoteservice | PHP | Shipping quote calculation |
| recommendationservice | Python | Product recommendations |
| shippingservice | Rust | Shipping calculation |
| adservice | Java | Ad serving |
| accountingservice | C# (.NET) | Order accounting (Kafka consumer) |
| llmservice | Python | LLM-based shopping assistant |
| imageprovider | nginx | Static product image serving |

### Infrastructure Services (official pre-built images, no custom Dockerfile)

| Service | Official Image | Role |
|---------|----------------|------|
| otelcollector | otel/opentelemetry-collector-contrib (Go) | Receives and routes all telemetry |
| jaeger | jaegertracing/all-in-one (Go) | Distributed trace visualisation |
| prometheus | prom/prometheus (Go) | Metrics scraping and storage |
| grafana | grafana/grafana (Go) | Dashboards (traces, metrics, logs) |
| postgresql | postgres | Database for cart/product data |
| flagd | ghcr.io/open-feature/flagd (Go) | Feature flag evaluation daemon |

### Client App

| Service | Image | Role |
|---------|-------|------|
| react-native-app | - | Mobile client app (not a backend service) |

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

### Start Docker Engine in Local WSL (when Docker Desktop integration is disabled)

If `az acr login` fails with `Cannot connect to the Docker daemon`, start/check Docker inside WSL first:

Security baseline for local WSL Docker:

- Use Unix socket only: `/run/docker.sock`
- Do not expose Docker API on `tcp://127.0.0.1:2375` without TLS
- Do not set `DOCKER_HOST=tcp://127.0.0.1:2375`

```bash
# Confirm Docker CLI and daemon status
which docker
docker --version
docker info
```

If `docker info` cannot reach the daemon, start it manually in WSL:

```bash
# Start daemon for current shell session
sudo service docker start

# Verify daemon is reachable
docker info
docker ps
```

Verify no insecure TCP listener is active:

```bash
echo "DOCKER_HOST=${DOCKER_HOST:-<empty>}"
ss -lntp | grep 2375 || echo "OK: no TCP 2375 listener"
```

If `service` is unavailable in your distro, run Docker daemon directly:

```bash
sudo dockerd > /tmp/dockerd.log 2>&1 &
docker info
```

Optional (avoid `sudo` for docker commands):

```bash
sudo usermod -aG docker $USER
newgrp docker
docker ps
```

After Docker is running, continue with ACR login.

### Login to ACR

```bash
# Login using Azure CLI managed identity (no password needed)
az acr login --name acrdevopsproject

# Verify login
docker info | grep Registry
```

### Corporate TLS / Zscaler Note (WSL2)

If `az acr login`, `curl`, or `docker build` fails with TLS/certificate errors in a corporate network, do a quick trust preflight before large builds:

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates openssl curl
sudo update-ca-certificates

export REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

# TLS path check (401 is expected and healthy for an unauthenticated registry ping)
curl -Iv https://acrdevopsprojectd1e51ba4.azurecr.io/v2/
```

> [!NOTE]
> In corporate environments with TLS interception, WSL tools and Docker build containers may have different trust chains. See [PRE-ACR-BUILD-CHECKLIST.md](PRE-ACR-BUILD-CHECKLIST.md) for full root-cause explanation and stage-specific certificate injection patterns.

### Build and Push All Services

```bash
#!/bin/bash
# scripts/build-push-all.sh

set -euo pipefail

ACR_NAME="acrdevopsproject"
ACR_SERVER="${ACR_NAME}.azurecr.io"
TAG="${1:-latest}"

# Custom application services and their Dockerfile locations
declare -A SERVICES=(
  ["frontend"]="src/frontend"
  ["frontendproxy"]="src/frontendproxy"
  ["cartservice"]="src/cartservice/src"
  ["checkoutservice"]="src/checkoutservice"
  ["currencyservice"]="src/currencyservice"
  ["emailservice"]="src/emailservice"
  ["featureflagservice"]="src/featureflagservice"
  ["frauddetectionservice"]="src/frauddetectionservice"
  ["loadgenerator"]="src/loadgenerator"
  ["paymentservice"]="src/paymentservice"
  ["productcatalogservice"]="src/productcatalogservice"
  ["productreviewsservice"]="src/productreviewsservice"
  ["quoteservice"]="src/quoteservice"
  ["recommendationservice"]="src/recommendationservice"
  ["shippingservice"]="src/shippingservice"
  ["adservice"]="src/adservice"
  ["accountingservice"]="src/accountingservice/src"
  ["llmservice"]="src/llmservice"
  ["imageprovider"]="src/imageprovider"
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
| `<git-sha>-<service>` | CI builds (immutable) | `acr.io/otel-demo:52a8a76-frontend` |
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

# Future hardening: use Private Endpoint + Private DNS Zone
# for private data-plane access to ACR from AKS and build agents

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

Frontend service context:

- Client-side application layer: renders OTEL webstore UI.
- API layer: exposes REST endpoints and connects to backend services.

Local frontend development command:

```bash
# From repo root
docker compose run --service-ports \
  -e NODE_ENV=development \
  --volume $(pwd)/src/frontend:/app \
  --volume $(pwd)/pb:/app/pb \
  --user node \
  --entrypoint sh frontend

# Inside container
npm run dev
```

> [!NOTE]
> This shell-based flow requires a non-distroless/dev-capable image target. If frontend runtime is distroless, the shell command will fail unless a local compose override switches frontend build target to a builder/dev stage. After adding override, run `docker compose build frontend` once.

Docker Desktop / WSL2 stable command (recommended when Turbopack/.next write permissions are problematic):

```bash
docker compose run --rm \
  --publish 8080:8080 \
  -e NODE_ENV=development \
  --volume $(pwd)/src/frontend:/app \
  --volume $(pwd)/pb:/app/pb \
  --volume frontend_node_modules:/app/node_modules \
  --volume frontend_next:/app/.next \
  --entrypoint sh frontend

# inside the container
npm ci --no-audit --no-fund
npm run dev -- --webpack -p 8080
```

Then open `http://localhost:8080/`.

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
