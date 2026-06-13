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
```

The values file is already in the repository at `k8s/monitoring/prometheus-values.yaml`. Its current contents:

```yaml
# k8s/monitoring/prometheus-values.yaml

grafana:
  enabled: true
  admin:
    existingSecret: grafana-admin-credentials  # Pre-create this secret — never use plaintext adminPassword
    userKey: admin-user
    passwordKey: admin-password

  replicas: 1
  deploymentStrategy:
    type: Recreate  # Avoids SQLite lock contention during restarts (see L-013)
  ingress:
    enabled: true
    ingressClassName: nginx
    annotations:
      nginx.ingress.kubernetes.io/ssl-redirect: "false"
    hosts:
      - ""    # Use ingress IP directly; no hostname needed for learning
    path: /grafana
    pathType: Prefix
  grafana.ini:
    server:
      root_url: "%(protocol)s://%(domain)s/grafana/"
      serve_from_sub_path: true  # Required when Grafana is served on a sub-path
  persistence:
    enabled: true
    storageClassName: managed-csi
    size: 5Gi
  # More tolerant probes prevent restart loops on small AKS nodes during slow first boot
  readinessProbe:
    initialDelaySeconds: 30
    timeoutSeconds: 5
    periodSeconds: 10
    failureThreshold: 12
  livenessProbe:
    initialDelaySeconds: 180
    timeoutSeconds: 10
    periodSeconds: 10
    failureThreshold: 12

prometheus:
  ingress:
    enabled: true
    ingressClassName: nginx
    annotations:
      nginx.ingress.kubernetes.io/ssl-redirect: "false"
    hosts:
      - ""
    paths:
      - /prometheus
    pathType: Prefix
  prometheusSpec:
    routePrefix: /prometheus  # Required when exposing Prometheus on a sub-path via ingress
    scrapeInterval: 30s
    # Scrape OTel Collector agent metrics from otel-demo namespace.
    # Uses pod label matching instead of prometheus.io/scrape annotations —
    # the OTel demo chart does not add those annotations by default.
    additionalScrapeConfigs:
      - job_name: otel-collector
        kubernetes_sd_configs:
          - role: pod
            namespaces:
              names:
                - otel-demo
        relabel_configs:
          - source_labels: [__meta_kubernetes_pod_label_app_kubernetes_io_name, __meta_kubernetes_pod_label_component]
            action: keep
            regex: opentelemetry-collector;agent-collector
          - source_labels: [__meta_kubernetes_pod_container_port_name]
            action: keep
            regex: metrics
    retention: 7d
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: managed-csi
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 20Gi

prometheusOperator:
  admissionWebhooks:
    patch:
      enabled: true  # Set to false only if hook pods can't schedule (see L-014)

alertmanager:
  enabled: true

nodeExporter:
  enabled: true

prometheus-node-exporter:
  enabled: true
```

> **Why `existingSecret` instead of `adminPassword`?**  
> Putting a password directly in a values file risks it ending up in git history or Helm release metadata. Pre-creating a secret decouples the credential lifecycle from the Helm release.

> **Why label-based scraping instead of annotation-based?**  
> The OTel demo chart does not add `prometheus.io/scrape: "true"` annotations to its pods. Label matching (`app.kubernetes.io/name` + `component`) is more reliable than relying on annotations that may not be set.

### Deploy

```bash
# Pre-create the Grafana admin secret before installing the chart
# Edit k8s/monitoring/grafana-admin-secret.yaml to set a real password first
kubectl apply -f k8s/monitoring/grafana-admin-secret.yaml

# Install / upgrade (omit --wait to avoid timeout on slow nodes — see L-012)
helm upgrade --install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --values k8s/monitoring/prometheus-values.yaml \
  --timeout 10m

