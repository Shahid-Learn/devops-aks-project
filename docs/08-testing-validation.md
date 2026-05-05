# Section 8 — Testing & Validation

> End-to-end validation of the complete setup: infrastructure, deployments, CI/CD, and observability.

---

## 8.1 Validation Checklist

Run through this checklist after completing each phase.

### Phase 1 — Infrastructure

```bash
# ✅ AKS cluster is running
kubectl get nodes
# Expected: 2+ nodes in Ready state

# ✅ Node pools exist
kubectl get nodes --show-labels | grep "workload-type"
# Expected: system and app node pool labels

# ✅ ACR is accessible
az acr login --name acrdevopsproject
docker pull acrdevopsproject.azurecr.io/frontend:latest
# Expected: Image pulls successfully

# ✅ Terraform state is stored remotely
az storage blob list \
  --account-name <storage-account> \
  --container-name tfstate \
  --output table
# Expected: aks-project.tfstate blob exists
```

---

### Phase 2 — Application Deployment

```bash
# ✅ All OTel Demo pods are running
kubectl get pods -n otel-demo
# Expected: All pods in Running state (may take 3-5 min)

# ✅ No crash loops
kubectl get pods -n otel-demo | grep -E "CrashLoop|Error|OOMKilled"
# Expected: No output

# ✅ Services are reachable
kubectl get services -n otel-demo
# Expected: All services have ClusterIP

# ✅ Ingress has external IP
kubectl get ingress -n otel-demo
kubectl get service ingress-nginx-controller -n ingress-nginx
# Expected: External IP assigned

# ✅ Frontend loads
INGRESS_IP=$(kubectl get service ingress-nginx-controller \
  -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -s -o /dev/null -w "%{http_code}" http://$INGRESS_IP
# Expected: 200
```

---

### Phase 3 — CI/CD Pipeline

```bash
# ✅ GitHub Actions secrets are set
gh secret list
# Expected: AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID

# ✅ Workflows exist
ls .github/workflows/
# Expected: terraform-plan.yml, terraform-apply.yml, ci-build-push.yml, cd-deploy.yml

# ✅ Trigger a test CI run
git checkout -b test/ci-validation
echo "# test" >> src/frontend/README.md
git add . && git commit -m "test: trigger CI"
git push -u origin test/ci-validation
gh pr create --title "Test CI" --body "Testing CI pipeline"
# Go to GitHub Actions tab and verify the workflow runs

# ✅ Verify OIDC works
# Check the workflow run logs — look for "Login with OIDC" success message
```

---

### Phase 4 — Observability

```bash
# ✅ OTel Collector is receiving data
kubectl logs -n otel-demo \
  -l app.kubernetes.io/name=otelcol \
  --tail=20 | grep -E "traces|metrics|error"

# ✅ Jaeger has traces
kubectl port-forward -n otel-demo svc/otel-demo-jaeger-query 16686:16686 &
sleep 2
curl -s "http://localhost:16686/api/services" | jq '.data | length'
# Expected: More than 5 services

# ✅ Prometheus has metrics
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 &
sleep 2
curl -s "http://localhost:9090/api/v1/query?query=up" | \
  jq '.data.result | length'
# Expected: Multiple targets

# ✅ Grafana is accessible
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80 &
sleep 2
curl -s -o /dev/null -w "%{http_code}" \
  -u admin:admin-change-me http://localhost:3000/api/health
# Expected: 200
```

---

## 8.2 Full End-to-End Smoke Test Script

```bash
#!/bin/bash
# scripts/smoke-test.sh

set -euo pipefail

INGRESS_IP=$(kubectl get service ingress-nginx-controller \
  -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

BASE_URL="http://$INGRESS_IP"
PASS=0
FAIL=0

test_endpoint() {
  local name="$1"
  local url="$2"
  local expected_code="${3:-200}"

  STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$url" --max-time 15 || echo "000")

  if [ "$STATUS" -eq "$expected_code" ]; then
    echo "✅ $name: HTTP $STATUS"
    ((PASS++))
  else
    echo "❌ $name: HTTP $STATUS (expected $expected_code)"
    ((FAIL++))
  fi
}

echo "=== Smoke Tests ==="
echo "Base URL: $BASE_URL"
echo ""

# Frontend tests
test_endpoint "Homepage"              "$BASE_URL/"
test_endpoint "Product catalog API"   "$BASE_URL/api/products"
test_endpoint "Cart API"              "$BASE_URL/api/cart"
test_endpoint "Recommendations"       "$BASE_URL/api/recommendations"

echo ""
echo "=== Results ==="
echo "✅ Passed: $PASS"
echo "❌ Failed: $FAIL"
echo ""

if [ $FAIL -gt 0 ]; then
  echo "SMOKE TESTS FAILED"
  exit 1
else
  echo "ALL SMOKE TESTS PASSED"
fi
```

