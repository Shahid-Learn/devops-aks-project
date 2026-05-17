# Section 9 — Learning Notes & Key Concepts

> A study guide and reference for all key concepts in this project. Use this to review and reinforce your understanding.

---

## 9.1 Kubernetes Core Concepts (AKS Context)

### Cluster Architecture

```
Control Plane (managed by Azure)
  ├── API Server      ← All kubectl commands go here
  ├── etcd            ← Cluster state database
  ├── Scheduler       ← Decides which node to run a pod on
  └── Controller Mgr  ← Reconciles desired vs actual state

Worker Nodes (you pay for these)
  ├── kubelet         ← Node agent — runs pods as instructed
  ├── kube-proxy      ← Network rules for services
  └── container runtime (containerd)
```

### Key K8s Objects

| Object | Purpose | Analogy |
|--------|---------|---------|
| Pod | Smallest deployable unit (1+ containers) | A process |
| Deployment | Manages pod replicas + rolling updates | Process manager |
| Service | Stable network endpoint for pods | Load balancer |
| Ingress | HTTP routing rules (host/path based) | Nginx virtual host |
| ConfigMap | Non-sensitive configuration | Config file |
| Secret | Sensitive data (base64 encoded) | Secrets vault |
| Namespace | Logical cluster isolation | Folder |
| HPA | Horizontal Pod Autoscaler | Auto-scaling rule |
| PVC | Persistent Volume Claim | Disk mount request |
| ServiceAccount | Pod's identity in the cluster | Service user |

---

## 9.2 AKS-Specific Concepts

### Node Pools

AKS supports multiple node pools — groups of VMs with the same configuration:

```
System Node Pool
  ├── Purpose: Run critical system pods (CoreDNS, metrics-server)
  ├── Taint: CriticalAddonsOnly=true:NoSchedule
  └── Always-on (cannot scale to 0)

User/App Node Pool  
  ├── Purpose: Run your application workloads
  ├── Can be scaled to 0 when not in use
  └── Supports spot instances (cheaper, but can be evicted)
```

### Managed Identity vs Service Principal

AKS uses managed identities instead of credentials:
- **System-assigned** — tied to the AKS resource lifecycle
- **User-assigned** — independent, can be shared across resources
- **Kubelet identity** — the node's identity, used to pull images from ACR

### Workload Identity

Allows Kubernetes pods to authenticate to Azure services without credentials:

```
Pod → Requests Azure token
  → Uses Kubernetes service account token
  → Azure validates against federated credential
  → Azure returns short-lived access token
  → Pod uses token to access Key Vault / Storage / etc.
```

---

## 9.3 Terraform Key Concepts

### State Management

Terraform state tracks what resources exist in the real world:

```
terraform.tfstate (stored in Azure Blob Storage)
  ├── Maps Terraform resource names → Azure resource IDs
  ├── Stores current configuration
  └── Enables drift detection (plan shows changes)

# NEVER manually edit state
# NEVER commit state to git (contains sensitive data)
# ALWAYS use remote state backend for team/CI use
```

### Terraform Workflow

```bash
terraform init     # Download providers, connect to backend
terraform plan     # Preview changes (no changes made)
terraform apply    # Make changes
terraform destroy  # Delete all managed resources
terraform output   # Show output values
terraform state    # Inspect/manage state file
```

### Import vs Create

```bash
# If a resource already exists in Azure and you want Terraform to manage it:
terraform import azurerm_resource_group.main /subscriptions/.../resourceGroups/rg-name

# After import, Terraform knows about the resource without creating it
```

### Modules

Modules = reusable Terraform code packages:

```hcl
module "aks" {
  source = "./modules/aks"   # Local module
  # OR
  source = "registry.terraform.io/Azure/aks/azurerm"  # Public registry
  
  # Pass inputs
  cluster_name = "my-cluster"
}

# Module outputs become available as:
module.aks.cluster_name
module.aks.oidc_issuer_url
```

---

## 9.4 GitHub Actions Key Concepts

### Workflow Triggers