# Verify
kubectl get pods -n monitoring
kubectl get services -n monitoring
```

> **Why no `--wait`?** With `--wait`, Helm blocks until all pods including DaemonSets are Ready. If a DaemonSet pod is pending due to node capacity or scheduling constraints it causes the whole `helm upgrade` to time out even though the workload is healthy. See L-012.

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
kubectl get secret -n monitoring grafana-admin-credentials \
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
echo "Jaeger:               http://$INGRESS_IP/jaeger/ui   (or port-forward)"

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

#### ConfigMap Example: OTel Collector Configuration (Helm-generated)

The `opentelemetry-demo` Helm chart auto-generates a ConfigMap called `otel-collector-agent` in the `otel-demo` namespace. You never write this manually — Helm creates it from its chart templates when you run `helm upgrade --install`.

The pod mounts it as a volume at `/conf/relay.yaml` (visible in `kubectl describe pod`):

```
Volumes:
  opentelemetry-collector-configmap:
    Type:      ConfigMap (a volume populated by a ConfigMap)
    Name:      otel-collector-agent   ← auto-created by Helm chart
```

Inspect what the chart generated:

```bash
kubectl get configmap otel-collector-agent -n otel-demo -o yaml
```

This contains the full OTel collector pipeline: receivers (OTLP on `:4317`/`:4318`), processors, and exporters (Jaeger, Prometheus on `:8888`). The collector uses `--config=/conf/relay.yaml` as its startup argument, reading this file from the mounted ConfigMap.

**Key insight:** Helm charts don't just deploy pods. They generate all supporting objects — ConfigMaps, Secrets, ServiceAccounts, RBAC rules, Services — from their templates. When you change a value in `values.yaml` and run `helm upgrade`, Helm re-renders and updates all these objects automatically.

#### Secret Example: Prometheus Scrape Config (Operator-generated)

In kube-prometheus-stack, the Prometheus Operator does **not** use a plain ConfigMap for scrape targets. It generates a **compressed Secret**:

```bash
# The Prometheus Operator generates this Secret — not a ConfigMap
kubectl get secret prometheus-kube-prometheus-stack-prometheus -n monitoring

# Decode the full merged config (additionalScrapeConfigs + ServiceMonitors)
kubectl get secret prometheus-kube-prometheus-stack-prometheus -n monitoring \
  -o jsonpath='{.data.prometheus\.yaml\.gz}' | base64 -d | gunzip | grep "^- job_name:"
```

Your `additionalScrapeConfigs` in `k8s/monitoring/prometheus-values.yaml` feeds into this Secret alongside the auto-generated ServiceMonitor targets. See [Section 7.3.1](07-observability.md#731-where-prometheus-scrape-targets-are-defined) for the full explanation.

#### Secret Example: Grafana Admin Password (manually pre-created)

This is one Secret you **do** create manually — before running `helm install` — because Helm needs it to exist at deploy time:

```bash
# k8s/monitoring/grafana-admin-secret.yaml — apply this before helm install
kubectl apply -f k8s/monitoring/grafana-admin-secret.yaml

# Query the password later
kubectl -n monitoring get secret grafana-admin-credentials \
  -o jsonpath="{.data.admin-password}" | base64 -d ; echo
```

Grafana reads it via `existingSecret` in `prometheus-values.yaml` rather than taking a plaintext `adminPassword` — so the credential is never stored in Helm release history or your values file.

**Benefit:**
- Credentials never appear in container images or Helm history
- Can be rotated without a `helm upgrade`
- Kubernetes can encrypt Secrets at rest in etcd

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

### Next Step in This Project: Add One ConfigMap + One Secret

Use this as the immediate follow-up exercise after section 5.5.

1. Create a non-sensitive runtime ConfigMap manifest:

```bash
kubectl -n otel-demo create configmap app-runtime-config \
  --from-literal=LOG_LEVEL=info \
  --from-literal=FEATURE_RECOMMENDATIONS=true \
  --dry-run=client -o yaml > k8s/secrets/app-runtime-config.yaml
