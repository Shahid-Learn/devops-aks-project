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