```yaml
on:
  push:                      # On git push
    branches: [main]
    paths: ['src/**']        # Only when src/ changes

  pull_request:              # On PR events
    branches: [main]

  workflow_dispatch:         # Manual trigger (with optional inputs)
    inputs:
      environment:
        type: choice
        options: [staging, production]

  schedule:                  # Cron schedule
    - cron: '0 6 * * 1'     # Every Monday at 6 AM
```

### Environments & Protection Rules

```yaml
jobs:
  deploy:
    environment: production   # References GitHub Environment setting
    # Production environment can have:
    # - Required reviewers (manual approval)
    # - Wait timer (delay before deployment)
    # - Allowed branches (only main can deploy to prod)
```

### Secrets vs Variables

| Type | Masked in logs | Example |
|------|---------------|---------|
| `secrets.NAME` | ✅ Yes | `AZURE_CLIENT_ID`, passwords |
| `vars.NAME` | ❌ No | `AKS_CLUSTER_NAME`, region |

### OIDC Authentication Flow

```
1. GitHub generates OIDC JWT: {
     "sub": "repo:myorg/myrepo:ref:refs/heads/main",
     "iss": "https://token.actions.githubusercontent.com",
     "aud": "api://AzureADTokenExchange"
   }

2. azure/login@v2 sends this to:
   POST https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token
   {
     "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
     "client_assertion": "<github-jwt>",
     "client_id": "<your-sp-app-id>"
   }

3. Azure verifies: "Is the federated credential for this subject configured?"
   YES → Returns access_token (1 hour expiry)

4. Workflow uses access_token for all Azure CLI / Terraform operations
```

---

## 9.5 Docker & Container Concepts

### Multi-Stage Builds (used in OTel demo)

```dockerfile
# Stage 1: Build
FROM golang:1.22 AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download              # Cache dependency layer
COPY . .
RUN CGO_ENABLED=0 go build -o /server .

# Stage 2: Runtime (much smaller image)
FROM gcr.io/distroless/static:nonroot
COPY --from=builder /server /server
USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/server"]
```

Benefits:
- Final image contains only the binary (not the Go toolchain)
- Smaller attack surface
- Faster pulls

### Docker Layer Caching

```
Each instruction in Dockerfile = one layer
Layers are cached — unchanged layers are reused

COPY go.mod go.sum ./    ← Layer 1 (cached if go.mod unchanged)
RUN go mod download      ← Layer 2 (cached if layer 1 unchanged)
COPY . .                 ← Layer 3 (changes on every code change)
RUN go build             ← Layer 4 (rebuilds when layer 3 changes)

ORDER MATTERS: Put rarely-changing instructions first!
```

---

## 9.6 OpenTelemetry Concepts

### The Three Pillars

```
Traces  = "What happened and in what order?"
          Distributed request tracking across services
          → Stored in Jaeger

Metrics = "How often? How much? How fast?"
          Counters, gauges, histograms
          → Stored in Prometheus

Logs    = "What did each service say?"
          Structured event records
          → Stored in Loki (or stdout/CloudWatch/etc.)
```

### OTel Data Model

```
Trace
  └── Span (one operation in one service)
        ├── TraceID      (groups spans across services)
        ├── SpanID       (unique to this span)
        ├── ParentSpanID (links to calling span)
        ├── Name         ("HTTP GET /products")
        ├── StartTime / EndTime
        ├── Attributes   (key-value metadata)
        └── Events       (timestamped annotations)
```

### Context Propagation

This is how trace context moves across service boundaries:

```
Frontend calls ProductCatalog via HTTP:
  Request headers include:
    traceparent: 00-<traceId>-<spanId>-01
    tracestate: <vendor-specific>

ProductCatalog reads these headers → creates child span → trace is connected
```

---

## 9.7 Networking in Kubernetes

### Service Types

```
ClusterIP  (default) — only accessible inside cluster
NodePort             — accessible via <nodeIP>:<port> (dev only)
LoadBalancer         — creates Azure Load Balancer (has public IP)
ExternalName         — DNS alias to external service
```

### How Ingress Works