```

2. Create a sensitive Secret manifest (development sample):

```bash
kubectl -n otel-demo create secret generic app-runtime-secrets \
  --from-literal=API_TOKEN=replace-me \
  --dry-run=client -o yaml > k8s/secrets/app-runtime-secrets.yaml
```

3. Apply both manifests:

```bash
kubectl apply -f k8s/secrets/app-runtime-config.yaml
kubectl apply -f k8s/secrets/app-runtime-secrets.yaml
```

4. Inject values into a real deployment from this cluster (`frontend`):

```bash
kubectl -n otel-demo set env deployment/frontend --from=configmap/app-runtime-config
kubectl -n otel-demo set env deployment/frontend --from=secret/app-runtime-secrets
kubectl rollout status -n otel-demo deployment/frontend
```

5. Verify the pod received values:

```bash
kubectl -n otel-demo get configmap app-runtime-config -o yaml
kubectl -n otel-demo get secret app-runtime-secrets -o yaml
kubectl -n otel-demo describe deployment frontend | grep -A8 "Environment"
```

Notes:
- Use ConfigMap for non-sensitive settings only.
- Use Secret for sensitive values; rotate them regularly.
- Keep generated secret manifests out of source control for real environments.

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
kubectl -n otel-demo set env deployment/cart \
  --from=secret/database-config
```

---

### Option 2: Azure Key Vault Integration (Production)

For sensitive credentials, integrate with **Azure Key Vault** using the **Secrets Store CSI Driver**.

#### Architecture Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  SETUP (one-time, done by platform team)                                    │
│                                                                             │
│  1. Create UAMI (User Assigned Managed Identity)                            │
│     └─ az identity create                                                   │
│                                                                             │
│  2. Create Federated Credential on UAMI                                     │
│     └─ binds: AKS OIDC issuer + Kubernetes ServiceAccount subject           │
│        az identity federated-credential create                              │
│                                                                             │
│  3. Annotate Kubernetes ServiceAccount with UAMI client ID                  │
│     └─ azure.workload.identity/client-id: "<UAMI_CLIENT_ID>"               │
│                                                                             │
│  4. Grant UAMI "Key Vault Secrets User" on the Key Vault                    │
│     └─ az role assignment create                                            │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│  RUNTIME (happens automatically when pod starts)                            │
│                                                                             │
│  Pod starts with serviceAccountName: workload-identity-sa                  │
│       │                                                                     │
│       ▼                                                                     │
│  AKS injects projected token (OIDC) into pod                               │
│       │                                                                     │
│       ▼                                                                     │
│  Secrets Store CSI Driver reads SecretProviderClass                        │
│  └─ knows: keyvaultName, tenantId, clientID (UAMI)                         │
│       │                                                                     │
│       ▼                                                                     │
│  CSI Driver exchanges OIDC token with Microsoft Entra ID                   │
│  └─ validates against federated credential (issuer + subject match)        │
│       │                                                                     │
│       ▼                                                                     │
│  Microsoft Entra issues access token for UAMI                              │
│       │                                                                     │
│       ▼                                                                     │
│  CSI Driver calls Azure Key Vault with access token                        │
│  └─ GET https://kv-devops-aks-*.vault.azure.net/secrets/db-password        │
│       │                                                                     │
│       ▼                                                                     │
│  Secret mounted as file at /mnt/secrets-store/db-password                  │
│  (optionally synced to Kubernetes Secret → env var)                        │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│  KEY OBJECTS AND WHERE THEY LIVE                                            │
│                                                                             │
│  Azure                         Kubernetes (AKS)                            │
│  ──────                         ──────────────────                         │
│  UAMI (identity)           ←→  ServiceAccount (annotated)                  │
│  Federated Credential      ←→  OIDC subject binding                        │
│  Key Vault (secrets)       ←→  SecretProviderClass (config)                │
│  KV access policy/RBAC     ←→  CSI mount on pod volume                    │
│                                                                             │
│  config file: k8s/secrets/secret-provider.yaml                             │
│  identity file: k8s/secrets/app-runtime-secrets.yaml (ServiceAccount)      │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Why no password is stored in the cluster:**
- Secret value lives only in Azure Key Vault
- Pod gets a short-lived OIDC token (not a password)
- That token is exchanged for an access token scoped to Key Vault
- Token expiry is automatic — no rotation needed
- If the pod stops, the file is gone; it is re-fetched on next start

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

