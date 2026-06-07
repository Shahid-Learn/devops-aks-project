# Section 12 - K9s Quickstart (WSL)

> Fast, practical K9s commands for daily AKS operations.

---

## 12.1 Prerequisites

- K9s installed in WSL
- kubectl configured and connected to AKS
- Current context points to your cluster

Quick check:

```bash
kubectl config current-context
kubectl get ns
```

---

## 12.2 Start K9s

```bash
k9s
```

Once open:

- `:` opens command mode
- `/` filters the current list
- `Esc` clears filter
- `q` goes back / quits
- `?` shows key bindings

---

## 12.3 List Pods For a Particular Namespace

### Option A (inside K9s)

1. Type `:ns` and press Enter.
2. Select your namespace (for example `otel-demo` or `monitoring`) and press Enter.
3. Type `:pods` and press Enter.

You now see pods only for the selected namespace.

### Option B (direct command mode)

Type this directly in K9s command mode:

```text
:pods -n otel-demo
```

Or:

```text
:po -n monitoring
```

---

## 12.4 Most Useful Day-1 Actions

From the pods view:

- `l` view logs for selected pod
- `s` toggle container shell (if shell exists)
- `d` describe selected resource
- `Shift-f` port-forward selected pod
- `Ctrl-d` delete selected resource (be careful)
- `y` copy resource name

From deployments view (`:deploy`):

- `l` logs
- `d` describe
- `r` restart rollout
- `Shift-f` port-forward service/pod behind it

---

## 12.5 Namespace Workflow You Can Reuse

Use this quick sequence each time:

1. `:ns`
2. Choose namespace
3. `:po` to inspect pod health
4. `:deploy` to inspect rollout status
5. `:svc` to check service ports
6. `:ing` to confirm ingress routes

---

## 12.6 Troubleshooting Shortcuts

### Find CrashLoopBackOff quickly

1. Open `:pods`
2. Filter using `/CrashLoopBackOff`
3. Open logs with `l`
4. Open describe with `d`

### Track pending pods

1. Open `:pods`
2. Filter with `/Pending`
3. Press `d` and inspect Events section

### Check monitoring namespace health

```text
:pods -n monitoring
```

Then inspect:

- `prometheus-*`
- `grafana-*`
- `alertmanager-*`

---

## 12.7 K9s + Terminal Pairing

Keep both open:

- Terminal 1: `k9s`
- Terminal 2: `kubectl get events -n otel-demo --sort-by=.lastTimestamp`

This pairing helps you watch UI + raw events in parallel during Helm upgrades.

---

## 12.8 Reset K9s View

If K9s looks confusing after many filters/views:

1. Press `Esc` a few times
2. Type `:xray po` for a clean pod relationship view
3. Or quit with `q` and reopen `k9s`

---

## 12.9 Optional Aliases (WSL)

Add to `~/.bashrc` or `~/.zshrc`:

```bash
alias k='kubectl'
alias k9='k9s'
```

Reload shell:

```bash
source ~/.bashrc
```
