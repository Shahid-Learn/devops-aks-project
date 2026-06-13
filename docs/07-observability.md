# Section 7 — Observability: OpenTelemetry, Prometheus, Grafana & Jaeger

> Configure end-to-end observability: traces, metrics, and logs using the OTel Collector, Prometheus, Grafana, and Jaeger — all included with the OpenTelemetry Demo.

---

## 7.1 Observability Pillars

```
                    ┌──────────────────────────────────────┐
                    │         Your Application              │
                    │   (15+ OTel-instrumented services)    │
                    └──────────────┬───────────────────────┘
                                   │ OTLP (gRPC/HTTP)
                                   ▼
                    ┌──────────────────────────────────────┐
                    │     OpenTelemetry Collector           │
                    │  (receives, processes, exports)       │
                    └────┬─────────────┬────────────────┬──┘
                         │             │                │
                    Traces          Metrics           Logs
                         │             │                │
                         ▼             ▼                ▼
                    ┌────────┐   ┌──────────┐   ┌──────────┐
                    │ Jaeger │   │Prometheus│   │  Loki    │
                    │(traces)│   │(metrics) │   │  (logs)  │
                    └────────┘   └────┬─────┘   └──────────┘
                                      │
                                      ▼
                                 ┌─────────┐
                                 │ Grafana │
                                 │(dashbrd)│
                                 └─────────┘
```

| Signal | Tool | What it shows |
|--------|------|---------------|
| Traces | Jaeger | Request flow across services, latency, errors |
| Metrics | Prometheus + Grafana | CPU, memory, request rates, business metrics |
| Logs | Loki (optional) | Structured log aggregation |

---

## 7.2 OpenTelemetry Collector Deep Dive

The OTel Collector is the central hub — it receives telemetry from all services and routes it to backends.

### OTel Collector Configuration

The demo deploys the collector with these pipelines. Here's a conceptual view:

```yaml
# Conceptual otel-collector-config.yaml (already in the demo chart)

receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317    # gRPC
      http:
        endpoint: 0.0.0.0:4318    # HTTP/JSON

  # Collect Kubernetes metrics
  k8s_cluster:
    collection_interval: 30s

  # Collect host metrics
  hostmetrics:
    collection_interval: 30s
    scrapers:
      cpu:
      memory:
      disk:
      network:

processors:
  batch:                            # Batch for efficiency
    timeout: 10s
    send_batch_size: 1024

  memory_limiter:                   # Prevent OOM
    check_interval: 1s
    limit_mib: 512
    spike_limit_mib: 128

  resource:                         # Add K8s metadata
    attributes:
      - action: insert
        key: k8s.cluster.name
        value: aks-devops-project

exporters:
  otlp/jaeger:
    endpoint: "jaeger-collector:4317"
    tls:
      insecure: true

  prometheus:
    endpoint: "0.0.0.0:9464"
    namespace: otel_demo

  debug:
    verbosity: detailed

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [otlp/jaeger, debug]

    metrics:
      receivers: [otlp, hostmetrics]
      processors: [memory_limiter, batch]
      exporters: [prometheus, debug]

    logs:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [debug]
```

---

## 7.3 Accessing Observability Tools

### Routing note (monitoring ingress paths)

- The public ingress IP belongs to the NGINX ingress controller.
- Grafana is exposed from the monitoring stack on `/grafana`.
- Prometheus is exposed from the monitoring stack on `/prometheus`.
- Jaeger UI is exposed from the `otel-demo` namespace on `/jaeger/ui` via `k8s/ingress/jaeger-ingress.yaml`.
- `k8s/ingress/jaeger-ingress.yaml` must not use `nginx.ingress.kubernetes.io/permanent-redirect` for this route. It causes a redirect loop when `/jaeger/ui` is also matched by the same ingress rule.
- Monitoring routes are configured in `k8s/monitoring/prometheus-values.yaml` and the Jaeger route in `k8s/ingress/jaeger-ingress.yaml`.

```bash
# Option 1: Direct access via Ingress (if configured)
INGRESS_IP=$(kubectl get service ingress-nginx-controller \
  -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

echo "Jaeger UI:   http://$INGRESS_IP/jaeger/ui"
echo "Grafana:     http://$INGRESS_IP/grafana"
echo "Prometheus:  http://$INGRESS_IP/prometheus/"

# Option 2: Port-forward (simpler for learning)

# Jaeger (included with OTel demo)
kubectl port-forward -n otel-demo svc/otel-demo-jaeger-query 16686:16686 &
echo "Jaeger: http://localhost:16686"

# Grafana (from kube-prometheus-stack)
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80 &
echo "Grafana: http://localhost:3000  (admin / admin-change-me)"

# Prometheus
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 &
echo "Prometheus: http://localhost:9090"

# OTel Demo frontend
kubectl port-forward -n otel-demo svc/otel-demo-frontendproxy 8080:8080 &
echo "Astronomy Shop: http://localhost:8080"
```