#### Step 1.5: Create UAMI + Federated Credential (Workload Identity)

Use this compact flow to create the identity and bind it to a Kubernetes ServiceAccount.

```bash
# Variables
RG=rg-devops-aks
AKS=aks-devops-project
NS=otel-demo
SA=workload-identity-sa
UAMI_NAME=uami-otel-secrets
KV_NAME=<your-keyvault-name>

# 1) Create UAMI (or reuse existing)
az identity create -g $RG -n $UAMI_NAME

UAMI_CLIENT_ID=$(az identity show -g $RG -n $UAMI_NAME --query clientId -o tsv)
UAMI_PRINCIPAL_ID=$(az identity show -g $RG -n $UAMI_NAME --query principalId -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
AKS_OIDC_ISSUER=$(az aks show -g $RG -n $AKS --query "oidcIssuerProfile.issuerUrl" -o tsv)

# 2) ServiceAccount annotated with UAMI client ID
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $SA
  namespace: $NS
  annotations:
    azure.workload.identity/client-id: "$UAMI_CLIENT_ID"
EOF

# 3) Federated credential (note: use --issuer/--subject/--audiences)
# Some Azure CLI versions do not support '--parameters' for this command.
az identity federated-credential create \
  --name fic-$NS-$SA \
  --identity-name $UAMI_NAME \
  --resource-group $RG \
  --issuer $AKS_OIDC_ISSUER \
  --subject system:serviceaccount:$NS:$SA \
  --audiences api://AzureADTokenExchange

# 4) Grant Key Vault read access to the UAMI
# IMPORTANT: pick the command based on Key Vault permission model.
KV_RBAC_ENABLED=$(az keyvault show -n $KV_NAME -g $RG --query properties.enableRbacAuthorization -o tsv)

if [ "$KV_RBAC_ENABLED" = "true" ]; then
  # RBAC model
  KV_ID=$(az keyvault show -n $KV_NAME -g $RG --query id -o tsv)
  az role assignment create \
    --assignee-object-id $UAMI_PRINCIPAL_ID \
    --assignee-principal-type ServicePrincipal \
    --role "Key Vault Secrets User" \
    --scope $KV_ID
else
  # Access policy model
  az keyvault set-policy \
    --name $KV_NAME \
    --object-id $UAMI_PRINCIPAL_ID \
    --secret-permissions get list
fi

# 5) Create the Key Vault secret referenced by SecretProviderClass
# SecretProviderClass requests objectName: db-password, so create it first.
az keyvault secret set \
  --vault-name $KV_NAME \
  --name db-password \
  --value "CHANGE_ME_DB_PASSWORD"
```

Keep these outputs for Step 2:
- `UAMI_CLIENT_ID` -> `clientID`
- `KV_NAME` -> `keyvaultName`
- `TENANT_ID` -> `tenantId`

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
    useVMManagedIdentity: "false"     # Workload Identity pattern
    clientID: "<uami-client-id>"      # Client ID of a User Assigned Managed Identity (created separately)
    keyvaultName: "<your-keyvault-name>"
    tenantId: "<your-tenant-id>"
    objects: |
      array:
        - |
          objectName: db-password
          objectType: secret
          objectVersion: ""

# Note:
# AKS creation in Section 3 enables OIDC + Workload Identity but does not create
# a UAMI automatically. Create a UAMI and federated credential, then use that
# UAMI client ID here.
```

#### Step 3: Mount in Pod Spec

> **Should you do this now?**  
> **Yes — but use a test pod first**, not the real `cart` Deployment. The test pod confirms the full chain works (UAMI → federated credential → Key Vault) before you change any running workload.

**What Step 3 means in the runtime flow:**

```
Pod spec has two things:
  1. serviceAccountName: workload-identity-sa   ← which identity to use
  2. volume with csi driver secrets-store       ← where to mount the secret

