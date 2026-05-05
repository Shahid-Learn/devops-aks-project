# Ultimate DevOps Project on AKS — OpenTelemetry Astronomy Shop

> A complete end-to-end DevOps project deploying the **OpenTelemetry Astronomy Shop** microservices application on **Azure Kubernetes Service (AKS)** using **Terraform**, **GitHub Actions**, **Azure Container Registry (ACR)**, and full observability with **Prometheus + Grafana + Jaeger**.

---

## Project Summary

| Item | Detail |
|------|--------|
| Application | OpenTelemetry Astronomy Shop (15+ microservices) |
| Cloud | Microsoft Azure |
| Kubernetes | AKS (Azure Kubernetes Service) |
| Infrastructure as Code | Terraform |
| Container Registry | Azure Container Registry (ACR) |
| CI/CD | GitHub Actions (Personal GitHub → Official Azure) |
| Observability | OpenTelemetry Collector, Prometheus, Grafana, Jaeger |
| Ingress | NGINX Ingress Controller |
| Secrets Management | Azure Key Vault + External Secrets Operator |

---

## Architecture Overview

```
Personal GitHub Repo
        │
        ▼ (GitHub Actions — OIDC to Azure)
  ┌─────────────────────────────────────────────────────┐
  │                   Azure (Official Account)           │
  │                                                     │
  │  ┌─────────────┐    ┌─────────────────────────────┐ │
  │  │    ACR      │    │         AKS Cluster          │ │
  │  │  (Images)   │───▶│                             │ │
  │  └─────────────┘    │  ┌──────────────────────┐   │ │
  │                     │  │   OTel Demo Namespace │   │ │
  │                     │  │  (15+ microservices)  │   │ │
  │                     │  └──────────────────────┘   │ │
  │                     │  ┌──────────────────────┐   │ │
  │                     │  │  Monitoring Namespace │   │ │
  │                     │  │ Prometheus + Grafana  │   │ │
  │                     │  └──────────────────────┘   │ │
  │                     └─────────────────────────────┘ │
  └─────────────────────────────────────────────────────┘
```

---

## Repository Structure

```
devops-aks-project/
├── README.md                          ← This file
├── docs/
│   ├── 00-project-overview.md         ← Architecture + goals
│   ├── 01-environment-setup.md        ← Local tools setup
│   ├── 02-azure-github-setup.md       ← Azure SP + OIDC + GitHub Secrets
│   ├── 03-terraform-aks.md            ← Terraform for AKS infra
│   ├── 04-containerization.md         ← Docker + ACR image builds
│   ├── 05-kubernetes-manifests.md     ← K8s manifests walkthrough
│   ├── 06-github-actions-cicd.md      ← CI/CD pipeline design
│   ├── 07-observability.md            ← OTel + Prometheus + Grafana
│   ├── 08-testing-validation.md       ← Smoke tests + validation
│   └── 09-learning-notes.md           ← Key concepts and learnings
├── terraform/
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── providers.tf
│   └── modules/
│       ├── aks/
│       ├── acr/
│       ├── networking/
│       └── keyvault/
├── k8s/
│   ├── namespaces/
│   ├── otel-demo/
│   ├── monitoring/
│   ├── ingress/
│   └── secrets/
├── .github/
│   └── workflows/
│       ├── ci-build-push.yml          ← Build & push images to ACR
│       ├── cd-deploy.yml              ← Deploy to AKS
│       ├── terraform-plan.yml         ← Terraform plan on PR
│       └── terraform-apply.yml        ← Terraform apply on merge
└── scripts/
    ├── setup-azure.sh
    ├── setup-oidc.sh
    └── verify-cluster.sh
```

---

## High-Level Steps

### Phase 1 — Foundation Setup
| # | Step | Doc |
|---|------|-----|
| 1 | Install local tools (az cli, kubectl, terraform, helm, docker) | [01-environment-setup.md](docs/01-environment-setup.md) |
| 2 | Configure Azure account + Service Principal with OIDC | [02-azure-github-setup.md](docs/02-azure-github-setup.md) |
| 3 | Create GitHub repo + configure secrets | [02-azure-github-setup.md](docs/02-azure-github-setup.md) |

### Phase 2 — Infrastructure with Terraform
| # | Step | Doc |
|---|------|-----|
| 4 | Provision Azure Resource Group, VNet, ACR | [03-terraform-aks.md](docs/03-terraform-aks.md) |
| 5 | Provision AKS cluster (with OIDC + Workload Identity) | [03-terraform-aks.md](docs/03-terraform-aks.md) |
| 6 | Terraform state backend (Azure Storage) | [03-terraform-aks.md](docs/03-terraform-aks.md) |

