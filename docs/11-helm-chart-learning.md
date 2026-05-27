# Section 11 - Helm Chart Learning Guide

> A practical chapter to understand Helm chart structure, how to build your own chart, and how to read the Prometheus chart family.

---

## 11.1 What a Helm Chart Is

A Helm chart is a package of Kubernetes manifests with templates and values.

Think of it like this:

- templates = reusable Kubernetes YAML with placeholders
- values.yaml = your environment-specific settings
- helm = the engine that combines templates + values and installs them as a release

Formula:

Rendered Manifests = Chart Templates + Values + Helm Functions

---

## 11.2 Standard Chart Structure

When you run `helm create myapp`, Helm generates the standard starter layout:

```text
myapp/
  Chart.yaml
  values.yaml
  .helmignore
  charts/
  templates/
    _helpers.tpl
    deployment.yaml
    service.yaml
    ingress.yaml
    serviceaccount.yaml
    hpa.yaml
    NOTES.txt
    tests/
      test-connection.yaml
```

What each part does:

- Chart.yaml: chart metadata (name, version, appVersion, dependencies)
- values.yaml: default configuration values
- templates/: Kubernetes object templates
- templates/_helpers.tpl: reusable template helper functions
- charts/: dependency charts if bundled locally

---

## 11.3 Build Your Own Chart (Fast Path)

### Step 1: Scaffold a chart

```bash
helm create demo-api
```

### Step 2: Keep only what you need

For a simple service, you can start with:

- deployment.yaml
- service.yaml
- ingress.yaml (optional)
- _helpers.tpl

Delete or disable extra templates like HPA if not needed yet.

### Step 3: Set defaults in values.yaml

Typical values you should define first:

- image.repository
- image.tag
- service.type and service.port
- resources.requests and resources.limits
- ingress.enabled and ingress.className

### Step 4: Validate before install

```bash
helm lint ./demo-api
helm template demo-api ./demo-api -f values.yaml
```

### Step 5: Install and verify

```bash
helm upgrade --install demo-api ./demo-api -n demo --create-namespace
kubectl get all -n demo
```

---

## 11.4 Prometheus Chart: Why It Feels Complex

Your confusion is normal. Prometheus setup in Kubernetes is usually not one component, but a stack.

In this project, you are using kube-prometheus-stack, which includes:

- Prometheus (metrics storage + query + alert rule engine)
- Alertmanager (alert routing and grouping)
- Grafana (dashboards)
- Prometheus Operator (manages Prometheus/Alertmanager custom resources)
- Exporters like node-exporter and kube-state-metrics

That is why one values file has sections like:

- grafana:
- prometheus:
- alertmanager:

It is one Helm release with multiple tightly integrated components.

---

## 11.5 How to Read the Prometheus Values Structure

Use this reading order when opening the values file:

1. Start with top-level keys
- prometheus
- grafana
- alertmanager
- kube-state-metrics
- prometheus-node-exporter

2. Find enable/disable switches
- enabled: true or false controls whether that component is deployed

3. Find persistence and retention
- prometheus.prometheusSpec.retention
- prometheus.prometheusSpec.storageSpec
- grafana.persistence

4. Find scrape behavior
- prometheus.prometheusSpec.scrapeInterval
- additionalScrapeConfigs

5. Find ingress and access patterns
- grafana.ingress
- service types and ports

Tip:
Render first, then inspect output:

```bash
helm template kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values k8s/monitoring/prometheus-values.yaml > /tmp/prom-rendered.yaml
```

Then inspect:

```bash
grep -n "kind: Prometheus\|kind: Alertmanager\|kind: Ingress\|kind: Service" /tmp/prom-rendered.yaml
```

---

## 11.6 Standard Template You Can Reuse

Yes, there is a standard template you can use.

### Option A (recommended): Helm built-in starter

```bash
helm create my-service
```

This is the most common baseline for internal app charts.

### Option B: Use a production-grade community chart

For common tools (Redis, Prometheus, NGINX, etc.), use official charts and only maintain your own values file.

Examples:

- prometheus-community/kube-prometheus-stack
- ingress-nginx/ingress-nginx
- bitnami/* charts

This usually reduces maintenance and upgrade risk.

---

## 11.7 Practical Pattern for Your Project

For this AKS project, the strongest pattern is:

- Keep upstream chart templates unchanged
- Store only your override files in repo:
  - k8s/otel-demo/values.yaml
  - k8s/monitoring/prometheus-values.yaml
- Use helm upgrade --install with pinned chart versions
- Render and lint before apply in CI

This gives you:

- easier upgrades
- fewer merge conflicts with upstream templates
- clear separation between vendor chart and your environment settings

---

## 11.8 Minimal Internal Chart Template (Copy Pattern)

If you want to build your own chart for an internal microservice, use this baseline design:

- Chart.yaml with semantic versioning
- values.yaml with image, service, ingress, resources, env
- templates/deployment.yaml using helpers for labels and naming
- templates/service.yaml for stable networking
- templates/ingress.yaml gated by ingress.enabled

Validation checklist:

```bash
helm lint ./my-service
helm template my-service ./my-service -f values.yaml
kubectl apply --dry-run=client -f <(helm template my-service ./my-service -f values.yaml)
```

---

## 11.9 Recommended Learning Resources

Helm fundamentals:

- Helm docs (official): https://helm.sh/docs/
- Chart template guide: https://helm.sh/docs/chart_template_guide/
- Best practices: https://helm.sh/docs/chart_best_practices/

Prometheus stack understanding:

- kube-prometheus-stack chart page: https://artifacthub.io/packages/helm/prometheus-community/kube-prometheus-stack
- Prometheus Operator docs: https://prometheus-operator.dev/
- Prometheus alerting docs: https://prometheus.io/docs/alerting/latest/alertmanager/

Hands-on practice:

- Use helm show values to study upstream defaults before overriding
- Use helm template on every change
- Keep a small sandbox namespace for experiments

---

## 11.10 Quick Command Cheat Sheet

```bash
# Explore chart defaults
helm show values prometheus-community/kube-prometheus-stack > defaults-prom.yaml

# Compare your overrides to defaults
# (manual diff in editor)

# Lint and render
helm lint ./mychart
helm template myrel ./mychart -f values.yaml

# Safe install with wait
helm upgrade --install myrel ./mychart -n myns --create-namespace --wait --timeout 10m

# Troubleshoot release
helm status myrel -n myns
helm get values myrel -n myns
helm get manifest myrel -n myns | head -100
```

---

## 11.11 Common Mistakes (and Fix)

Mistake: editing upstream templates directly inside downloaded chart folders.
Fix: keep templates upstream, override only values in your repo.

Mistake: deploying without rendering.
Fix: always run helm template before upgrade --install.

Mistake: setting a global image repository and forgetting sidecars.
Fix: check final pod images with kubectl jsonpath after deploy.

Mistake: no persistence for Prometheus/Grafana.
Fix: configure storageClassName and PVC sizes explicitly.

---

## 11.12 What to Practice Next

1. Create a tiny internal chart with helm create.
2. Add Deployment + Service + Ingress only.
3. Add one environment variable and one secret reference.
4. Add resource requests/limits.
5. Install in a temporary namespace and test upgrade/rollback.

After this, reading larger charts like kube-prometheus-stack becomes much easier.