```
User → DNS → Azure Load Balancer → NGINX Ingress Controller
                                          │
                              Rules match host/path
                                          │
                              Route to ClusterIP Service
                                          │
                              Forward to Pod
```

### Network Policies (Azure CNI)

```yaml
# Allow only ingress-nginx to reach frontend
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-ingress-to-frontend
  namespace: otel-demo
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: frontend
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
```

---

## 9.8 Security Best Practices Applied in This Project

| Practice | Implementation |
|---------|---------------|
| No long-lived credentials | OIDC federation for GitHub → Azure |
| Least privilege | SP has Contributor on RG only (not subscription) |
| No admin ACR creds | AcrPull via managed identity |
| No imagePullSecrets | AKS-to-ACR role assignment |
| Image scanning | Trivy in CI pipeline |
| K8s secrets from Key Vault | CSI Driver + Workload Identity |
| Container non-root | OTel demo images use nonroot user |
| Network isolation | Separate namespaces per workload type |
| TF state encryption | Azure Storage with versioning |

---

## 9.9 Common kubectl Commands Reference

```bash
# Cluster
kubectl get nodes -o wide
kubectl top nodes
kubectl describe node <name>

# Pods
kubectl get pods -n <namespace> -o wide
kubectl describe pod <name> -n <ns>
kubectl logs <pod> -n <ns> -f --tail=100
kubectl exec -it <pod> -n <ns> -- /bin/sh
kubectl delete pod <pod> -n <ns>    # Pod restarts via Deployment

# Deployments
kubectl get deployments -n <ns>
kubectl rollout status deployment/<name> -n <ns>
kubectl rollout history deployment/<name> -n <ns>
kubectl rollout undo deployment/<name> -n <ns>
kubectl scale deployment/<name> --replicas=3 -n <ns>

# Services & Ingress
kubectl get services -n <ns>
kubectl get ingress -n <ns>
kubectl port-forward svc/<name> 8080:80 -n <ns>

# Context
kubectl config get-contexts
kubectl config use-context <name>
kubectl config current-context

# Debugging
kubectl get events -n <ns> --sort-by='.lastTimestamp'
kubectl auth can-i create pods --namespace <ns>
kubectl get resourcequota -n <ns>
```

---

## 9.10 Helm Reference

```bash
# Repo management
helm repo add <name> <url>
helm repo update
helm repo list

# Chart exploration
helm search repo <term>
helm show chart <repo/chart>
helm show values <repo/chart> > values.yaml

# Install / upgrade
helm install <release> <chart> -n <ns> --create-namespace
helm upgrade --install <release> <chart> -n <ns> -f values.yaml
helm upgrade --install <release> <chart> --set key=value

# Inspect
helm list -n <ns>
helm status <release> -n <ns>
helm get values <release> -n <ns>
helm history <release> -n <ns>

# Rollback / uninstall
helm rollback <release> <revision> -n <ns>
helm uninstall <release> -n <ns>

# Dry run / debug
helm upgrade --install <release> <chart> --dry-run --debug
helm template <release> <chart> -f values.yaml   # Render manifests without deploying
```

---

## 9.11 Useful Resources

| Topic | Resource |
|-------|---------|
| AKS Documentation | https://learn.microsoft.com/en-us/azure/aks/ |
| Terraform AzureRM Provider | https://registry.terraform.io/providers/hashicorp/azurerm |
| GitHub Actions Documentation | https://docs.github.com/en/actions |
| OpenTelemetry Demo | https://opentelemetry.io/docs/demo/ |
| Helm Documentation | https://helm.sh/docs/ |
| Prometheus PromQL | https://prometheus.io/docs/prometheus/latest/querying/basics/ |
| Grafana Dashboards | https://grafana.com/grafana/dashboards/ |
| Trivy (Image Scanner) | https://aquasecurity.github.io/trivy/ |
| OIDC in GitHub Actions | https://docs.github.com/en/actions/security-guides/automatic-token-authentication |

---

## 9.12 Architecture Decision Records (ADR)

Brief notes on key architectural decisions made in this project:

### ADR-001: OIDC vs Service Principal Password for GitHub Actions
- **Decision:** Use OIDC federated credentials
- **Reason:** No credentials to rotate, more secure, Microsoft recommended
- **Trade-off:** Slightly more complex initial setup

### ADR-002: System + App Node Pools vs Single Pool
- **Decision:** Separate system and app node pools
- **Reason:** Prevents app workloads from evicting critical system pods; app pool can scale to 0
- **Trade-off:** Slightly more complex configuration

### ADR-003: Helm for OTel Demo vs Raw Manifests
- **Decision:** Use official Helm chart
- **Reason:** Easier upgrades, community maintained, supports value overrides
- **Trade-off:** Less visibility into individual manifests (use `helm template` to inspect)

### ADR-004: Basic ACR SKU
- **Decision:** Basic ACR for learning
- **Reason:** Cost — Basic is ~$5/month vs Standard ~$20/month
- **Trade-off:** Lower throughput, geo-replication not available, fewer retention policies
- **Note:** Upgrade to Standard for production

### ADR-005: Azure Storage for Terraform State
- **Decision:** Azure Blob Storage backend
- **Reason:** Supports locking (prevents concurrent applies), integrates with OIDC auth
- **Trade-off:** Requires pre-creating the storage account manually before first `terraform init`

---

## 9.13 Platform Engineer vs Application Team — Role Boundaries

> Understanding where your responsibility ends and the application team's begins is critical for effective collaboration and interview scenarios.

### The Mental Model

```
Application Team owns:          Platform/DevOps Engineer owns:
────────────────────────        ──────────────────────────────────
WHAT the service does           HOW the service runs
Business logic                  Container build pipeline
API contracts                   Kubernetes manifests
Service dependencies            Network policies, ingress
Dockerfile                      Base image standards/scanning
Unit/integration tests          Deployment pipeline, smoke tests
Feature flags                   Resource limits, autoscaling
Database schema                 Secrets management (Key Vault)
```

### Per-Service: What a Platform Engineer Must Know

| Topic | Must Know | Why |
|---|---|---|
| Port the service listens on | ✅ | K8s Service definition, ingress routing |
| Health check endpoints | ✅ | Liveness/readiness probes — pod won't start without these |
| Environment variables needed | ✅ | Must inject via ConfigMap or Secret |
| CPU/memory usage profile | ✅ | Set resource requests/limits correctly |
| Startup time | ✅ | Set `initialDelaySeconds` on probes correctly |
| External dependencies (DBs, queues) | ✅ | Affects startup order, network policies |
| Internal business logic | ❌ | Not your concern |
| Database schema design | ❌ | Not your concern |
| Algorithm implementation | ❌ | Not your concern |

### Responsibility Matrix (RACI)

| Task | Platform Eng | App Team |
|---|---|---|
| Write Dockerfile | Consult | **Responsible** |
| Define base image standards | **Responsible** | Informed |
| Build & push image in CI | **Responsible** | Informed |
| Image vulnerability scanning | **Responsible** | Informed |
| Write K8s manifests / Helm values | **Responsible** | Consulted |
| Define resource requests/limits | **Responsible** (with input) | Consulted |
| Set health check endpoints | Informed | **Responsible** |
| Application crashes (bug) | Informed | **Responsible** |
| Pod OOMKilled (out of memory) | **Responsible** | Consulted |
| Service can't reach another service | **Responsible** | Informed |
| CI/CD pipeline setup | **Responsible** | Informed |
| Observability dashboards | **Responsible** | Consulted |

### Common Interview Scenario

> "A pod keeps restarting. How do you debug it?"

Platform engineer approach:
```bash
kubectl describe pod <pod-name>    # look at Events section — OOMKilled? probe failing?
kubectl logs <pod-name> --previous # logs from the crashed container
kubectl top pod <pod-name>         # CPU/memory usage

# If OOMKilled → increase memory limit (your fix)
# If probe failing → wrong port or endpoint (coordinate with app team)
# If CrashLoopBackOff with app error → escalate to app team
```

---

## 9.14 Dockerfile Deep Dive — Interview Reference

