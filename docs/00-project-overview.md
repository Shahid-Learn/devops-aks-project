# Section 0 — Project Overview & Architecture

> This document describes the complete project architecture, technology choices, and what you will build end-to-end.

---

## What You Will Build

A **production-grade DevOps pipeline** that:

1. Provisions AKS infrastructure with Terraform (GitOps for infra)
2. Builds and pushes Docker images to Azure Container Registry via GitHub Actions
3. Deploys 15+ microservices (OpenTelemetry Astronomy Shop) to AKS with Helm
4. Provides full observability: distributed traces (Jaeger), metrics (Prometheus), dashboards (Grafana)
5. Uses **zero stored credentials** — all Azure authentication via OIDC

---

## Complete Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        DEVELOPER WORKFLOW                                    │
│                                                                             │
│   Developer                                                                 │
│      │ git push                                                             │
│      ▼                                                                      │
│   Personal GitHub Account                                                   │
│   └── github.com/<you>/devops-aks-project                                  │
│         │                                                                   │
│         ├── src/**   ──────▶ ci-build-push.yml                             │
│         ├── terraform/** ──▶ terraform-plan/apply.yml                      │
│         └── k8s/**   ──────▶ cd-deploy.yml                                 │
└────────────────────────────────┬────────────────────────────────────────────┘
                                  │ OIDC Token Exchange
                                  │ (No passwords stored)
                                  ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                     OFFICIAL AZURE ACCOUNT                                   │
│                                                                             │
│  Resource Group: rg-devops-aks                                              │
│  ┌─────────────┐                                                            │
│  │  Azure      │  ◀── GitHub Actions pushes images                         │
│  │  Container  │                                                            │
│  │  Registry   │                                                            │
│  └──────┬──────┘                                                            │
│         │ AcrPull (managed identity)                                        │
│         ▼                                                                   │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │                    AKS Cluster                                        │   │
│  │                                                                      │   │
│  │  System Node Pool            App Node Pool (autoscale 1-3)           │   │
│  │  (2x D2s_v3)                 (D4s_v3)                                │   │
│  │  ┌─────────────┐             ┌──────────────────────────────────┐    │   │
│  │  │  CoreDNS    │             │  Namespace: otel-demo            │    │   │
│  │  │  metrics    │             │  ┌──────────────────────────┐    │    │   │
│  │  │  -server    │             │  │ frontend   (TypeScript)  │    │    │   │
│  │  │  ingress-   │             │  │ cartservice (C#)         │    │    │   │
│  │  │  nginx      │             │  │ checkoutservice (Go)     │    │    │   │
│  │  └─────────────┘             │  │ productcatalog (Go)      │    │    │   │
│  │                              │  │ recommendationservice    │    │    │   │
│  │                              │  │ ... 10+ more services   │    │    │   │
│  │                              │  │ otel-collector          │    │    │   │
│  │                              │  │ jaeger                  │    │    │   │
│  │                              │  └──────────────────────────┘    │    │   │
│  │                              │                                  │    │   │
│  │                              │  Namespace: monitoring           │    │   │
│  │                              │  ┌──────────────────────────┐    │    │   │
│  │                              │  │ Prometheus               │    │    │   │
│  │                              │  │ Grafana                  │    │    │   │
│  │                              │  │ Alertmanager             │    │    │   │
│  │                              │  └──────────────────────────┘    │    │   │
│  │                              └──────────────────────────────────┘    │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  ┌─────────────────┐  ┌──────────────────────┐                             │
│  │  Azure Key Vault │  │  Azure Storage        │                             │
│  │  (App secrets)   │  │  (Terraform state)    │                             │
│  └─────────────────┘  └──────────────────────┘                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## CI/CD Pipeline Flow

```
┌────────────────────────────────────────────────────────────────────────┐
│  Pull Request Flow                                                      │
│                                                                        │
│  PR opened/updated                                                     │
│       ├─▶ terraform-plan.yml                                           │
│       │     ├─ terraform fmt check                                     │
│       │     ├─ terraform validate                                      │
│       │     └─ terraform plan (comment on PR)                         │
│       └─▶ ci-build-push.yml (build only, no push)                     │
└────────────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────────────┐
│  Main Branch Merge Flow                                                 │
│                                                                        │
│  Merge to main                                                         │
│       ├─▶ terraform-apply.yml (if terraform/** changed)               │
│       │     ├─ Requires manual approval (production env)              │
│       │     └─ terraform apply                                         │
│       └─▶ ci-build-push.yml (if src/** changed)                       │
│             ├─ Build changed services in parallel                      │
│             ├─ Tag with git SHA                                        │
│             ├─ Push to ACR                                             │
│             ├─ Trivy vulnerability scan                                │
│             └─▶ Trigger cd-deploy.yml                                 │
│                   ├─ Requires manual approval (production env)        │
│                   ├─ helm upgrade --atomic                             │
│                   ├─ Smoke test                                        │
│                   └─ Deployment summary                                │
└────────────────────────────────────────────────────────────────────────┘
```

---

## Technology Justification

### Why AKS over EKS?
- Azure Active Directory integration is tighter (RBAC, Workload Identity)
- Azure CNI provides better network performance
- Managed control plane reduces operational overhead
- You have an existing Azure account

### Why OpenTelemetry Demo?
- Real multi-language microservices (15+ services in Go, Python, Java, C#, TypeScript, Rust, etc.)
- Already OTel-instrumented — no code changes needed to see traces/metrics
- Has a load generator built in
- Active open-source community + well-documented

### Why Helm for Deployment?
- Official Helm chart maintained by OTel project
- Easy value overrides for ACR image locations
- Atomic upgrades with auto-rollback
- Version history and rollback support

### Why OIDC for Authentication?
- No credentials to store, rotate, or leak
- Short-lived tokens (1 hour max)
- Auditable — Azure logs which federated credential was used
- Microsoft's recommended approach for GitHub → Azure integration

---

## Project Phases Summary

| Phase | What | Duration (est.) |
|-------|------|----------------|
| 1 | Environment setup + Azure/GitHub config | 1-2 hours |
| 2 | Terraform AKS provisioning | 2-3 hours |
| 3 | Containerization + ACR | 1-2 hours |
| 4 | K8s deployment + Ingress | 2-3 hours |
| 5 | GitHub Actions CI/CD pipelines | 3-4 hours |
| 6 | Observability setup | 2-3 hours |
| 7 | Testing + validation | 1-2 hours |
| **Total** | | **~12-20 hours** |

---

## Personal GitHub + Official Azure Account FAQ

**Q: Can I use my personal GitHub with my official Azure account?**
A: Yes. GitHub Actions authenticates to Azure using OIDC federation. Your Azure Service Principal is registered in your official Azure tenant. GitHub only stores 3 non-sensitive IDs (no passwords). The authentication happens via token exchange at runtime.

**Q: Will my official IT department see this project?**
A: Azure activity logs will show API calls from the GitHub Actions service principal. The Terraform state will be in your Azure subscription. If you are using a shared subscription, your resource group will be visible to subscription admins.

**Q: What Azure permissions do I need?**
A: Contributor role on a resource group is sufficient for this project. You also need the ability to create Service Principals (Application Administrator in Azure AD, or equivalent).

**Q: Can I do this from a free Azure account?**
A: AKS requires Standard_D2s_v3 VMs which are not available in the free tier. You need a Pay-As-You-Go or Visual Studio subscription. Estimated cost: ~$10-15/day while the cluster is running, less than $1/day when scaled down.