Expected HTTP behavior on ingress:

- `http://<INGRESS_IP>/grafana/` returns `302` to `/grafana/login`
- `http://<INGRESS_IP>/prometheus/` returns `302` to `/prometheus/query`
- `http://<INGRESS_IP>/jaeger/ui` returns `307` to `/jaeger/ui/`, then `200`
- `http://<INGRESS_IP>/jaeger` may return `404` and is not the canonical URL

---

## 7.3.1 Where Prometheus Scrape Targets Are Defined

Understanding this is essential — targets come from **two separate mechanisms** that the Prometheus Operator merges at runtime.

### The two mechanisms

| Mechanism | Where defined | Who creates it | Examples in this project |
|---|---|---|---|
| **ServiceMonitors** (CRDs) | Auto-created by `kube-prometheus-stack` Helm chart | Prometheus Operator | alertmanager, grafana, apiserver, kubelet, node-exporter, kube-state-metrics, coredns, etcd, scheduler |
| **additionalScrapeConfigs** | `k8s/monitoring/prometheus-values.yaml` | You (manual) | `otel-collector` job |

### How they become active

```
k8s/monitoring/prometheus-values.yaml       kubectl get servicemonitors -n monitoring
  prometheus.prometheusSpec                  (auto-created by chart install)
    additionalScrapeConfigs:              +   serviceMonitor/monitoring/kube-prometheus-stack-*
      - job_name: otel-collector                  alertmanager, grafana, kubelet,
        ...                                        node-exporter, kube-state-metrics ...
              │                                          │
              └──────── Prometheus Operator ─────────────┘
                                │
                  Builds a compressed Secret:
                  prometheus-kube-prometheus-stack-prometheus
                  (namespace: monitoring)
                                │
                  Prometheus pod mounts and reads it
                                │
                  Targets visible at /targets in web UI
```

### Verify what is actually loaded

```bash
# 1. See all job names in the generated config (fastest check)
kubectl get secret prometheus-kube-prometheus-stack-prometheus -n monitoring \
  -o jsonpath='{.data.prometheus\.yaml\.gz}' | base64 -d | gunzip | grep "^- job_name:"

# 2. Full config for a specific job
kubectl get secret prometheus-kube-prometheus-stack-prometheus -n monitoring \
  -o jsonpath='{.data.prometheus\.yaml\.gz}' | base64 -d | gunzip \
  | grep -A 15 "job_name: otel-collector"

# 3. Live target status (requires port-forward)
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 &
# http://localhost:9090/targets     — shows UP / DOWN per target
# http://localhost:9090/config      — shows full merged config

# 4. List all ServiceMonitors (what feeds the auto-targets)
kubectl get servicemonitors -n monitoring

# 5. List all PrometheusRule CRDs (alert rules)
kubectl get prometheusrules -n monitoring
```

### What your project's targets look like

Running the secret decode in this project shows these `job_name` entries:

| Job name | Source | What it scrapes |
|---|---|---|
| `serviceMonitor/monitoring/kube-prometheus-stack-alertmanager/*` | ServiceMonitor (auto) | Alertmanager metrics |
| `serviceMonitor/monitoring/kube-prometheus-stack-grafana/*` | ServiceMonitor (auto) | Grafana self-metrics |
| `serviceMonitor/monitoring/kube-prometheus-stack-apiserver/*` | ServiceMonitor (auto) | Kubernetes API server |
| `serviceMonitor/monitoring/kube-prometheus-stack-kubelet/*` | ServiceMonitor (auto) | Kubelet + cAdvisor (container metrics) |
| `serviceMonitor/monitoring/kube-prometheus-stack-kube-state-metrics/*` | ServiceMonitor (auto) | Pod/deployment status metrics |
| `serviceMonitor/monitoring/kube-prometheus-stack-prometheus-node-exporter/*` | ServiceMonitor (auto) | Node CPU, memory, disk |
| `serviceMonitor/monitoring/kube-prometheus-stack-coredns/*` | ServiceMonitor (auto) | DNS resolution metrics |
| `serviceMonitor/monitoring/kube-prometheus-stack-prometheus/*` | ServiceMonitor (auto) | Prometheus self-metrics |
| `serviceMonitor/monitoring/kube-prometheus-stack-operator/*` | ServiceMonitor (auto) | Operator self-metrics |
| `otel-collector` | **additionalScrapeConfigs** in `prometheus-values.yaml` | OTel Collector agent metrics from `otel-demo` namespace |

