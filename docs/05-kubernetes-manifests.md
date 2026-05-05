# Section 5 — Kubernetes Manifests & Helm Deployment

> Deploy the OpenTelemetry Astronomy Shop to AKS using Helm. Set up namespaces, RBAC, Ingress, and configure the app to pull images from ACR.

---

## 5.1 Namespace Strategy

```
Namespace              Purpose
─────────────────────  ──────────────────────────────────────────
otel-demo              OpenTelemetry Astronomy Shop (all 15+ services)
monitoring             Prometheus, Grafana, Alertmanager
ingress-nginx          NGINX Ingress Controller
cert-manager           TLS certificate automation (optional)
```

### Create Namespaces

```bash
# k8s/namespaces/namespaces.yaml
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: otel-demo
  labels:
    app.kubernetes.io/managed-by: helm
    project: devops-aks-project
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

kubectl get namespaces
```

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

The OpenTelemetry project provides an official Helm chart. We'll customize it for AKS/ACR.

### Step 1: Add the OTel Helm repo

```bash
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update

# Inspect the default values
helm show values open-telemetry/opentelemetry-demo > /tmp/otel-demo-defaults.yaml
```

### Step 2: Create Custom Values File

Create `k8s/otel-demo/values.yaml`:

```yaml
# k8s/otel-demo/values.yaml

# Override image registry to use ACR
default:
  image:
    repository: acrdevopsproject.azurecr.io
    tag: "v1.0.0"          # Use git SHA in CI/CD
    pullPolicy: IfNotPresent

# Ingress configuration
components:
  frontendProxy:
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

# OpenTelemetry Collector configuration
opentelemetry-collector:
  config:
    exporters:
      # Send traces to Jaeger
      otlp/jaeger:
        endpoint: "jaeger-collector:4317"
        tls:
          insecure: true
      # Send metrics to Prometheus
      prometheus:
        endpoint: "0.0.0.0:9464"
      # Debug logging
      debug:
        verbosity: basic

    service:
      pipelines:
        traces:
          exporters: [otlp/jaeger, debug]
        metrics:
          exporters: [prometheus, debug]
        logs:
          exporters: [debug]

# Resource limits — adjust for your node sizes
components:
  adService:
    resources:
      requests:
        memory: "300Mi"
        cpu: "100m"
      limits:
        memory: "500Mi"

  cartService:
    resources:
      requests:
        memory: "160Mi"
        cpu: "100m"
      limits:
        memory: "250Mi"

  checkoutService:
    resources:
      requests:
        memory: "150Mi"
        cpu: "100m"
      limits:
        memory: "250Mi"

  frontend:
    resources:
      requests:
        memory: "250Mi"
        cpu: "100m"
      limits:
        memory: "400Mi"

  productCatalogService:
    resources:
      requests:
        memory: "60Mi"
        cpu: "50m"
      limits:
        memory: "120Mi"
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

---

## 5.4 Install Prometheus + Grafana (kube-prometheus-stack)

```bash
# Add repo
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Create values file for Prometheus stack
cat > k8s/monitoring/prometheus-values.yaml <<'EOF'
# k8s/monitoring/prometheus-values.yaml

grafana:
  enabled: true
  adminPassword: "admin-change-me"   # Change this! Or use a K8s secret
  ingress:
    enabled: true
    annotations:
      kubernetes.io/ingress.class: nginx
    hosts:
      - ""    # Will use IP-based access

prometheus:
  prometheusSpec:
    # Scrape interval
    scrapeInterval: 30s
    # Scrape OTel Collector metrics
    additionalScrapeConfigs:
      - job_name: otel-collector
        kubernetes_sd_configs:
          - role: pod
            namespaces:
              names:
                - otel-demo
        relabel_configs:
          - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
            action: keep
            regex: true

alertmanager:
  enabled: true

# PersistentVolumeClaims for data retention
prometheus:
  prometheusSpec:
    retention: 15d
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: managed-csi
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 20Gi

grafana:
  persistence:
    enabled: true
    storageClassName: managed-csi
    size: 5Gi
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

### Using Azure Key Vault with Kubernetes Secrets Store CSI Driver

```bash
# Install the Secrets Store CSI Driver
helm repo add csi-secrets-store-provider-azure \
  https://azure.github.io/secrets-store-csi-driver-provider-azure/charts
helm repo update

helm upgrade --install azure-csi-secrets \
  csi-secrets-store-provider-azure/csi-secrets-store-provider-azure \
  --namespace kube-system \
  --set syncSecret.enabled=true
```

Example `SecretProviderClass`:

```yaml
# k8s/secrets/secret-provider.yaml
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: azure-keyvault-secrets
  namespace: otel-demo
spec:
  provider: azure
  secretObjects:
    - secretName: app-secrets
      type: Opaque
      data:
        - objectName: db-password
          key: db-password
  parameters:
    usePodIdentity: "false"
    useVMManagedIdentity: "false"
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

## 5.9 Deployment Verification Script

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
