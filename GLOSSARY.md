# W10 — Service & Component Glossary

## Core Platform

| Component | What it is | What it does in this project |
|---|---|---|
| **ArgoCD** | GitOps operator | Watches a Git repo and syncs Kubernetes manifests automatically. The "source of truth" is git, not kubectl. Deploy, rollback, and drift detection are all driven by commits. |
| **Argo Rollouts** | Progressive delivery controller | Like a Deployment but with canary/blue-green strategies. Instead of all pods switching at once, a Rollout shifts traffic gradually (10%→50%→100%) and auto-rolls back if metrics look bad. |
| **Gatekeeper** | Admission webhook (OPA/Rego) | Intercepts every `kubectl apply` and checks it against Rego policies before allowing it. If a pod violates a rule (no limits, root user, wrong registry), Gatekeeper rejects it with a message explaining why. |
| **External Secrets Operator (ESO)** | Kubernetes operator | Reads secrets from external APIs (AWS Secrets Manager) and creates native Kubernetes Secrets from them. Keeps secrets synced every N seconds — update the secret in AWS, it updates in K8s automatically. |
| **Sigstore Policy Controller** | Admission webhook (Cosign) | Intercepts every pod creation and verifies the container image's cryptographic signature. If the image matches a policy rule (e.g. `ghcr.io/user/w10-api@*`) but isn't signed with the matching private key, the pod is rejected. |
| **Prometheus Operator + kube-prometheus-stack** | Monitoring stack (Prometheus + AlertManager + Grafana) | Collects metrics from pods (CPU, memory, request rates), evaluates alert rules (e.g. success rate < 95%), and sends notifications (email via AlertManager). ServiceMonitor CRDs tell Prometheus which pods to scrape. |

## CI/CD & Security Tools

| Component | What it is | What it does in this project |
|---|---|---|
| **GitHub Actions** | CI/CD platform | On every push to `src/api/`: builds a Docker image, runs Trivy vulnerability scan (fail if CRITICAL or HIGH), signs the image with Cosign, bumps the version in `rollout.yaml`, and commits it back. |
| **Trivy** | Container vulnerability scanner | Scans the built image for known CVEs in OS packages and Python dependencies. Fails the build if any CRITICAL or HIGH severity vulnerabilities are found. |
| **Cosign** | Container signing tool | Signs the container image with a private key after the build. The signature is stored alongside the image in the registry. Sigstore Policy Controller uses the corresponding public key to verify the signature at admission time. |
| **Terraform** | Infrastructure-as-code | Provisions AWS resources: IAM user (`eso-sync`), access key, and a Secrets Manager secret (`w10/db-password`). Run once to bootstrap the cloud side of ESO. |

## ArgoCD Pattern

| Component | What it is | What it does in this project |
|---|---|---|
| **App-of-Apps** | ArgoCD pattern | A single "root" Application that points to a directory of child Application manifests. Instead of creating 11 apps manually in the UI, one `root.yaml` creates all of them. Adding a new app = adding a YAML file to the `argocd/apps/` directory. |
| **Sync Wave** | ArgoCD ordering mechanism | Numbers that control deploy order. Wave -1 runs first (namespaces), wave 0 runs next (infrastructure), wave 1 runs after (config), wave 2 runs last (workloads). Within the same wave, apps deploy in parallel. |

## Workload

| Component | What it is | What it does in this project |
|---|---|---|
| **Flask API** (src/api/app.py) | Simple Python web app | Returns `{"ok": true, "version": "v0.0.1"}` on `/`. Exposes `/metrics` for Prometheus. Has an `ERROR_RATE` env var that injects random 500 errors — used to test canary rollback and SLO alerts. |
| **Rollout** | Argo Rollouts CRD | Like a Deployment but with canary steps. The `app-api/rollout.yaml` defines 4 replicas, a 2-step canary (10%→50%→100%), and references an AnalysisTemplate that decides whether to proceed or abort. |
| **AnalysisTemplate** | Argo Rollouts CRD | A Prometheus query that measures success rate over 2 minutes. If the new version's success rate drops below 90%, the rollout aborts and reverts to the previous version. |
| **ServiceMonitor** | Prometheus Operator CRD | Tells Prometheus: "scrape pods with label `app: api` on port 80 at `/metrics` every 15 seconds." Without this, Prometheus wouldn't know which pods to collect metrics from. |
| **PrometheusRule** | Prometheus Operator CRD | Defines alert rules. The `SLOViolation` rule fires if the 5-minute rolling success rate drops below 95% for 2+ minutes. AlertManager sends the alert via email. |

## Challenge Components (Multi-Tenant)

| Component | What it is | What it does in this project |
|---|---|---|
| **Role + RoleBinding** | Kubernetes RBAC (namespaced) | `ClusterRole` + `ClusterRoleBinding` apply cluster-wide (any namespace). `Role` + `RoleBinding` are scoped to one namespace — the `payments-dev` user can only act inside `payments`, cannot touch `demo`. |
| **ResourceQuota** | Kubernetes resource cap | Sets hard limits on total CPU, memory, and pod count in a namespace. If team B tries to deploy more than the quota allows, the pod is rejected. |
| **LimitRange** | Kubernetes default limits | Injects default resource limits for any pod that doesn't declare its own. Without this, pods without `resources.limits` would be denied by Gatekeeper and never start. |
| **NetworkPolicy** | Kubernetes firewall rule | Controls which pods can talk to each other. Two policies: (1) default-deny ingress — blocks anyone from calling INTO payments, (2) restrict egress — allows traffic only within payments + DNS, blocking calls to `demo`. Requires a CNI that enforces policies (Calico, Cilium). |

## Namespace Scopes

```
Cluster-scoped:
  ClusterRole, ClusterRoleBinding   ← Apply to ALL namespaces
  ClusterImagePolicy                 ← Sigstore policy for ALL namespaces
  CustomResourceDefinition           ← CRDs (templates, constraints, etc.)
  Namespace                          ← Namespaces themselves

Namespace-scoped:
  Role, RoleBinding                  ← Only within their namespace
  ResourceQuota                      ← Only within their namespace
  LimitRange                         ← Only within their namespace
  NetworkPolicy                      ← Only within their namespace
  Rollout, Service, Pod, Secret      ← Regular workloads
```

## Admission Control Chain

When you run `kubectl apply -f pod.yaml`, the request goes through this pipeline before the pod is created:

```
1. Authentication   → Are you who you say you are? (kubeconfig cert/token)
2. Authorization    → Are you allowed to create pods? (RBAC check)
3. Gatekeeper       → Does the pod comply with policy? (Rego rules)
4. Sigstore         → Is the container image properly signed? (Cosign verify)
5. ResourceQuota    → Does the namespace have budget left?
6. LimitRange       → Apply default limits if pod omitted them
7. NetworkPolicy    → (Applied to traffic, not to pod creation)
8. Pod scheduled & started
```

Step 3 (Gatekeeper) and Step 4 (Sigstore) are the two admission webhooks added by this project.