> DevOps engineers are expected to containerize applications. This section covers everything you need to write, review, and optimise Dockerfiles.

### Dockerfile Instruction Reference

```dockerfile
# ── BASE IMAGE ──────────────────────────────────────────────────────────────
FROM node:20-alpine          # Use specific version tags, never 'latest' in prod
                             # alpine = smaller (5MB vs 900MB for full debian)

# ── METADATA ────────────────────────────────────────────────────────────────
LABEL maintainer="team@example.com"
LABEL version="1.0"

# ── ENVIRONMENT VARIABLES ───────────────────────────────────────────────────
ENV NODE_ENV=production      # Available at build time AND runtime
ARG BUILD_VERSION            # Build-time only — not available in running container

# ── WORKING DIRECTORY ───────────────────────────────────────────────────────
WORKDIR /app                 # Creates dir if not exists, sets context for RUN/COPY

# ── COPY FILES ──────────────────────────────────────────────────────────────
COPY package*.json ./        # Copy package files FIRST (cache optimisation)
RUN npm ci --only=production # Install deps (cached as long as package.json unchanged)
COPY . .                     # Copy source AFTER deps (cache busted on every change)

# ── RUN COMMANDS ────────────────────────────────────────────────────────────
RUN npm run build            # Each RUN = one layer; chain with && to reduce layers
RUN rm -rf /tmp/*            # Clean up in SAME RUN as the command that created files

# ── SECURITY: Non-root user ──────────────────────────────────────────────────
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
USER appuser                 # Never run as root in production

# ── EXPOSE ──────────────────────────────────────────────────────────────────
EXPOSE 3000                  # Documentation only — does NOT actually open port
                             # K8s Service/ingress controls actual port access

# ── HEALTHCHECK ─────────────────────────────────────────────────────────────
HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
  CMD wget -qO- http://localhost:3000/healthz || exit 1

# ── ENTRYPOINT vs CMD ───────────────────────────────────────────────────────
ENTRYPOINT ["node"]          # Fixed — cannot be overridden without --entrypoint flag
CMD ["server.js"]            # Default args — easily overridden: docker run img other.js
# Together: runs "node server.js"
# Best practice: use ENTRYPOINT for the executable, CMD for default args
```

### Multi-Stage Build Patterns

**Pattern 1: Build then Runtime (most common)**
```dockerfile
# Stage 1: Build
FROM golang:1.22 AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o /server .

# Stage 2: Minimal runtime
FROM gcr.io/distroless/static:nonroot   # Google's minimal image — no shell, no package manager
COPY --from=builder /server /server
USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/server"]

# Result: Go toolchain (~1GB) stays in builder stage
#         Final image is just the binary (~10MB)
```

**Pattern 2: Test + Build + Runtime**
```dockerfile
FROM node:20-alpine AS deps
WORKDIR /app
COPY package*.json ./
RUN npm ci

FROM deps AS test
COPY . .
RUN npm test           # Fails build if tests fail

FROM deps AS builder
COPY . .
RUN npm run build

FROM node:20-alpine AS runtime
WORKDIR /app
COPY --from=builder /app/dist ./dist
COPY --from=deps /app/node_modules ./node_modules
USER node
CMD ["node", "dist/index.js"]
```

### Layer Caching — Why Order Matters

```
WRONG (slow CI):              RIGHT (fast CI — cache deps layer):
────────────────              ───────────────────────────────────
COPY . .                      COPY package*.json ./
RUN npm install               RUN npm install       ← cached until package.json changes
RUN npm build                 COPY . .              ← only this layer+ rebuild on code change
                              RUN npm build
```

Every code change invalidates all layers below the changed `COPY` — put stable things (dependencies) before volatile things (source code).

### .dockerignore — Always Include

```
node_modules/        # Never copy — must be installed inside container
.git/                # Build history not needed
*.md                 # Documentation
.env                 # Never bake secrets into images!
dist/                # Build artifacts (will be rebuilt)
coverage/            # Test coverage reports
*.log
.DS_Store
Thumbs.db
```

### Security Best Practices