### Phase 3 — Application Containerization
| # | Step | Doc |
|---|------|-----|
| 7 | Fork OpenTelemetry Demo repo | [04-containerization.md](docs/04-containerization.md) |
| 8 | Build Docker images for each microservice | [04-containerization.md](docs/04-containerization.md) |
| 9 | Push images to ACR | [04-containerization.md](docs/04-containerization.md) |

### Phase 4 — Kubernetes Deployment
| # | Step | Doc |
|---|------|-----|
| 10 | Create namespaces + RBAC | [05-kubernetes-manifests.md](docs/05-kubernetes-manifests.md) |
| 11 | Deploy OpenTelemetry Collector | [05-kubernetes-manifests.md](docs/05-kubernetes-manifests.md) |
| 12 | Deploy all microservices with Helm | [05-kubernetes-manifests.md](docs/05-kubernetes-manifests.md) |
| 13 | Configure NGINX Ingress + TLS | [05-kubernetes-manifests.md](docs/05-kubernetes-manifests.md) |

### Phase 5 — CI/CD Pipeline
| # | Step | Doc |
|---|------|-----|
| 14 | GitHub Actions — CI pipeline (build, test, push) | [06-github-actions-cicd.md](docs/06-github-actions-cicd.md) |
| 15 | GitHub Actions — CD pipeline (deploy to AKS) | [06-github-actions-cicd.md](docs/06-github-actions-cicd.md) |
| 16 | GitHub Actions — Terraform automation | [06-github-actions-cicd.md](docs/06-github-actions-cicd.md) |
| 17 | Environment protection rules + approvals | [06-github-actions-cicd.md](docs/06-github-actions-cicd.md) |

### Phase 6 — Observability
| # | Step | Doc |
|---|------|-----|
| 18 | OpenTelemetry Collector configuration | [07-observability.md](docs/07-observability.md) |
| 19 | Prometheus + Grafana setup via Helm | [07-observability.md](docs/07-observability.md) |
| 20 | Jaeger for distributed tracing | [07-observability.md](docs/07-observability.md) |
| 21 | Custom dashboards + alerting | [07-observability.md](docs/07-observability.md) |

### Phase 7 — Testing & Validation
| # | Step | Doc |
|---|------|-----|
| 22 | Smoke test the application end-to-end | [08-testing-validation.md](docs/08-testing-validation.md) |
| 23 | Verify traces in Jaeger | [08-testing-validation.md](docs/08-testing-validation.md) |
| 24 | Verify metrics in Grafana | [08-testing-validation.md](docs/08-testing-validation.md) |

---

## Personal GitHub + Official Azure — Is It Possible?

**Yes — absolutely.** This is a very common setup. Here's how it works:

```
Personal GitHub Account
  └─ GitHub Actions Workflow
       └─ OIDC Federation ──▶ Azure Service Principal
                                  └─ Azure Subscription (Official Account)
                                       ├─ AKS
                                       ├─ ACR
                                       └─ Key Vault
```

You authenticate GitHub Actions to Azure using **OIDC (OpenID Connect)** — no long-lived secrets. The Azure Service Principal is created in your official Azure tenant and scoped to specific resources. GitHub never stores your Azure credentials — only a federated identity binding.

---

## Tech Stack

| Tool | Purpose | Version |
|------|---------|---------|
| Terraform | Infrastructure as Code | >= 1.7 |
| Azure CLI | Azure resource management | latest |
| kubectl | Kubernetes CLI | >= 1.29 |
| Helm | Kubernetes package manager | >= 3.14 |
| Docker | Container runtime (local builds) | latest |
| GitHub Actions | CI/CD automation | N/A |
| AKS | Managed Kubernetes | 1.29/1.30 |
| ACR | Container registry | Basic/Standard |
| OpenTelemetry Demo | Sample microservices app | 2.x |
| Prometheus Stack | Metrics collection | kube-prometheus-stack |
| Grafana | Dashboards | bundled with prom stack |
| Jaeger | Distributed tracing | bundled with OTel demo |
| NGINX Ingress | HTTP routing | latest |

---

## Getting Started

> Follow the docs in order from `01` to `08`.

```bash
# Clone this repo
git clone https://github.com/<your-username>/devops-aks-project.git
cd devops-aks-project

# Start with environment setup
cat docs/01-environment-setup.md
```

---

## Learning Outcomes

By completing this project you will have hands-on experience with:
- Provisioning production-grade AKS clusters with Terraform
- Setting up Workload Identity and OIDC authentication (no long-lived secrets)
- Building and pushing multi-architecture Docker images to ACR
- Writing end-to-end GitHub Actions CI/CD pipelines
- Deploying distributed microservices with Helm
- Implementing full observability: metrics, traces, and logs
- Managing Kubernetes secrets with Azure Key Vault
- Configuring NGINX Ingress with TLS certificates

---

*Inspired by [iam-veeramalla/ultimate-devops-project-aws](https://github.com/iam-veeramalla/ultimate-devops-project-aws) — adapted for Azure/AKS.*