At pod start:
  CSI driver reads the SecretProviderClass (from step 2)
  Uses the ServiceAccount's identity (from step 1.5)
  Fetches the secret from Key Vault
  Mounts it as a file at mountPath
```

**Sub-step A: Test pod (do this first to validate the setup)**

```bash
NS=otel-demo
SA=workload-identity-sa

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: kv-test-pod
  namespace: $NS
  labels:
    azure.workload.identity/use: "true"   # Required — tells mutating webhook to inject OIDC token
spec:
  serviceAccountName: $SA                 # Must match ServiceAccount from Step 1.5
  containers:
    - name: busybox
      image: busybox
      command: ["/bin/sh", "-c", "sleep 3600"]
      volumeMounts:
        - name: kv-secrets
          mountPath: /mnt/secrets-store   # Secret file will appear here
          readOnly: true
  volumes:
    - name: kv-secrets
      csi:
        driver: secrets-store.csi.k8s.io
        readOnly: true
        volumeAttributes:
          secretProviderClass: azure-keyvault-secrets  # Must match name in Step 2
EOF

# Wait for pod to start (CSI fetches secret at this moment)
kubectl get pod kv-test-pod -n $NS -w

# Verify the secret file is mounted
kubectl exec -n $NS kv-test-pod -- ls /mnt/secrets-store
kubectl exec -n $NS kv-test-pod -- cat /mnt/secrets-store/db-password

# Clean up test pod when done
kubectl delete pod kv-test-pod -n $NS
```

**What to expect:**
- Pod `Running` → CSI mount worked → Key Vault fetch succeeded
- Pod `ContainerCreating` stuck → describe the pod, check Events for CSI errors
- Secret file contains the plaintext value from Key Vault

**Sub-step B: Add to a real Deployment (only after test pod succeeds)**

```yaml
# Add these to the Deployment you want to use the secret
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cart
  namespace: otel-demo
spec:
  template:
    metadata:
      labels:
        azure.workload.identity/use: "true"   # ← ADD THIS LABEL to pod template
    spec:
      serviceAccountName: workload-identity-sa  # ← ADD THIS to use UAMI identity
      containers:
      - name: cartservice
        env:
          # Option A: Read from mounted file in app code
          # Option B: Sync to env var via secretObjects in SecretProviderClass
          - name: DB_PASSWORD
            valueFrom:
              secretKeyRef:
                name: app-secrets          # synced by secretObjects in SecretProviderClass
                key: db-password
        volumeMounts:
        - name: kv-secrets
          mountPath: /mnt/secrets-store
          readOnly: true
      volumes:
      - name: kv-secrets
        csi:
          driver: secrets-store.csi.k8s.io
          readOnly: true
          volumeAttributes:
            secretProviderClass: azure-keyvault-secrets
```

> **Two ways to consume the secret in your app:**
>
> | Method | How | Best for |
> |--------|-----|----------|
> | File read | App reads `/mnt/secrets-store/db-password` directly | Apps that support file-based config |
> | Env var | SecretProviderClass `secretObjects` syncs to a K8s Secret → env var | Apps expecting `DB_PASSWORD` env var |
>
> The `secretObjects` block in your `secret-provider.yaml` enables the env var path.

**Troubleshooting if pod stays in ContainerCreating:**

```bash
kubectl describe pod kv-test-pod -n $NS | grep -A 20 "^Events:"

# Common causes:
# "failed to get provider" → CSI driver not installed (redo Step 1)
# "keyvault.BaseClient#GetSecret: 403"  → UAMI missing Key Vault RBAC (redo Step 1.5 #4)
# "token exchange failed"               → federated credential mismatch (check issuer/subject)
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
kubectl -n monitoring get secret grafana-admin-credentials \
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