| Practice | Why |
|---|---|
| Pin base image versions (`node:20.11-alpine`) | Reproducible builds, no surprise changes |
| Use non-root user | Limits blast radius if container is compromised |
| Use distroless or alpine | Smaller attack surface — fewer binaries an attacker can use |
| Never `COPY . .` before handling secrets | Risk of baking secrets into image layers |
| Scan images (`trivy image myapp:latest`) | Catch CVEs before pushing to registry |
| Don't use `latest` tag in prod | Unpredictable — pin to digest or version |
| Multi-stage builds | Ensure build tools not in final image |

### Interview Questions & Answers

**Q: What's the difference between CMD and ENTRYPOINT?**
> `ENTRYPOINT` defines the executable — not easily overridden. `CMD` provides default arguments that are easily replaced. Best practice: use both together — `ENTRYPOINT` for the binary, `CMD` for default args.

**Q: How do you reduce Docker image size?**
> Multi-stage builds, alpine/distroless base images, chain RUN commands with `&&`, use `.dockerignore`, remove caches in the same RUN layer that created them (`apt-get install && rm -rf /var/lib/apt/lists/*`).

**Q: How do you handle secrets in Docker?**
> Never bake into image. Use environment variables injected at runtime, K8s Secrets mounted as volumes, or a secrets manager (Azure Key Vault, HashiCorp Vault). For build-time secrets use `--secret` flag with BuildKit (`RUN --mount=type=secret`).

**Q: What is a distroless image?**
> An image with no shell, no package manager, no OS utilities — just the runtime and your app. Harder to exploit if compromised because there's no `bash` or `curl` for an attacker to use.

**Q: How does layer caching work in CI?**
> Each Dockerfile instruction is a layer. If the instruction and all previous layers are unchanged, Docker reuses the cached layer. To maximise cache hits: copy dependency files first, install deps, then copy source code.

---

## 9.15 Real Lessons from This Project (Troubleshooting Log)

These are actual problems encountered and resolved during setup. Each is a realistic interview scenario.

### L-001: Kubernetes version rejected by AKS

- **Symptom:** `terraform apply` failed — version `1.15` not available in `swedencentral`
- **Root cause:** Outdated default in variable definition
- **Fix:** Set `kubernetes_version = "1.35.3"` (run `az aks get-versions --location swedencentral -o table` to find valid versions)
- **Lesson:** Always check supported K8s versions in your target region before provisioning

### L-002: AKS creation failed — service CIDR overlap

- **Symptom:** `ServiceCidrOverlapExistingSubnetsCidr` error during `terraform apply`
- **Root cause:** Default `service_cidr` was `10.0.0.0/16` — same as the VNet address space
- **Fix:** Changed service CIDR to `10.1.0.0/16` (must not overlap VNet or any subnet)
- **Lesson:** Plan your CIDR ranges before provisioning: VNet → Subnets → Service CIDR must all be non-overlapping

### L-003: kubectl returned Forbidden despite cluster running

- **Symptom:** `kubectl get nodes` returned `Forbidden: User cannot list resource nodes`
- **Root cause:** AKS had `azure_rbac_enabled = true` but no role assignment for the user
- **Fix:**
  ```bash
  az role assignment create \
    --role "Azure Kubernetes Service RBAC Cluster Admin" \
    --assignee <your-user-object-id> \
    --scope <aks-resource-id>
  ```
- **Lesson:** With Azure RBAC on AKS, cluster admin is NOT automatic — you must explicitly assign it, even to the owner

### L-004: Role assigned but kubectl still Forbidden

- **Symptom:** Role assignment created but `kubectl` still returned Forbidden
- **Root cause:** `kubelogin` cached an old token without the cluster-admin permission
- **Fix:** `kubelogin remove-cache-dir` then re-fetch credentials
- **Lesson:** After RBAC changes, always clear the kubelogin token cache — tokens are valid for up to 1 hour

### L-005: WSL calling Windows az.exe instead of Linux az