### Recommended approach for this project

**Use `additionalScrapeConfigs` for your own app scrape jobs** (like `otel-collector`). Reserve `ServiceMonitors` for cases where a Helm chart provides one (e.g. when an app chart ships its own ServiceMonitor CRD).

The OTel demo chart does **not** ship a ServiceMonitor, so `additionalScrapeConfigs` with pod label matching is the right approach here. Annotation-based scraping (`prometheus.io/scrape=true`) is not used because the OTel demo pods do not set those annotations.

To add a new scrape job (e.g. for another app in a different namespace), add another block under `additionalScrapeConfigs` in [`k8s/monitoring/prometheus-values.yaml`](../k8s/monitoring/prometheus-values.yaml) and run `helm upgrade`.

---

## 7.4 Grafana Setup

### Login and Initial Setup

1. Open http://localhost:3000
2. Login: `admin` / `admin-change-me`
3. Change password when prompted

### Add Prometheus Data Source

1. Go to **Connections → Data Sources → Add data source**
2. Choose **Prometheus**
3. URL: `http://kube-prometheus-stack-prometheus.monitoring:9090`
4. Click **Save & Test**

### Add Jaeger Data Source

1. Go to **Connections → Data Sources → Add data source**
2. Choose **Jaeger**
3. URL: `http://otel-demo-jaeger-query.otel-demo:16686`
4. Click **Save & Test**

### Import Pre-built Dashboards

```bash
# Import Kubernetes cluster dashboard
# Dashboard ID: 15757 (Kubernetes / Views / Global)

# Import Node exporter dashboard  
# Dashboard ID: 1860

# Import OTel Collector dashboard
# Dashboard ID: 15983
```

**Via CLI:**
```bash
GRAFANA_URL="http://localhost:3000"
GRAFANA_AUTH="admin:admin-change-me"

# Import dashboard by ID
curl -s -X POST \
  -H "Content-Type: application/json" \
  -u "$GRAFANA_AUTH" \
  -d '{"dashboard": {"id": null}, "folderId": 0, "inputs": [], "overwrite": true}' \
  "$GRAFANA_URL/api/dashboards/import"
```

---

## 7.5 Jaeger — Distributed Tracing

### Jaeger Metrics Backend Override (Important)

When changing Jaeger's `PROMETHEUS_ADDR` through Helm values, remember that `jaeger.jaeger.extraEnv` is a list and Helm replaces the full list instead of merging list entries.

If you set only `PROMETHEUS_ADDR`, Jaeger can crash because required defaults are dropped (for example `MEMORY_MAX_TRACES`, `JAEGER_HOST`, `JAEGER_GRPC_PORT`, `OTEL_COLLECTOR_HOST`, `OTEL_COLLECTOR_PORT_HTTP`).

Keep all required env vars in the override block and only change the `PROMETHEUS_ADDR` value.

### What to Look For

Open Jaeger UI at http://localhost:16686:

1. **Service dropdown** — select `frontend`
2. **Find Traces** — see all recent requests
3. Click any trace to see the **full call graph**
4. Look for:
   - Red spans = errors
   - Long spans = latency bottlenecks
   - Database calls
   - External API calls

### Example Trace Query

```
Service:  checkoutservice
Operation: oteldemo.CheckoutService/PlaceOrder
Tags:     error=true
Lookback: Last 1 hour
```

This finds all failed checkout operations with their full distributed trace.

---

## 7.6 Prometheus Queries (PromQL Examples)

Open Prometheus at http://localhost:9090 → Graph tab:

```promql
# Request rate to the frontend (per second, 5-min window)
rate(http_server_request_count_total{job="otel-demo-frontend"}[5m])

# P99 latency for checkout service
histogram_quantile(0.99,
  rate(rpc_server_duration_milliseconds_bucket{
    job="otel-demo-checkoutservice"
  }[5m])
)

# Error rate across all services
sum by (job) (
  rate(http_server_request_count_total{http_response_status_code=~"5.."}[5m])
)

# Pod CPU usage
sum(rate(container_cpu_usage_seconds_total{namespace="otel-demo"}[5m])) by (pod)

# Memory usage per pod
sum(container_memory_working_set_bytes{namespace="otel-demo"}) by (pod)
```

### 7.6.1 How OTel Collector Targets Are Selected

This project scrapes OTel metrics from `otel-collector-agent` pods using Kubernetes pod service discovery (`role: pod`) and relabel filters.

Configured selectors in [k8s/monitoring/prometheus-values.yaml](../k8s/monitoring/prometheus-values.yaml):

