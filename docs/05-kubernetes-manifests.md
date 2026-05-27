# Section 5 — Kubernetes Manifests & Helm Deployment

> Deploy the OpenTelemetry Astronomy Shop to AKS using Helm. Set up namespaces, RBAC, Ingress, and configure the app to pull images from ACR.

## Index

- [5.1 Namespace Strategy](#51-namespace-strategy)
- [5.2 Install NGINX Ingress Controller](#52-install-nginx-ingress-controller)
- [5.3 Deploy OpenTelemetry Demo with Helm](#53-deploy-opentelemetry-demo-with-helm)
- [5.4 Install Prometheus + Grafana (kube-prometheus-stack)](#54-install-prometheus--grafana-kube-prometheus-stack)
- [5.5 Access the Applications](#55-access-the-applications)
- [5.6 ConfigMaps & Secrets](#56-configmaps--secrets)
- [5.7 Resource Quotas](#57-resource-quotas)
- [5.8 HorizontalPodAutoscaler (Optional)](#58-horizontalpodautoscaler-optional)
- [5.9 Deploy Prometheus + Grafana (kube-prometheus-stack)](#59-deploy-prometheus--grafana-kube-prometheus-stack)
- [5.10 Deployment Verification Script](#510-deployment-verification-script)

### Section Note

For monitoring deployment and troubleshooting guidance, use section 5.9 as the latest operational reference.

---

## 5.1 Namespace Strategy

### What is a Kubernetes namespace and why do we need them?

A **namespace** is a logical isolation boundary inside a Kubernetes cluster. Think of it as separate "environments" or "workspaces" that share the same cluster but keep resources (pods, services, secrets) isolated.

**Benefits:**
- **Workload isolation** — If monitoring pods crash, they don't affect the app
- **RBAC policies** — Restrict who/what can access each namespace
- **Resource quotas** — Limit CPU/memory per namespace (prevents one app from starving others)
- **Secrets isolation** — Database credentials in `monitoring` namespace are invisible to `otel-demo`
- **Multi-team support** — Teams can work in separate namespaces without stepping on each other

### Our namespace strategy

```
Namespace              Purpose                                      Why separate?
─────────────────────  ─────────────────────────────────────────    ───────────────────────────────────
otel-demo              OpenTelemetry Astronomy Shop (15+ services)  App business logic — the main workload
monitoring             Prometheus, Grafana, Alertmanager            Observability stack — monitor the app
ingress-nginx          NGINX Ingress Controller                      Cluster routing — manages all ingress
cert-manager           TLS certificate automation (optional)         Security concern — separate from app
```

**Example:** If your app logs go haywire and fill all storage, the monitoring stack (in separate namespace) can still scrape metrics and alert you. If both were mixed, the app crash could take down monitoring too.

---

### Create the namespaces

**Prerequisites:**
- AKS cluster is running: `kubectl cluster-info`
- You have cluster admin access: `kubectl auth can-i create namespaces`

**Step 1: Apply the namespace manifests**

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: otel-demo
  labels:
    app.kubernetes.io/managed-by: helm      # Standard label — tells tools this NS is managed by Helm
    project: devops-aks-project               # Custom label — helps organize resources
---
apiVersion: v1
kind: Namespace
metadata:
  name: monitoring
  labels:
    project: devops-aks-project
---
apiVersion: v1
kind: Namespace
metadata:
  name: ingress-nginx
  labels:
    project: devops-aks-project
EOF
```

**Step 2: Verify creation**

```bash
kubectl get namespaces

# Expected output (all three should show STATUS: Active):
# NAME              STATUS   AGE
# otel-demo         Active   15s
# monitoring        Active   14s
# ingress-nginx     Active   14s
# default           Active   5m
# kube-system       Active   5m
# kube-public       Active   5m
```

**Step 3: (Optional) List resources in each namespace**

```bash
# Check how many pods are in each (should be 0 at this point)
kubectl get pods -n otel-demo
kubectl get pods -n monitoring
kubectl get pods -n ingress-nginx
```

---

### Troubleshooting

| Error | Cause | Solution |
|---|---|---|
| `Unable to connect to the server` | AKS cluster not running or kubeconfig invalid | Run `az aks get-credentials --resource-group rg-devops-aks --name aks-devops-project` |
| `Error from server (Forbidden)` | Missing permissions to create namespaces | Your user account needs cluster admin role; contact cluster owner |
| `Namespace ... already exists` | You ran the command twice | This is fine — `kubectl apply` is idempotent; running again does nothing |

---

## 5.2 Install NGINX Ingress Controller

```bash
# Add Helm repo
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

# Install with Azure Load Balancer
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-health-probe-request-path"=/healthz \
  --set controller.service.externalTrafficPolicy=Local \
  --wait

# Get the public IP (takes 2-3 min for Azure to assign)
kubectl get service ingress-nginx-controller -n ingress-nginx -w

# Save the external IP
INGRESS_IP=$(kubectl get service ingress-nginx-controller \
  -n ingress-nginx \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Ingress IP: $INGRESS_IP"
```

---

## 5.3 Deploy OpenTelemetry Demo with Helm

The OpenTelemetry project provides an official Helm chart. We'll customize it to pull images from **our ACR** instead of the public OTel registry.

### Why use our ACR instead of the public registry?

| | Public OTel Registry | Our ACR |
|---|---|---|
| Default Helm chart behaviour | ✅ Pulls from `ghcr.io/open-telemetry/demo` | ❌ Must override values |
| Works without any setup | ✅ Yes | Requires ACR + AKS role assignment |
| Used in production / CI | ❌ No — not your registry | ✅ Yes — you control versions |
| Supports custom Dockerfile changes | ❌ No | ✅ Yes |
| Image tag is your git SHA | ❌ No | ✅ Yes (`52a8a76`) |

**Rule of thumb:** Use the public registry to get started quickly. Use your ACR once you want full control — custom builds, your own CI/CD pipeline, and no dependency on upstream availability.

Our images are already in ACR:
- Registry: `acrdevopsprojectd1e51ba4.azurecr.io`
- Repository: `otel-demo`
- Tag format: `<git-sha>-<service-name>` (e.g. `52a8a76-frontend`)
- AKS already has `AcrPull` permission via managed identity — no `imagePullSecrets` needed

### Step 1: Add the OTel Helm repo

```bash
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update

# Inspect the default values to understand the image override structure
helm show values open-telemetry/opentelemetry-demo > /tmp/otel-demo-defaults.yaml
cat /tmp/otel-demo-defaults.yaml | grep -A5 "image:"
```

### Step 2: Create Custom Values File

Create `k8s/otel-demo/values.yaml`.

The key override is `components.<serviceName>.image.repository` — each service needs its own
entry because our ACR uses per-service tags (`otel-demo:frontend-52a8a76`) rather than one tag per repo.

```bash
# Set your values
ACR="acrdevopsprojectd1e51ba4.azurecr.io"
TAG="52a8a76"   # git SHA from the build that pushed to ACR
```

```yaml
# k8s/otel-demo/values.yaml
#
# Overrides for the official opentelemetry-demo Helm chart.
# Images are pulled from ACR — all 22 custom images were pushed with git SHA 52a8a76.
#
# Tag format: <git-sha>-<service-name>  e.g. 52a8a76-frontend
# Verify tags: az acr repository show-tags --name acrdevopsprojectd1e51ba4 --repository otel-demo --output tsv | sort

components:

  frontend:
    image:
      repository: acrdevopsprojectd1e51ba4.azurecr.io/otel-demo
      tag: "52a8a76-frontend"
      pullPolicy: IfNotPresent
    resources:
      requests:
        memory: "250Mi"
        cpu: "100m"
      limits:
        memory: "400Mi"

  frontendProxy:
    image:
      repository: acrdevopsprojectd1e51ba4.azurecr.io/otel-demo
      tag: "52a8a76-frontend-proxy"
      pullPolicy: IfNotPresent
    ingress:
      enabled: true
      annotations:
        kubernetes.io/ingress.class: nginx
        nginx.ingress.kubernetes.io/ssl-redirect: "false"
      hosts:
        - host: ""          # Uses IP directly — fine for learning
          paths:
            - path: /
              pathType: Prefix

  cartService:
    image:
      repository: acrdevopsprojectd1e51ba4.azurecr.io/otel-demo
      tag: "52a8a76-cart"
      pullPolicy: IfNotPresent
    resources:
      requests:
        memory: "160Mi"
        cpu: "100m"
      limits:
        memory: "250Mi"

  checkoutService:
    image:
      repository: acrdevopsprojectd1e51ba4.azurecr.io/otel-demo
      tag: "52a8a76-checkout"
      pullPolicy: IfNotPresent
    resources:
      requests:
        memory: "150Mi"
        cpu: "100m"
      limits:
        memory: "250Mi"

  productCatalogService:
    image:
      repository: acrdevopsprojectd1e51ba4.azurecr.io/otel-demo
      tag: "52a8a76-product-catalog"
      pullPolicy: IfNotPresent
    resources:
      requests:
        memory: "60Mi"
        cpu: "50m"
      limits:
        memory: "120Mi"

  productReviewsService:
    image:
      repository: acrdevopsprojectd1e51ba4.azurecr.io/otel-demo
      tag: "52a8a76-product-reviews"
      pullPolicy: IfNotPresent

  recommendationService:
    image:
      repository: acrdevopsprojectd1e51ba4.azurecr.io/otel-demo
      tag: "52a8a76-recommendation"
      pullPolicy: IfNotPresent

  adService:
    image:
      repository: acrdevopsprojectd1e51ba4.azurecr.io/otel-demo
      tag: "52a8a76-ad"
      pullPolicy: IfNotPresent
    resources:
      requests:
        memory: "300Mi"
        cpu: "100m"
      limits:
        memory: "500Mi"

  paymentService:
    image:
      repository: acrdevopsprojectd1e51ba4.azurecr.io/otel-demo
      tag: "52a8a76-payment"
      pullPolicy: IfNotPresent

  shippingService:
    image:
      repository: acrdevopsprojectd1e51ba4.azurecr.io/otel-demo
      tag: "52a8a76-shipping"
      pullPolicy: IfNotPresent

  emailService:
    image:
      repository: acrdevopsprojectd1e51ba4.azurecr.io/otel-demo
      tag: "52a8a76-email"
      pullPolicy: IfNotPresent

  currencyService:
    image:
      repository: acrdevopsprojectd1e51ba4.azurecr.io/otel-demo
      tag: "52a8a76-currency"
      pullPolicy: IfNotPresent

  loadGenerator:
    image:
      repository: acrdevopsprojectd1e51ba4.azurecr.io/otel-demo
      tag: "52a8a76-load-generator"
      pullPolicy: IfNotPresent

  fraudDetectionService:
    image:
      repository: acrdevopsprojectd1e51ba4.azurecr.io/otel-demo
      tag: "52a8a76-fraud-detection"
      pullPolicy: IfNotPresent

  quoteService:
    image:
      repository: acrdevopsprojectd1e51ba4.azurecr.io/otel-demo
      tag: "52a8a76-quote"
      pullPolicy: IfNotPresent

  accountingService:
    image:
      repository: acrdevopsprojectd1e51ba4.azurecr.io/otel-demo
      tag: "52a8a76-accounting"
      pullPolicy: IfNotPresent

  featureFlagService:
    image:
      repository: acrdevopsprojectd1e51ba4.azurecr.io/otel-demo
      tag: "52a8a76-flagd-ui"
      pullPolicy: IfNotPresent

  llmService:
    image:
      repository: acrdevopsprojectd1e51ba4.azurecr.io/otel-demo
      tag: "52a8a76-llm"
      pullPolicy: IfNotPresent

  imageProvider:
    image:
      repository: acrdevopsprojectd1e51ba4.azurecr.io/otel-demo
      tag: "52a8a76-image-provider"
      pullPolicy: IfNotPresent

  # kafka and opensearch have custom images in OTel demo (pushed to ACR)
  kafka:
    image:
      repository: acrdevopsprojectd1e51ba4.azurecr.io/otel-demo
      tag: "52a8a76-kafka"
      pullPolicy: IfNotPresent

  opensearch:
    image:
      repository: acrdevopsprojectd1e51ba4.azurecr.io/otel-demo
      tag: "52a8a76-opensearch"
      pullPolicy: IfNotPresent

  telemetryDocs:
    image:
      repository: acrdevopsprojectd1e51ba4.azurecr.io/otel-demo
      tag: "52a8a76-telemetry-docs"
      pullPolicy: IfNotPresent

# Infrastructure services (jaeger, prometheus, grafana, postgresql, flagd)
# use their official public images — no overrides needed here.
```

### Step 3: Deploy with Helm

```bash
# Deploy
helm upgrade --install otel-demo open-telemetry/opentelemetry-demo \
  --namespace otel-demo \
  --values k8s/otel-demo/values.yaml \
  --wait \
  --timeout 10m

# Verify all pods are running
kubectl get pods -n otel-demo

# Check services
kubectl get services -n otel-demo

# Check ingress
kubectl get ingress -n otel-demo
```

### 5.3.1 Real Incident: Helm timeout with partially healthy release

During deployment we hit:

```bash
Error: context deadline exceeded
```

but most pods were already running. This is expected when `--wait` is enabled and even one pod remains unhealthy.

#### What happened

- `frontend-proxy` entered `CrashLoopBackOff`
- `flagd` pod was not fully ready because `flagd-ui` sidecar image could not be pulled
- Ingress returned `503 Service Temporarily Unavailable`

#### Root cause

1. `frontend-proxy` custom ACR image started but failed runtime validation (Envoy bootstrap error).
2. Global `default.image.repository` pointed to ACR (`acr.../otel-demo`), so sidecars without explicit override also used ACR.
3. `flagd` is a multi-container pod (main `flagd` + `flagd-ui` sidecar). The sidecar needed tag `2.2.0-flagd-ui`; if that tag is missing in ACR, pod readiness fails.

#### Fix that worked

- Use known-good upstream image for `frontend-proxy`:

```yaml
components:
  frontend-proxy:
    imageOverride:
      repository: ghcr.io/open-telemetry/demo
      tag: "2.2.0-frontend-proxy"
```

- Use official `flagd` image for main container:

```yaml
components:
  flagd:
    imageOverride:
      repository: ghcr.io/open-feature/flagd
      tag: "v0.12.9"
```

- Re-run Helm with a safer timeout for first-time installs:

```bash
helm upgrade --install otel-demo open-telemetry/opentelemetry-demo \
  --namespace otel-demo \
  --values k8s/otel-demo/values.yaml \
  --wait \
  --timeout 15m
```

Result: release became `STATUS: deployed`, all pods `Running`, ingress returned HTTP `200`.

#### Fast debugging checklist

```bash
# 1) Which pods are failing?
kubectl get pods -n otel-demo

# 2) Why are they failing?
kubectl describe pod <pod> -n otel-demo | sed -n '/Events:/,$p'
kubectl logs <pod> -n otel-demo --all-containers=true --tail=200

# 3) Which images are actually used by a pod?
kubectl get pod <pod> -n otel-demo -o jsonpath="{range .spec.containers[*]}{.name}{' => '}{.image}{'\\n'}{end}"

# 4) What values did Helm apply?
helm get values otel-demo -n otel-demo
```

---

## 5.4 Install Prometheus + Grafana (kube-prometheus-stack)

### Understanding the stack architecture

**kube-prometheus-stack** is a single Helm chart that deploys multiple components that work together:

```
┌─────────────────────────────────────────────────────────────────┐
│  kube-prometheus-stack (Single Helm Release)                    │
│                                                                  │
│  ┌──────────────────┐  ┌─────────────────┐  ┌──────────────┐  │
│  │  Prometheus      │  │  Grafana        │  │ Alertmanager │  │
│  │  ────────────    │  │  ────────       │  │ ────────────── │  │
│  │ • Scrapes metrics│  │ • Visualizes    │  │ • Manages      │  │
│  │ • Stores data    │  │   metrics       │  │   alerts       │  │
│  │ • Rules engine   │  │ • Dashboards    │  │ • Routes to    │  │
│  │ • Alert trigger  │  │ • Admin panel   │  │   channels     │  │
│  └─────────┬────────┘  └────────┬────────┘  └────────┬───────┘  │
│            │                    │                    │           │
│            └────────────────────┼────────────────────┘           │
│                                 │                                │
│                          (connected via config)                  │
│                                 │                                │
│  ┌──────────────────┐  ┌──────────────────┐                    │
│  │  Node Exporter   │  │  Kube-State-Metrics │                 │
│  │  ──────────────  │  │  ────────────────    │                 │
│  │ Exposes node     │  │ Exposes cluster    │                 │
│  │ metrics (CPU,    │  │ metrics (pod count,│                 │
│  │ memory, disk)    │  │ replica status)    │                 │
│  └──────────────────┘  └──────────────────┘                    │
│                                 │                                │
│                    (Prometheus scrapes these)                   │
└─────────────────────────────────────────────────────────────────┘
```

**Key relationships:**
1. **Prometheus** pulls metrics from Node Exporter and Kube-State-Metrics every `scrapeInterval` (default 30s)
2. **Prometheus** evaluates alert rules; if threshold crossed, fires alert to **Alertmanager**
3. **Alertmanager** groups, deduplicates, and routes alerts (can send to email, Slack, etc.)
4. **Grafana** queries Prometheus database to display dashboards and visualizations
5. All four services store configuration and data in Kubernetes using ConfigMaps, Secrets, and PersistentVolumes

### Why they're in one values file

Because they're all part of a single Helm chart (`kube-prometheus-stack`), their config lives in one `values.yaml`. The chart template uses `{{ if .Values.prometheus.enabled }}` logic to deploy or skip each component. This pattern is common in "stack" charts.

**If they were separate charts**, you'd have:
- `prometheus-values.yaml`
- `grafana-values.yaml`
- `alertmanager-values.yaml`

But managing three separate Helm releases is more work. The single-chart approach is simpler for learning and smaller deployments.

### Add repo and create values file

```bash
# Add repo
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Create values file for Prometheus stack
cat > k8s/monitoring/prometheus-values.yaml <<'EOF'
# k8s/monitoring/prometheus-values.yaml
#
# This file configures the kube-prometheus-stack Helm chart.
# It includes config for: Prometheus, Grafana, Alertmanager, Node Exporter, Kube-State-Metrics

# ─────────────────────────────────────────────────────────────────────────────
# GRAFANA — Web UI for visualizing metrics
# ─────────────────────────────────────────────────────────────────────────────
grafana:
  enabled: true
  adminPassword: "admin-change-me"   # Change this! Or use a K8s secret
  ingress:
    enabled: true
    annotations:
      kubernetes.io/ingress.class: nginx
    hosts:
      - ""    # Will use IP-based access; no hostname needed for learning

# ─────────────────────────────────────────────────────────────────────────────
# PROMETHEUS — Metrics database + alert rule engine
# ─────────────────────────────────────────────────────────────────────────────
prometheus:
  prometheusSpec:
    # Scrape interval: How often Prometheus polls metric endpoints
    scrapeInterval: 30s
    
    # Tell Prometheus about the OTel Collector in the otel-demo namespace
    # This config scrapes metrics from pods annotated with:
    #   prometheus.io/scrape: "true"
    additionalScrapeConfigs:
      - job_name: otel-collector
        kubernetes_sd_configs:
          - role: pod
            namespaces:
              names:
                - otel-demo
        relabel_configs:
          # Only scrape pods with this annotation set to "true"
          - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
            action: keep
            regex: true

# ─────────────────────────────────────────────────────────────────────────────
# ALERTMANAGER — Alert routing and deduplication
# ─────────────────────────────────────────────────────────────────────────────
# When Prometheus rules fire, alerts are sent here.
# Alertmanager groups them, deduplicates, and routes to destinations.
alertmanager:
  enabled: true
  # Default config: alerts are silenced (no email/Slack integration yet)
  # To add routes, create a Kubernetes Secret and reference it here

# ─────────────────────────────────────────────────────────────────────────────
# DATA RETENTION — Keep metrics for 15 days; use managed-csi storage class
# ─────────────────────────────────────────────────────────────────────────────
prometheus:
  prometheusSpec:
    retention: 15d   # Delete metrics older than 15 days
    
    # PersistentVolumeClaim for Prometheus database
    # Without this, metrics are lost when the pod restarts
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: managed-csi   # Azure managed disk
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 20Gi   # 20 GB is typical for 15 days of metrics

# ─────────────────────────────────────────────────────────────────────────────
# GRAFANA PERSISTENCE — Save dashboards to disk
# ─────────────────────────────────────────────────────────────────────────────
grafana:
  persistence:
    enabled: true
    storageClassName: managed-csi
    size: 5Gi   # 5 GB for dashboard definitions and provisioning data

EOF

# Install
helm upgrade --install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values k8s/monitoring/prometheus-values.yaml \
  --wait \
  --timeout 10m

# Verify
kubectl get pods -n monitoring
kubectl get services -n monitoring
```

### Verify the components are running and connected

**Check all pods deployed:**

```bash
kubectl get pods -n monitoring

# You should see:
# - kube-prometheus-stack-prometheus-* (Prometheus server)
# - kube-prometheus-stack-grafana-* (Grafana UI)
# - kube-prometheus-stack-alertmanager-* (Alert router)
# - kube-prometheus-stack-operator-* (Manages Prometheus/Alertmanager resources)
# - kube-prometheus-stack-kube-state-metrics-* (Cluster metrics exporter)
# - kube-prometheus-stack-prometheus-node-exporter-* (Node metrics exporter)
```

**Verify Prometheus is scraping metrics:**

```bash
# Port-forward to Prometheus
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 &

# Open browser: http://localhost:9090
# Click "Status" → "Targets" to see all scrape targets
# Should see: node-exporter, kube-state-metrics, otel-collector (if configured)
```

**Verify Grafana can read from Prometheus:**

```bash
# Get Grafana admin password
kubectl get secret -n monitoring kube-prometheus-stack-grafana \
  -o jsonpath="{.data.admin-password}" | base64 -d ; echo

# Port-forward to Grafana
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80 &

# Open browser: http://localhost:3000
# Login: admin / <password-from-above>
# Click Configuration → Data Sources → Prometheus
# Should show "Data source is working" (green checkmark)
```

**Check Prometheus configuration includes OTel Collector:**

```bash
# Access Prometheus web UI at http://localhost:9090
# Click "Status" → "Configuration"
# Look for "otel-collector" job_name in the YAML
# Should list pods from otel-demo namespace
```

### Data flow summary

```
Node Exporter (CPU, memory, disk)
         ↓
Prometheus scrapes every 30s
         ↓
Prometheus stores data (local disk)
         ↓
Prometheus evaluates alert rules
         ↓
Alertmanager (if rules fire)
         ↓
Grafana queries Prometheus dashboard data ← (User visits Grafana to see graphs)
```

**In your case with OTel Collector:**

```
OTel Collector (exporters: OpenTelemetry Demo services)
         ↓
Prometheus scrapes /metrics endpoint
         ↓
Grafana displays "OpenTelemetry Demo" dashboard
         ↓
User sees: request latency, error rates, throughput
```

---

## 5.5 Access the Applications

```bash
# Get Ingress IP
INGRESS_IP=$(kubectl get service ingress-nginx-controller \
  -n ingress-nginx \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

echo "=== Application URLs ==="
echo "OTel Astronomy Shop:  http://$INGRESS_IP"
echo "Grafana:              http://$INGRESS_IP/grafana  (or port-forward)"
echo "Jaeger:               http://$INGRESS_IP/jaeger   (or port-forward)"

# Port-forward as alternative
kubectl port-forward -n otel-demo svc/otel-demo-frontendproxy 8080:8080 &
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80 &

echo "Shop: http://localhost:8080"
echo "Grafana: http://localhost:3000  (admin/admin-change-me)"
```

---

## 5.6 ConfigMaps & Secrets

### Why Do We Need ConfigMaps and Secrets?

Kubernetes runs **containerized applications** — but containers are **immutable**. Once built, you can't change code without rebuilding the image. However, **configuration changes** (database URLs, feature flags, credentials) happen frequently.

**ConfigMaps** and **Secrets** solve this by separating **configuration from container images**:

| Aspect | Container Image | ConfigMap / Secret |
|--------|---|---|
| **Changes** | Rebuild entire image | Update directly in cluster |
| **Size** | Large (~100MB+) | Small (a few KB) |
| **Redeployment** | Required (new image) | None (pod reads updated values) |
| **Frequency** | Rare (new app version) | Often (config tuning, credentials rotation) |
| **Built into image** | Yes | No — injected at runtime |

### ConfigMaps vs Secrets: When to Use Each

| Use Case | ConfigMap | Secret | Reason |
|----------|-----------|--------|--------|
| **Database URL** | ✅ | ❌ | Non-sensitive, same across environments |
| **Database Password** | ❌ | ✅ | Sensitive — should be encrypted at rest |
| **Feature flags** | ✅ | ❌ | Non-sensitive config |
| **API keys** | ❌ | ✅ | Sensitive — must be protected |
| **Prometheus scrape intervals** | ✅ | ❌ | Non-sensitive config |
| **TLS certificates** | ❌ | ✅ | Cryptographic material — must be protected |
| **Grafana admin password** | ❌ | ✅ | Sensitive — auto-generated by Helm |
| **Log level (DEBUG/INFO/ERROR)** | ✅ | ❌ | Non-sensitive behavior flag |

### Real Examples in This Project

#### ConfigMap Example: Prometheus Configuration

Prometheus needs to know **which services to scrape** (job targets). Rather than hardcoding this in the Prometheus binary, we inject it as a ConfigMap:

```yaml
# Example (stored in etcd, not in container image)
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-config
  namespace: monitoring
data:
  prometheus.yml: |
    global:
      scrape_interval: 30s
    scrape_configs:
      - job_name: 'otel-collector'
        kubernetes_sd_configs:
          - role: pod
            namespaces:
              names: ['otel-demo']
```

**Benefit:** Change scrape targets without rebuilding Prometheus image. Prometheus pod auto-reloads configuration.

#### Secret Example: Grafana Admin Password

The kube-prometheus-stack Helm chart auto-generates a random admin password and stores it as a Secret:

```bash
# Query the secret (base64 encoded)
kubectl -n monitoring get secret kube-prometheus-stack-grafana \
  -o jsonpath="{.data.admin-password}" | base64 -d

# Secret is stored in etcd, encrypted if enabled
# Pod mounts it as an environment variable at runtime
```

**Benefit:** 
- Credentials never appear in container images (not in container registry)
- Can be rotated without rebuilding images
- Kubernetes can encrypt them at rest (etcd encryption)

#### ConfigMap Example: OTel Collector Configuration

The OTel collector in `otel-demo` namespace uses a ConfigMap for its receiver/exporter configuration:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-collector-config
  namespace: otel-demo
data:
  config.yaml: |
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318
    exporters:
      prometheus:
        endpoint: "0.0.0.0:8888"
    service:
      pipelines:
        metrics:
          receivers: [otlp]
          exporters: [prometheus]
```

### How Pods Access ConfigMaps and Secrets

**Method 1: Environment Variables**
```yaml
env:
  - name: DB_PASSWORD
    valueFrom:
      secretKeyRef:
        name: db-secret
        key: password
  - name: LOG_LEVEL
    valueFrom:
      configMapKeyRef:
        name: app-config
        key: log-level
```

**Method 2: Volume Mounts** (files in pod filesystem)
```yaml
volumes:
  - name: config-volume
    configMap:
      name: app-config
  - name: secret-volume
    secret:
      secretName: db-secret
containers:
  - name: app
    volumeMounts:
      - name: config-volume
        mountPath: /etc/config      # /etc/config/* contains ConfigMap data
      - name: secret-volume
        mountPath: /etc/secrets     # /etc/secrets/* contains Secret data
```

### Storage Layer: etcd

All ConfigMaps and Secrets are stored in **etcd** (Kubernetes' database):

```
┌─────────────────────────┐
│  Kubernetes API Server  │
│  kubectl create secret  │
└────────────┬────────────┘
             │
    ┌────────▼────────┐
    │  etcd Database  │
    │  (Sensitive!)   │
    └────────┬────────┘
             │
    ┌────────▼────────────────┐
    │  Pod Mounts at Runtime  │
    │  via Volume/Env Var     │
    └─────────────────────────┘
```

**Security considerations:**
- etcd stores Secrets in plaintext by default (encrypt at rest recommended)
- Anyone with API access can read Secrets via `kubectl get secret`
- Restrict RBAC: `kubectl create rolebinding ... --verb=get,list,watch --resource=secrets`

### Best Practices

1. **Never hardcode secrets in code or container images**
   ```dockerfile
   # ❌ BAD
   ENV DB_PASSWORD=admin123
   
   # ✅ GOOD
   # (leave empty — inject via Secret at runtime)
   ```

2. **Use descriptive names**
   ```bash
   # ❌ BAD
   kubectl create secret generic secret1 --from-literal=x=y
   
   # ✅ GOOD
   kubectl create secret generic otel-demo-db-credentials \
     --from-literal=username=admin \
     --from-literal=password=$(openssl rand -base64 32)
   ```

3. **Separate by namespace**
   ```bash
   # otel-demo namespace has its own secrets
   # monitoring namespace has its own secrets
   kubectl -n otel-demo get secrets
   kubectl -n monitoring get secrets
   ```

4. **Use external secret management for production**
   - Azure Key Vault (demonstrated below)
   - AWS Secrets Manager
   - HashiCorp Vault
   - Sealed Secrets

---

### Option 1: Simple Secrets (Development Only)

For learning/testing, store secrets directly in Kubernetes:

```bash
# Create a secret
kubectl -n otel-demo create secret generic database-config \
  --from-literal=username=admin \
  --from-literal=password=your-secure-password

# List secrets
kubectl -n otel-demo get secrets

# View secret (base64 encoded for protection)
kubectl -n otel-demo get secret database-config -o yaml

# Reference in pod
kubectl -n otel-demo set env deployment/otel-demo-cartservice \
  --from=secret/database-config
```

---

### Option 2: Azure Key Vault Integration (Production)

For sensitive credentials, integrate with **Azure Key Vault** using the **Secrets Store CSI Driver**:

#### Step 1: Install the Secrets Store CSI Driver

```bash
# Add Helm repo
helm repo add csi-secrets-store-provider-azure \
  https://azure.github.io/secrets-store-csi-driver-provider-azure/charts
helm repo update

# Install provider
helm upgrade --install azure-csi-secrets \
  csi-secrets-store-provider-azure/csi-secrets-store-provider-azure \
  --namespace kube-system \
  --set syncSecret.enabled=true
```

#### Step 2: Create a SecretProviderClass

This tells Kubernetes which secrets to fetch from Key Vault:

```yaml
# k8s/secrets/secret-provider.yaml
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: azure-keyvault-secrets
  namespace: otel-demo
spec:
  provider: azure
  # Optionally sync to Kubernetes Secret (for backward compatibility)
  secretObjects:
    - secretName: app-secrets
      type: Opaque
      data:
        - objectName: db-password
          key: password
  
  # Azure Key Vault configuration
  parameters:
    usePodIdentity: "false"
    useVMManagedIdentity: "true"      # Use AKS managed identity
    clientID: "<workload-identity-client-id>"
    keyvaultName: "<your-keyvault-name>"
    tenantId: "<your-tenant-id>"
    objects: |
      array:
        - |
          objectName: db-password
          objectType: secret
          objectVersion: ""
```

#### Step 3: Mount in Pod Spec

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: otel-demo-cartservice
  namespace: otel-demo
spec:
  template:
    spec:
      containers:
      - name: cartservice
        volumeMounts:
        - name: secrets
          mountPath: "/mnt/secrets"
          readOnly: true
      volumes:
      - name: secrets
        csi:
          driver: secrets-store.csi.k8s.io
          readOnly: true
          volumeAttributes:
            secretProviderClass: "azure-keyvault-secrets"
```

#### Step 4: Access in Application

```bash
# Inside pod, secrets appear as files:
cat /mnt/secrets/db-password
# Output: the actual password from Azure Key Vault
```

**Benefits:**
- ✅ Secrets never stored in etcd (fetched from Key Vault on pod start)
- ✅ Managed by Azure (automatic rotation, audit logs)
- ✅ No base64 encoding visible in kubectl
- ✅ Audit trail in Azure Activity Log
- ✅ Separate identity/authentication (workload identity)

---

## 5.7 Resource Quotas

Set resource quotas per namespace to prevent resource starvation:

```yaml
# k8s/namespaces/resource-quota.yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: otel-demo-quota
  namespace: otel-demo
spec:
  hard:
    requests.cpu: "4"
    requests.memory: 8Gi
    limits.cpu: "8"
    limits.memory: 16Gi
    pods: "50"
```

```bash
kubectl apply -f k8s/namespaces/resource-quota.yaml
kubectl describe resourcequota otel-demo-quota -n otel-demo
```

---

## 5.8 HorizontalPodAutoscaler (Optional)

```yaml
# k8s/otel-demo/hpa-frontend.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: frontend-hpa
  namespace: otel-demo
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: otel-demo-frontend
  minReplicas: 1
  maxReplicas: 5
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
```

---

## 5.9 Deploy Prometheus + Grafana (kube-prometheus-stack)

The `prometheus-community/kube-prometheus-stack` Helm chart bundles Prometheus Operator, Prometheus, AlertManager, Grafana, and node exporters. We'll customize it for our AKS learning environment.

### Important: SQLite Database Limitations

**⚠️ Critical issue**: The upstream Helm chart uses aggressive readiness probe defaults (3 failures, 1-second timeout) that don't work well with Grafana's SQLite database in Kubernetes multi-pod scenarios.

**Why?**
- SQLite uses **file-based locking** — incompatible with multiple pods accessing the same PVC simultaneously
- Database migrations during startup take 30-60+ seconds
- Default RollingUpdate creates multiple replicas → concurrent database access → lock contention → crashes

**Our Solution:**
```yaml
# k8s/monitoring/prometheus-values.yaml
grafana:
  replicas: 1                        # Single pod only
  deploymentStrategy:
    type: Recreate                   # Kill old pod before starting new one
  readinessProbe:
    initialDelaySeconds: 30          # Give time before first probe
    timeoutSeconds: 5                # Allow DB migration operations
    failureThreshold: 12             # ~120s tolerance for slow startup
```

**Note:** For production, use an external database (PostgreSQL/MySQL) instead of SQLite. Then you can safely use replicas > 1 with RollingUpdate.

### Step 1: Add Prometheus Community Helm Repo

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
```

### Step 2: Create Values File

Create `k8s/monitoring/prometheus-values.yaml` (already included in your repo):

Key overrides:
- **Grafana ingress**: Disabled (use port-forward for internal access)
- **Node exporter**: Disabled (AKS nodes missing required labels for DaemonSet scheduling)
- **Persistence**: Uses managed-csi storage class (from Azure)
- **Prometheus scrape targets**: Configured to collect metrics from OTel collector in `otel-demo` namespace

### Step 3: Deploy kube-prometheus-stack

```bash
helm upgrade --install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values k8s/monitoring/prometheus-values.yaml \
  --wait --timeout 20m
```

**Expected output:**
```
Release "kube-prometheus-stack" has been upgraded. Happy Helming!
NAME: kube-prometheus-stack
LAST DEPLOYED: Sat May 23 15:30:48 2026
NAMESPACE: monitoring
STATUS: deployed
REVISION: 7
```

### Step 4: Verify Deployment

```bash
# Check all monitoring pods
kubectl -n monitoring get pods

# Expected: All pods should be Ready (Prometheus, AlertManager, Grafana, etc.)
# Grafana takes longer due to SQLite migrations — may see 2/3 ready briefly

# Get Grafana admin password
kubectl -n monitoring get secret kube-prometheus-stack-grafana \
  -o jsonpath="{.data.admin-password}" | base64 -d

# Check all services (internal ClusterIP only, no external access)
kubectl -n monitoring get svc
```

### Step 5: Access Services via Port-Forward

```bash
# Grafana (port 3000)
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
# Visit: http://localhost:3000
# Login: admin / <password from step 4>

# Prometheus (port 9090)
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
# Visit: http://localhost:9090
# Targets tab shows: OTel collector metrics from otel-demo namespace

# AlertManager (port 9093)
kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093:9093
# Visit: http://localhost:9093
```

### Troubleshooting Grafana Readiness Issues

**Problem**: Grafana pod shows `2/3` Ready but logs show successful startup.

**Root Cause**: Readiness probe timeout during SQLite migrations.

**Verification**: Check if service is actually working:
```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80 &
curl http://127.0.0.1:3000/api/health
kill %1

# Expected output:
# {"database":"ok","version":"13.0.1+security-01","commit":"9bbe672d"}
```

**Solutions**:
1. **Wait longer** — SQLite migrations complete slowly; pod becomes Ready after 2-3 minutes
2. **Check logs** — `kubectl -n monitoring logs -l app.kubernetes.io/name=grafana --tail=100 | grep -i "error\|migration"`
3. **Restart pod** — Force reconciliation: `kubectl -n monitoring delete pod -l app.kubernetes.io/name=grafana`

**Persistent problem?** See `/memories/repo/kube-prometheus-stack-notes.md` for detailed diagnosis and production alternatives.

---

## 5.10 Deployment Verification Script

```bash
#!/bin/bash
# scripts/verify-cluster.sh

echo "=== Checking Cluster Health ==="

echo ""
echo "--- Nodes ---"
kubectl get nodes -o wide

echo ""
echo "--- OTel Demo Pods ---"
kubectl get pods -n otel-demo

echo ""
echo "--- Monitoring Pods ---"
kubectl get pods -n monitoring

echo ""
echo "--- Ingress ---"
kubectl get ingress -A

echo ""
echo "--- Services with External IPs ---"
kubectl get services -A --field-selector spec.type=LoadBalancer

FAILED=$(kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded \
  --no-headers 2>/dev/null | wc -l)

if [ "$FAILED" -gt 0 ]; then
  echo ""
  echo "⚠️  Non-running pods:"
  kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
else
  echo ""
  echo "✅ All pods are running"
fi
```

---

## Summary Checklist

- [x] Namespaces created (otel-demo, monitoring, ingress-nginx)
- [x] NGINX Ingress Controller deployed with public IP
- [x] OTel Demo deployed via Helm with ACR images
- [x] Prometheus + Grafana deployed
- [x] Applications accessible via Ingress
- [x] Resource quotas set
- [x] Secrets managed via Azure Key Vault CSI Driver (optional)

**Next:** [06 — GitHub Actions CI/CD](06-github-actions-cicd.md)
