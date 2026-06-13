# kubectl Quick Reference

> Fast-access command reference for every important Kubernetes object.
> All commands work against any namespace — replace `-n <ns>` with your target (e.g. `-n otel-demo`, `-n monitoring`).

## Index

- [Nodes](#nodes)
- [Namespaces](#namespaces)
- [Pods](#pods)
- [Deployments](#deployments)
- [ReplicaSets](#replicasets)
- [DaemonSets](#daemonsets)
- [StatefulSets](#statefulsets)
- [Services](#services)
- [Ingress](#ingress)
- [ConfigMaps](#configmaps)
- [Secrets](#secrets)
- [PersistentVolumes & PersistentVolumeClaims](#persistentvolumes--persistentvolumeclaims)
- [StorageClasses](#storageclasses)
- [ServiceAccounts](#serviceaccounts)
- [RBAC — Roles & Bindings](#rbac--roles--bindings)
- [HorizontalPodAutoscaler](#horizontalpodautoscaler)
- [Jobs & CronJobs](#jobs--cronjobs)
- [Events](#events)
- [Context & Cluster](#context--cluster)
- [Resource Usage (top)](#resource-usage-top)
- [Port Forwarding](#port-forwarding)
- [Exec & Debugging](#exec--debugging)
- [Prometheus-specific](#prometheus-specific)

---

## Nodes

```bash
# List nodes with IP, OS, container runtime
kubectl get nodes -o wide

# Watch node status changes
kubectl get nodes -w

# Describe a node (labels, taints, conditions, allocated resources)
kubectl describe node <node-name>

# Pod count per node (across all namespaces)
kubectl get pods --all-namespaces -o wide | awk 'NR>1 {print $8}' | sort | uniq -c | sort -rn

# Allocatable pod limit on a node
kubectl get node <node-name> -o jsonpath='{.status.allocatable.pods}'

# All resource capacity on a node
kubectl get node <node-name> -o jsonpath='{.status.allocatable}' | python3 -m json.tool

# Cordon a node (stop scheduling new pods onto it)
kubectl cordon <node-name>

# Uncordon
kubectl uncordon <node-name>

# Drain a node (evict pods, then cordon)
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data

# Taint a node
kubectl taint nodes <node-name> key=value:NoSchedule

# Remove a taint
kubectl taint nodes <node-name> key=value:NoSchedule-
```

---

## Namespaces

```bash
# List all namespaces
kubectl get namespaces

# Create
kubectl create namespace <name>

# Delete (removes everything inside)
kubectl delete namespace <name>

# Set default namespace for current context
kubectl config set-context --current --namespace=<name>

# List all resources in a namespace
kubectl get all -n <ns>

# List all resources across all namespaces
kubectl get all --all-namespaces
```

---

## Pods

```bash
# List pods
kubectl get pods -n <ns>
kubectl get pods -n <ns> -o wide           # Include node, IP
kubectl get pods --all-namespaces -o wide  # All namespaces

# Watch live
kubectl get pods -n <ns> -w

# Describe (scheduling events, resource limits, volumes)
kubectl describe pod <pod-name> -n <ns>

# Describe — show only Events section
kubectl describe pod <pod-name> -n <ns> | grep -A 20 "^Events:"

# Logs
kubectl logs <pod-name> -n <ns>
kubectl logs <pod-name> -n <ns> --previous        # Previous container (after crash)
kubectl logs <pod-name> -n <ns> -f                # Follow (tail)
kubectl logs <pod-name> -n <ns> --tail=100        # Last 100 lines
kubectl logs <pod-name> -n <ns> -c <container>    # Specific container in multi-container pod

# Delete (Deployment recreates it automatically)
kubectl delete pod <pod-name> -n <ns>

# Force delete a stuck pod
kubectl delete pod <pod-name> -n <ns> --grace-period=0 --force

# List pods on a specific node
kubectl get pods --all-namespaces -o wide --field-selector spec.nodeName=<node-name>

# List pods by label
kubectl get pods -n <ns> -l app=frontend

# Get pod IP
kubectl get pod <pod-name> -n <ns> -o jsonpath='{.status.podIP}'

# Get pod's node
kubectl get pod <pod-name> -n <ns> -o jsonpath='{.spec.nodeName}'
```

---

## Deployments

```bash
# List
kubectl get deployments -n <ns>
kubectl get deploy -n <ns>

# Describe
kubectl describe deployment <name> -n <ns>

# Scale
kubectl scale deployment <name> --replicas=3 -n <ns>

# Rollout status
kubectl rollout status deployment/<name> -n <ns>

# Rollout history
kubectl rollout history deployment/<name> -n <ns>

# Undo last rollout
kubectl rollout undo deployment/<name> -n <ns>

# Undo to specific revision
kubectl rollout undo deployment/<name> -n <ns> --to-revision=2

# Restart all pods in a deployment (rolling restart)
kubectl rollout restart deployment/<name> -n <ns>

# Edit in-place
kubectl edit deployment <name> -n <ns>

# Show current image tag
kubectl get deployment <name> -n <ns> -o jsonpath='{.spec.template.spec.containers[*].image}'

# Pause / resume rollout
kubectl rollout pause deployment/<name> -n <ns>
kubectl rollout resume deployment/<name> -n <ns>
```

---

## ReplicaSets

```bash
# List (includes Deployment-managed ReplicaSets)
kubectl get replicasets -n <ns>
kubectl get rs -n <ns>

# Describe
kubectl describe rs <name> -n <ns>
```

---

## DaemonSets

```bash
# List
kubectl get daemonsets -n <ns>
kubectl get ds -n <ns>

# Describe (shows node selector, tolerations, scheduling)
kubectl describe ds <name> -n <ns>

# Rollout restart
kubectl rollout restart ds/<name> -n <ns>

# Check which nodes have the DaemonSet pod
kubectl get pods -n <ns> -l <label-selector> -o wide
```

---

## StatefulSets

```bash
# List
kubectl get statefulsets -n <ns>
kubectl get sts -n <ns>

# Describe
kubectl describe sts <name> -n <ns>

# Scale
kubectl scale sts <name> --replicas=3 -n <ns>

# Rollout restart
kubectl rollout restart sts/<name> -n <ns>
```

---

## Services

```bash
# List
kubectl get services -n <ns>
kubectl get svc -n <ns>

# Describe (shows endpoints, selectors, ports)
kubectl describe svc <name> -n <ns>

# Get external IP of a LoadBalancer service
kubectl get svc <name> -n <ns> -o jsonpath='{.status.loadBalancer.ingress[0].ip}'

# Get NGINX Ingress Controller external IP
kubectl get svc ingress-nginx-controller -n ingress-nginx \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}'

# List endpoints (which pod IPs back the service)
kubectl get endpoints <name> -n <ns>
kubectl get ep <name> -n <ns>
```

---

## Ingress

```bash
# List
kubectl get ingress -n <ns>
kubectl get ing -n <ns>

# Describe (shows rules, TLS, backend services)
kubectl describe ingress <name> -n <ns>

# Get all ingress rules across all namespaces
kubectl get ingress --all-namespaces

# Apply an ingress manifest
kubectl apply -f k8s/ingress/<name>.yaml
```

---

## ConfigMaps

```bash
# List
kubectl get configmaps -n <ns>
kubectl get cm -n <ns>

# Describe (shows keys and truncated values)
kubectl describe cm <name> -n <ns>

# Show full YAML (including all values)
kubectl get cm <name> -n <ns> -o yaml

# Print a specific key's value
kubectl get cm <name> -n <ns> -o jsonpath='{.data.<key>}'

# Print multi-line key (e.g. prometheus.yaml)
kubectl get cm <name> -n <ns> -o jsonpath='{.data.prometheus\.yaml}'

# List all key names in a configmap
kubectl get cm <name> -n <ns> -o json | python3 -c "import sys,json; [print(k) for k in json.load(sys.stdin)['data']]"

# Create from a file
kubectl create cm <name> --from-file=<file> -n <ns>

# Create from literal values
kubectl create cm <name> --from-literal=key1=val1 --from-literal=key2=val2 -n <ns>

# Edit in-place
kubectl edit cm <name> -n <ns>

# Delete
kubectl delete cm <name> -n <ns>
```

---

## Secrets

```bash
# List (values are always hidden)
kubectl get secrets -n <ns>

# Describe (shows type and key names, not values)
kubectl describe secret <name> -n <ns>

# Decode a specific key (base64)
kubectl get secret <name> -n <ns> -o jsonpath='{.data.<key>}' | base64 -d

# Example — Grafana admin password
kubectl get secret grafana-admin-credentials -n monitoring \
  -o jsonpath='{.data.admin-password}' | base64 -d ; echo

# Create a generic secret from literal
kubectl create secret generic <name> \
  --from-literal=key1=val1 \
  --from-literal=key2=val2 \
  -n <ns>

# Create from a file
kubectl create secret generic <name> --from-file=<file> -n <ns>

# Apply from YAML manifest
kubectl apply -f k8s/monitoring/grafana-admin-secret.yaml

# Edit in-place (values must be base64 encoded manually)
kubectl edit secret <name> -n <ns>

# Delete
kubectl delete secret <name> -n <ns>
```

---

## PersistentVolumes & PersistentVolumeClaims

```bash
# List PVCs (namespace-scoped)
kubectl get pvc -n <ns>

# List PVs (cluster-scoped)
kubectl get pv

# Describe a PVC
kubectl describe pvc <name> -n <ns>

# Describe a PV
kubectl describe pv <name>

# Check PVC status (Bound / Pending / Lost)
kubectl get pvc -n <ns> -o wide

# Delete a PVC (caution: may lose data)
kubectl delete pvc <name> -n <ns>
```

---

## StorageClasses

```bash
# List (shows provisioner and reclaim policy)
kubectl get storageclasses
kubectl get sc

# Describe
kubectl describe sc <name>

# Check default storage class (marked with "(default)")
kubectl get sc
```

---

## ServiceAccounts

```bash
# List
kubectl get serviceaccounts -n <ns>
kubectl get sa -n <ns>

# Describe (shows secrets and tokens linked to it)
kubectl describe sa <name> -n <ns>

# Create
kubectl create serviceaccount <name> -n <ns>
```

---

## RBAC — Roles & Bindings

```bash
# Roles (namespace-scoped)
kubectl get roles -n <ns>
kubectl describe role <name> -n <ns>

# ClusterRoles (cluster-scoped)
kubectl get clusterroles
kubectl describe clusterrole <name>

# RoleBindings
kubectl get rolebindings -n <ns>
kubectl describe rolebinding <name> -n <ns>

# ClusterRoleBindings
kubectl get clusterrolebindings
kubectl describe clusterrolebinding <name>

# Check what permissions a user/SA has
kubectl auth can-i list pods -n <ns> --as <user>
kubectl auth can-i create deployments -n <ns>

# Show all permissions for current user
kubectl auth can-i --list -n <ns>
```

---

## HorizontalPodAutoscaler

```bash
# List
kubectl get hpa -n <ns>

# Describe (shows current / target metrics, min/max replicas)
kubectl describe hpa <name> -n <ns>

# Create (CPU-based)
kubectl autoscale deployment <name> --cpu-percent=50 --min=2 --max=10 -n <ns>
```

---

## Jobs & CronJobs

```bash
# List jobs
kubectl get jobs -n <ns>

# Describe a job
kubectl describe job <name> -n <ns>

# Logs from a job pod
kubectl logs -l job-name=<name> -n <ns>

# List cronjobs
kubectl get cronjobs -n <ns>
kubectl get cj -n <ns>

# Trigger a cronjob manually
kubectl create job --from=cronjob/<name> <manual-job-name> -n <ns>

# Delete a job
kubectl delete job <name> -n <ns>
```

---

## Events

```bash
# List events in a namespace (sorted by time)
kubectl get events -n <ns> --sort-by='.lastTimestamp'

# Show only Warning events
kubectl get events -n <ns> --field-selector type=Warning

# Watch events live
kubectl get events -n <ns> -w

# Events for a specific pod (via describe)
kubectl describe pod <pod-name> -n <ns> | grep -A 20 "^Events:"
```

---

## Context & Cluster

```bash
# Show all contexts
kubectl config get-contexts

# Current context
kubectl config current-context

# Switch context
kubectl config use-context <context-name>

# Set default namespace for current context
kubectl config set-context --current --namespace=<ns>

# Show cluster info
kubectl cluster-info

# Show API server version
kubectl version --short
```

---

## Resource Usage (top)

> Requires Metrics Server to be installed (included in AKS by default).

```bash
# Node CPU/memory usage
kubectl top nodes

# Pod CPU/memory usage
kubectl top pods -n <ns>

# All pods across all namespaces
kubectl top pods --all-namespaces

# Sort by memory
kubectl top pods -n <ns> --sort-by=memory

# Sort by CPU
kubectl top pods -n <ns> --sort-by=cpu
```

---

## Port Forwarding

```bash
# Forward local port to a service
kubectl port-forward svc/<name> <local-port>:<service-port> -n <ns>

# Forward local port to a pod
kubectl port-forward pod/<name> <local-port>:<container-port> -n <ns>

# Run in background
kubectl port-forward svc/<name> <local-port>:<service-port> -n <ns> &

# Common in this project
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 &
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80 &
kubectl port-forward -n otel-demo svc/jaeger 16686:16686 &
kubectl port-forward -n otel-demo svc/otel-demo-frontend-proxy 8080:8080 &

# Kill a background port-forward
kill %1   # or: lsof -ti:9090 | xargs kill
```

---

## Exec & Debugging

```bash
# Shell into a running pod
kubectl exec -it <pod-name> -n <ns> -- /bin/sh
kubectl exec -it <pod-name> -n <ns> -- /bin/bash

# Shell into a specific container (multi-container pod)
kubectl exec -it <pod-name> -n <ns> -c <container-name> -- /bin/sh

# Run a one-off command
kubectl exec <pod-name> -n <ns> -- env
kubectl exec <pod-name> -n <ns> -- cat /etc/config/app.yaml

# Ephemeral debug container (for distroless pods with no shell)
kubectl debug -it <pod-name> -n <ns> \
  --image=busybox \
  --target=<container-name>

# Run a temporary debug pod in the cluster
kubectl run debug --rm -it --image=busybox -n <ns> -- /bin/sh

# Copy a file from pod to local
kubectl cp <ns>/<pod-name>:/path/to/file ./local-file

# Copy a file to pod
kubectl cp ./local-file <ns>/<pod-name>:/path/to/file
```

---

## Prometheus-specific

```bash
# Check Prometheus targets (after port-forward to :9090)
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 &
# Open: http://localhost:9090/targets

# Decode the Prometheus generated config secret
kubectl get secret prometheus-kube-prometheus-stack-prometheus -n monitoring \
  -o jsonpath='{.data.prometheus\.yaml\.gz}' \
  | base64 -d | gunzip | grep -A 20 "job_name: otel-collector"

# Check Prometheus config via API (port-forward must be running)
curl -s http://localhost:9090/api/v1/status/config \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['yaml'])" \
  | grep -A 15 "otel-collector"

# Check active scrape targets via API
curl -s http://localhost:9090/api/v1/targets \
  | python3 -m json.tool | grep -E '"job"|"health"|"scrapeUrl"'

# List ServiceMonitors (define what Prometheus scrapes via the Operator)
kubectl get servicemonitors --all-namespaces
kubectl describe servicemonitor <name> -n monitoring

# List PrometheusRules (alert rules managed by the Operator)
kubectl get prometheusrules --all-namespaces

# Check Grafana admin password
kubectl get secret grafana-admin-credentials -n monitoring \
  -o jsonpath='{.data.admin-password}' | base64 -d ; echo
```