---

## 8.3 Load Test (Optional)

Use the built-in load generator or `k6`:

```bash
# Option 1: Check the loadgenerator pod (already running)
kubectl logs -n otel-demo -l app.kubernetes.io/name=loadgenerator --tail=20

# Option 2: k6 load test
cat > /tmp/loadtest.js <<'EOF'
import http from 'k6/http';
import { check, sleep } from 'k6';

export const options = {
  vus: 10,
  duration: '60s',
  thresholds: {
    http_req_failed: ['rate<0.01'],     // Error rate < 1%
    http_req_duration: ['p(99)<2000'],  // P99 < 2s
  },
};

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';

export default function () {
  const responses = http.batch([
    ['GET', `${BASE_URL}/`],
    ['GET', `${BASE_URL}/api/products`],
  ]);

  check(responses[0], { 'homepage OK': (r) => r.status === 200 });
  check(responses[1], { 'products OK': (r) => r.status === 200 });
  sleep(1);
}
EOF

# Run with k6
INGRESS_IP=$(kubectl get service ingress-nginx-controller \
  -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

docker run --rm -e BASE_URL="http://$INGRESS_IP" \
  -v /tmp/loadtest.js:/home/k6/script.js \
  grafana/k6 run /home/k6/script.js
```

---

## 8.4 Troubleshooting Guide

### Pod won't start (ImagePullBackOff)

```bash
# Check the error
kubectl describe pod <pod-name> -n otel-demo | grep -A 10 "Events:"

# Verify ACR attachment to AKS
az aks check-acr \
  --name aks-devops-project \
  --resource-group rg-devops-aks \
  --acr acrdevopsproject

# Fix: Ensure AcrPull role is assigned
az role assignment list \
  --assignee $(az aks show \
    --name aks-devops-project \
    --resource-group rg-devops-aks \
    --query "identityProfile.kubeletidentity.objectId" -o tsv) \
  --role AcrPull \
  --output table
```

### GitHub Actions OIDC fails

```bash
# Common errors:
# "AADSTS70011: The provided request must include a 'scope' input parameter"
# Fix: Make sure 'id-token: write' permission is set in workflow

# "Specified federated credential does not exist"
# Fix: Check the subject in federated credential matches exactly
az ad app federated-credential list --id <app-id> -o table

# Subject format for main branch:
# repo:<org>/<repo>:ref:refs/heads/main
```

### Helm deployment fails

```bash
# Check Helm release status
helm list -n otel-demo
helm history otel-demo -n otel-demo

# Check events
kubectl get events -n otel-demo --sort-by='.lastTimestamp' | tail -20

# Rollback if needed
helm rollback otel-demo -n otel-demo

# Debug with dry-run
helm upgrade --install otel-demo open-telemetry/opentelemetry-demo \
  --namespace otel-demo \
  --values k8s/otel-demo/values.yaml \
  --dry-run
```

### OTel Collector not receiving data

```bash
# Check collector logs
kubectl logs -n otel-demo \
  -l app.kubernetes.io/name=otelcol -f

# Check if services are sending to the right endpoint
kubectl exec -n otel-demo -it <any-pod> -- \
  curl -s http://otel-demo-otelcol:4318/v1/traces \
  -H "Content-Type: application/json" \
  -d '{}' 
# Expected: 400 Bad Request (means collector is reachable)
```

---

## 8.5 Cost Cleanup

When done with a learning session, scale down to save costs:

```bash
# Scale app node pool to 0
az aks nodepool scale \
  --resource-group rg-devops-aks \
  --cluster-name aks-devops-project \
  --name app \
  --node-count 0

# Scale system pool to minimum
az aks nodepool scale \
  --resource-group rg-devops-aks \
  --cluster-name aks-devops-project \
  --name system \
  --node-count 1

# Or completely destroy and recreate with Terraform
# (Only if you're done — Terraform recreates in ~10 min)
cd terraform && terraform destroy
```

---

## Summary Checklist

- [x] All infrastructure validation tests pass
- [x] All pods running (no crash loops)
- [x] Frontend accessible via Ingress
- [x] CI pipeline triggers on code push
- [x] CD pipeline deploys to AKS successfully
- [x] Jaeger has distributed traces
- [x] Prometheus collecting metrics
- [x] Grafana dashboards populated
- [x] Smoke tests passing
- [x] Troubleshooting guide reviewed

**Next:** [09 — Learning Notes](09-learning-notes.md)
