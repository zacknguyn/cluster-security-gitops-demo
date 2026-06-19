# W10 — Cluster Security GitOps Demo

GitOps setup for a production-ready Kubernetes cluster with RBAC, OPA/Gatekeeper admission policies, External Secrets Operator (ESO), Trivy + Cosign supply chain security, and a multi-tenant challenge.

## Architecture

```
GitHub (source of truth)
  │ git push
  ▼
ArgoCD (polls repo → syncs cluster state)
  │
  ├── app-common/    → demo namespace
  ├── k8s-rollouts/  → Argo Rollouts controller
  ├── kube-prometheus/→ Prometheus + AlertManager + Grafana
  ├── rbac/          → 3 ClusterRoles + bindings
  ├── gatekeeper/    → 6 constraint templates + constraints
  ├── alert/         → SLO PrometheusRule
  ├── analysis/      → AnalysisTemplate for canary
  ├── api/           → Rollout + Service + ServiceMonitor
  ├── eso-config/    → SecretStore + ExternalSecret
  ├── policies/      → ClusterImagePolicy (Sigstore)
  ├── payments/      → tenant infra (wave -1)
  └── payments-app/  → tenant workload (wave 2)
```

## What's Implemented

### RBAC — 3 Roles
| Role | Scope | Permissions |
|---|---|---|
| `developer` | ns `demo` | CRUD on pods, services, deployments |
| `sre` | cluster-wide | Same as developer + secrets, nodes, delete |
| `viewer` | cluster-wide | Read-only (get/list/watch) |

### Gatekeeper — 6 Admission Constraints
| Constraint | Rego | Blocks |
|---|---|---|
| `K8sRequiredLabels` | Custom | Pods missing `owner` label |
| `K8sRequiredResources` | Library | Pods without `resources.limits` |
| `K8sBlockLatestTag` | Library | Images using `:latest` tag |
| `K8sBlockRootUser` | Library | `runAsUser: 0` |
| `K8sBlockHostNetwork` | Library | `hostNetwork: true` |
| `K8sAllowedRegistries` | Custom | Images from untrusted registries |

All constraints use `namespaceSelector.matchLabels.gatekeeper: enforced` — any namespace with this label gets them automatically.

### External Secrets Operator
- **SecretStore**: connects to AWS Secrets Manager (`us-west-2`)
- **ExternalSecret**: syncs `w10/db-password` every 60s, no pod restart needed
- **Terraform**: provisions IAM user, access key, and Secrets Manager secret

### Supply Chain Security
- **Trivy**: scans image in CI, fails on CRITICAL/HIGH CVEs
- **Cosign**: signs image with private key after scan passes
- **Sigstore Policy Controller**: verifies signature at admission, blocks unsigned images
- **Catch-all**: `allow-all-other` passes all non-w10 images

### Multi-Tenant Challenge — `payments` namespace
| # | Task | Proof |
|---|---|---|
| 1 | RBAC least-privilege (`Role`+`RoleBinding`, no secrets) | `auth can-i` — create in payments=yes, demo=no |
| 2 | ResourceQuota + LimitRange | Quota exceeded → Forbidden |
| 3 | NetworkPolicy isolation | Default-deny ingress + restrict egress |
| 4 | Gatekeeper auto-apply via `gatekeeper: enforced` label | Existing constraints block violations in payments |

## Structure

```
.
├── app-api/                 # Team A Rollout + Service + ServiceMonitor
├── app-analysis/            # AnalysisTemplate (canary success rate)
├── app-alert/               # PrometheusRule SLO alerts
├── app-common/              # demo namespace
├── apps/payments/           # Team B Rollout + Service
├── argocd/
│   ├── apps/                # 13 child Application YAMLs
│   ├── rbac/                # ClusterRoles + bindings
│   └── gatekeeper/          # 6 ConstraintTemplates + constraints
├── eso/                     # SecretStore + ExternalSecret
├── signing/                 # ClusterImagePolicy + catch-all
├── tenants/payments/        # RBAC + quota + limitrange + netpol
├── terraform/               # AWS IAM + Secrets Manager
├── src/api/                 # Flask app source + Dockerfile
├── evidence/                # Screenshots for delivery
├── .github/workflows/       # CI/CD: build → Trivy → sign → deploy
├── GLOSSARY.md              # Component definitions
├── SYSTEMS.md               # Architecture + code walkthrough
├── SETUP.md                 # Full install guide
└── evidence.md              # Evidence checklist
```

## Quick Install

```bash
# 1. Start cluster
minikube start -p w10 --cpus=2 --memory=4096

# 2. Install ArgoCD
kubectl create ns argocd
kubectl apply --server-side -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-server

# 3. Gatekeeper & ESO operators (Helm, not ArgoCD — CRD conflict)
helm repo add gatekeeper https://open-policy-agent.github.io/gatekeeper/charts
helm install gatekeeper gatekeeper/gatekeeper -n gatekeeper-system --create-namespace
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets -n external-secrets --create-namespace
helm install sigstore policy-controller \
  https://github.com/sigstore/policy-controller/releases/download/v0.9.0/policy-controller-0.9.0.tgz \
  -n cosign-system --create-namespace

# 4. Fix Gatekeeper webhook selector after Helm install
WEBHOOK_POD_RELEASE=$(kubectl get pods -n gatekeeper-system \
  -l control-plane=controller-manager -o jsonpath='{.items[0].metadata.labels.release}')
kubectl get svc gatekeeper-webhook-service -n gatekeeper-system -o json | \
  jq --arg rel "$WEBHOOK_POD_RELEASE" '.spec.selector.release = $rel' | \
  kubectl replace -f -

# 5. Apply root app
kubectl apply -f argocd/root.yaml

# 6. Label namespaces
kubectl label ns demo gatekeeper=enforced --overwrite
kubectl label ns payments gatekeeper=enforced
```

## Verify

```bash
# RBAC
kubectl auth can-i create deployments -n demo --as alice
kubectl auth can-i delete nodes --as carol

# Gatekeeper (should be denied)
kubectl run bad --image=nginx:latest -n payments --restart=Never

# K8sRequiredLabels (should be denied - no owner label)
kubectl run test --image=registry.k8s.io/pause:3.10 -n payments \
  --overrides='{"spec":{"containers":[{"name":"pause","image":"registry.k8s.io/pause:3.10","resources":{"limits":{"cpu":"100m","memory":"128Mi"}}}]}}'

# ESO secret sync
kubectl get secret db-password -n demo -o jsonpath='{.data.password}' | base64 -d

# Sigstore (unsigned image should be denied)
kubectl run unsigned --image=gcr.io/google-samples/hello-app:1.0 -n demo --restart=Never
```

## Evidence

See `evidence.md` for the complete screenshot checklist to submit.

## Tools

- **ArgoCD** — GitOps operator, app-of-apps pattern
- **Argo Rollouts** — Canary deployments with automated analysis
- **Gatekeeper** — OPA/Rego admission webhook
- **External Secrets Operator** — AWS Secrets Manager sync
- **Sigstore Policy Controller** — Cosign signature verification
- **Trivy** — Container vulnerability scanner
- **Cosign** — Container image signing
- **Prometheus Stack** — Metrics, alerts, SLO monitoring