```yaml
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
```

Why this matters:

- The OTel app pods (such as `ad`, `checkout`, `frontend`) are not scraped directly by Prometheus.
- They push telemetry to the collector via OTLP (`:4317` / `:4318`).
- Prometheus scrapes only the collector metrics endpoint (`:8888`, port name `metrics`).
- Annotation-only filtering (`prometheus.io/scrape=true`) does not match these collector-agent pods in this deployment.

Quick checks:

```bash
# Collector agent pods that match label filters
kubectl get pods -n otel-demo \
  -l 'app.kubernetes.io/name=opentelemetry-collector,component=agent-collector'

# Confirm metrics port is present
kubectl describe pod -n otel-demo <collector-agent-pod> | grep '(metrics)'

# Prometheus targets UI
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
# Open http://localhost:9090/targets and filter job=otel-collector
```

To include another namespace, add it under `namespaces.names` for the same job, or create a second `job_name` block for clearer separation.

---

## 7.7 Custom Grafana Dashboard for This Project

Create a dashboard JSON and save to `k8s/monitoring/grafana-dashboard.json`:

Key panels to include:
1. **Request Rate** — HTTP requests/sec to frontend
2. **Error Rate** — 5xx errors per service
3. **P99 Latency** — 99th percentile response time
4. **Pod Status** — Pod count by namespace
5. **Node CPU/Memory** — Cluster resource utilization
6. **Active Carts** — Business metric from cart service

---

## 7.8 Alerting in Grafana

### Example Alert Rules

Navigate to **Alerting → Alert Rules → New Alert Rule**:

**Alert 1: High Error Rate**
```yaml
# Condition: Error rate > 5% for 5 minutes
expr: |
  sum(rate(http_server_request_count_total{http_response_status_code=~"5.."}[5m]))
  /
  sum(rate(http_server_request_count_total[5m]))
  > 0.05
for: 5m
labels:
  severity: warning
annotations:
  summary: "High error rate detected"
  description: "Error rate is {{ $value | humanizePercentage }}"
```

**Alert 2: Pod Crash Looping**
```yaml
expr: rate(kube_pod_container_status_restarts_total{namespace="otel-demo"}[15m]) > 0
for: 5m
labels:
  severity: critical
annotations:
  summary: "Pod {{ $labels.pod }} is crash looping"
```

---

## 7.9 OpenTelemetry Instrumentation Overview

Each service in the demo is already instrumented with OTel. This is what you'd do for your own apps:

```go
// Go example (productcatalogservice)
import (
    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/trace"
)

tracer := otel.Tracer("productcatalogservice")

func GetProduct(ctx context.Context, id string) (*Product, error) {
    ctx, span := tracer.Start(ctx, "GetProduct")
    defer span.End()

    span.SetAttributes(attribute.String("product.id", id))

    product, err := db.Find(ctx, id)
    if err != nil {
        span.RecordError(err)
        span.SetStatus(codes.Error, err.Error())
        return nil, err
    }

    return product, nil
}
```

The span is automatically sent to the OTel Collector → Jaeger → visible in Jaeger UI.

---

## 7.10 Verify Full Observability Pipeline

```bash
# 1. Generate some load
kubectl port-forward -n otel-demo svc/otel-demo-frontendproxy 8080:8080 &

# Generate traffic (the loadgenerator pod does this automatically)
# But you can also do it manually:
for i in {1..20}; do
  curl -s http://localhost:8080/api/products > /dev/null
  sleep 0.5
done

# 2. Check OTel Collector is processing telemetry
kubectl logs -n otel-demo -l app.kubernetes.io/name=opentelemetry-collector --tail=50

# 3. Check Jaeger has traces
curl -s "http://localhost:16686/api/services" | jq '.data[]'

# 4. Check Prometheus has metrics
curl -s "http://localhost:9090/api/v1/label/__name__/values" | \
  jq '.data[] | select(startswith("otel_demo"))' | head -20

# 5. Check Grafana data source
curl -s -u admin:admin-change-me \
  "http://localhost:3000/api/datasources" | jq '.[].name'
```

---

## Summary Checklist

- [x] OTel Collector deployed and receiving telemetry
- [x] Jaeger accessible with traces visible
- [x] Prometheus scraping OTel metrics
- [x] Grafana connected to both Prometheus and Jaeger
- [x] Pre-built dashboards imported
- [x] Custom dashboard created for this project
- [x] Alert rules configured (error rate, crash looping)
- [x] End-to-end trace visible (frontend → backend → db)

**Next:** [08 — Testing & Validation](08-testing-validation.md)