- **Symptom:** `az aks get-credentials` wrote kubeconfig to `C:\Users\...` instead of `~/.kube/config`
- **Root cause:** WSL interop was calling the Windows `az.exe` binary
- **Fix:** `export PATH=/usr/bin:$PATH` then reinstall Linux az CLI via `curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash`
- **Lesson:** In WSL, always confirm `which az` points to `/usr/bin/az` (Linux) not the Windows path

### L-006: WSL2 DNS failure — IPv6 nameservers unreachable

- **Symptom:** `nslookup management.azure.com` failed with `network unreachable` against `fec0:0:0:ffff::1`
- **Root cause:** WSL auto-generated `resolv.conf` from Windows DHCP included IPv6-only DNS servers that WSL cannot reach
- **Fix:**
  ```bash
  # Disable auto-generation
  sudo tee /etc/wsl.conf >/dev/null <<'EOF'
  [network]
  generateResolvConf = false
  EOF

  # Set working nameservers
  sudo tee /etc/resolv.conf >/dev/null <<'EOF'
  nameserver 1.1.1.1
  nameserver 8.8.8.8
  search sas.local net.sas.se net.sas.dk net.sas.no
  EOF
  ```
  Then `wsl --shutdown` from PowerShell and reopen WSL.
- **Lesson:** WSL DNS auto-config is unreliable in corporate environments. Always verify with `nslookup management.azure.com` before starting cloud work.

### L-007: Docker daemon exposing insecure TCP endpoint

- **Symptom:** `sudo dockerd &` started with deprecation warning: `API accessible on http://127.0.0.1:2375 without encryption`
- **Root cause:** `/etc/docker/daemon.json` had `tcp://127.0.0.1:2375` in `hosts`, and `~/.zshrc` had `DOCKER_HOST=tcp://127.0.0.1:2375`
- **Fix:**
  1. Remove TCP host from `/etc/docker/daemon.json` — keep only `unix:///run/docker.sock`
  2. Remove `DOCKER_HOST` line from `~/.zshrc`
  3. `unset DOCKER_HOST` in current shell
  4. Restart Docker: `sudo service docker start`
- **Lesson:** Docker TCP without TLS gives root-equivalent access to any local script. Use Unix socket only for local development.

### L-008: Corporate TLS interception (Zscaler) breaking Docker builds

- **Symptom:** `docker build` failed with TLS certificate errors; `az acr login` failed
- **Root cause:** Zscaler intercepts HTTPS and re-signs with corporate CA. Build containers only have the base image CA bundle, not the corporate root
- **Fix:** See [PRE-ACR-BUILD-CHECKLIST.md](PRE-ACR-BUILD-CHECKLIST.md) for full stage-specific patterns:
  - Non-Java: append cert to `/etc/ssl/certs/ca-certificates.crt`
  - Node.js: also set `NODE_EXTRA_CA_CERTS`
  - Java: `keytool` import to JVM trust store
- **Lesson:** Corporate TLS interception affects **local machines and self-hosted runners only** — GitHub-hosted runners bypass corporate proxy

### L-009: ACR connection required Tailscale (but shouldn't)

- **Symptom:** `az acr login` only worked when Tailscale VPN was active
- **Root cause:** WSL DNS was broken (L-006 above) — without Tailscale's DNS resolver `100.100.100.100`, no Azure endpoints resolved
- **Fix:** Fix WSL DNS (L-006) — ACR is a public endpoint and does not require VPN
- **Lesson:** If a public cloud endpoint only works with VPN, suspect DNS rather than network routing

### L-010: Frontend container has no shell (distroless)

- **Symptom:** `docker compose run --service-ports frontend` returned `exec: no such file or directory`
- **Root cause:** Frontend runtime image is distroless — no shell binary at all
- **Fix:** Use `--entrypoint sh` with a non-distroless build stage, or use the WSL2 stable command with named volumes:
  ```bash
  docker compose run --rm \
    --publish 8080:8080 \
    --volume frontend_node_modules:/app/node_modules \
    --volume frontend_next:/app/.next \
    --entrypoint sh frontend
  ```
- **Lesson:** Distroless images are great for production security but require a separate dev/builder stage for interactive work
