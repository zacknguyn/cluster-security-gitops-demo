# W10 Evidence Pack — Secure & Operate: RBAC, Gatekeeper, ESO, Supply Chain

This document is the submission checklist for the W10 project. It records what was built, the commands used to prove it, what each result means, and the screenshots to capture.

## Project Scope

The project demonstrates a production-ready Kubernetes cluster with multi-layer security:

- **RBAC** — 3 roles (developer, sre, viewer) with ClusterRole/RoleBinding, verified via `kubectl auth can-i`.
- **Gatekeeper** — 6 OPA/Rego admission constraints enforced via `namespaceSelector` (label `gatekeeper: enforced`):
  - `K8sRequiredLabels` — requires `owner` label on every pod
  - `K8sRequiredResources` — requires `resources.limits`
  - `K8sBlockLatestTag` — blocks `:latest` tag
  - `K8sBlockRootUser` — blocks `runAsUser: 0`
  - `K8sBlockHostNetwork` — blocks `hostNetwork: true`
  - `K8sAllowedRegistries` — custom Rego, only allows trusted registries
- **External Secrets Operator (ESO)** — AWS Secrets Manager integration with 60s refresh, no pod restart needed
- **Supply Chain Security** — Trivy scan + Cosign sign in CI, Sigstore Policy Controller verifies at admission
- **Multi-Tenant Challenge** — `payments` namespace with full isolation: RBAC least-privilege, ResourceQuota, LimitRange, NetworkPolicy, and auto-inheriting Gatekeeper constraints

## Screenshot Index

Save screenshots under `evidence/`. Use the exact filenames below.

| ID | Screenshot | What To Capture | Why It Matters |
|---|---|---|---|
| 01 | `evidence/argocd-apps.png` | ArgoCD Applications page or `kubectl get app -n argocd` showing all apps Synced/Healthy | Proves GitOps app-of-apps deployment |
| 02 | `evidence/rbac-all.png` | Terminal showing 4 `kubectl auth can-i` commands for alice, bob, carol | Proves RBAC works |
| 03 | `evidence/gatekeeper-all.png` | Terminal showing at least 2-3 constraint denials (labels, latest, limits) | Proves Gatekeeper enforcement |
| 04 | `evidence/gatekeeper-custom.png` | Terminal showing `K8sAllowedRegistries` or `K8sRequiredLabels` custom Rego denies | Proves custom Rego works |
| 05 | `evidence/eso-secret.png` | Terminal showing `kubectl get secret db-password -n demo ... \| base64 -d` returning `P@ssw0rd123` | Proves ESO sync from AWS |
| 06 | `evidence/sigstore-deny.png` | Terminal showing unsigned image rejected by Sigstore | Proves supply chain admission control |
| 07 | `evidence/challenge-rbac.png` | 4 `auth can-i` commands for `payments-dev` | Proves tenant RBAC isolation |
| 08 | `evidence/challenge-quota.png` | ResourceQuota + LimitRange in payments namespace | Proves resource caps enforced |
| 09 | `evidence/challenge-netpol.png` | `kubectl get networkpolicy -n payments` | Proves network isolation policies exist |
| 10 | `evidence/challenge-gk-auto.png` | Violation in payments blocked by existing Gatekeeper constraint (no new rules) | Proves constraint auto-apply via label selector |

## Lab 1 — RBAC + Gatekeeper (Morning)

### RBAC Evidence

Three roles deployed via GitOps:

| Role | Scope | Permissions |
|---|---|---|
| `developer` (alice) | ns `demo` | CRUD on pods, services, deployments |
| `sre` (bob) | cluster-wide | Same + secrets, nodes, delete |
| `viewer` (carol) | cluster-wide | Read-only (get/list/watch) |

Run these commands:

```bash
kubectl auth can-i create deployments -n demo --as alice
kubectl auth can-i create deployments -n kube-system --as alice
kubectl auth can-i get pods -A --as bob
kubectl auth can-i delete nodes --as carol
```

Expected results:
- Alice can create in `demo` → `yes`
- Alice cannot create in `kube-system` → `no`
- Bob can get pods cluster-wide → `yes`
- Carol cannot delete nodes → `no`

Screenshot:

- `evidence/rbac-all.png`

Take this screenshot:

1. Terminal showing all 4 `kubectl auth can-i` commands with their expected results.

![RBAC verification](evidence/rbac-all.png)

### Gatekeeper Evidence

Six constraints active. All use `namespaceSelector.matchLabels.gatekeeper: enforced` on the `demo` and `payments` namespaces.

Verify constraints are present:

```bash
kubectl get constraints
```

Expected result — all 6 constraints listed:

```
k8sallowedregistries.constraints.gatekeeper.sh/demo-trusted-registries
k8sblockhostnetwork.constraints.gatekeeper.sh/demo-no-host-network
k8sblocklatesttag.constraints.gatekeeper.sh/demo-no-latest-tag
k8sblockrootuser.constraints.gatekeeper.sh/demo-no-root-user
k8srequiredlabels.constraints.gatekeeper.sh/demo-must-have-owner
k8srequiredresources.constraints.gatekeeper.sh/demo-must-have-limits
```

Test each constraint (run any 2-3 to demonstrate):

```bash
# K8sRequiredLabels — no owner label
kubectl run test-label --image=registry.k8s.io/pause:3.10 -n payments \
  --overrides='{"spec":{"containers":[{"name":"pause","image":"registry.k8s.io/pause:3.10","resources":{"limits":{"cpu":"100m","memory":"128Mi"}}}]}}'
  → Forbidden: missing labels: {"owner"}

# K8sBlockLatestTag — :latest image
kubectl run bad-tag --image=nginx:latest -n payments --labels=owner=test --restart=Never
  → Forbidden: uses :latest tag

# K8sRequiredResources — no resource limits
kubectl run no-limits --image=registry.k8s.io/pause:3.10 -n demo --labels=owner=test
  → Forbidden: must specify resource limits

# K8sAllowedRegistries — untrusted registry (custom Rego)
kubectl run bad-reg --image=unknown.registry.io/pause:1.0 -n payments --labels=owner=test \
  --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"pause","image":"unknown.registry.io/pause:1.0","resources":{"limits":{"cpu":"100m","memory":"128Mi"}}}]}}'
  → Forbidden: uses untrusted registry
```

Explanation:

- `K8sRequiredLabels` uses a custom Rego rule. The set comprehension requires `some i` syntax (`{label | some i; label := input.parameters.labels[i]}`) and the `provided` value must be a set of keys, not the raw labels object.
- `K8sAllowedRegistries` is the other custom Rego rule, whitelisting only `ghcr.io/zacknguyn/`, `quay.io/`, `docker.io/`, and `registry.k8s.io/`.
- `namespaceSelector` replaces hardcoded `namespaces: ["demo"]` — any namespace with `gatekeeper: enforced` label auto-inherits all constraints.

Screenshots:

- `evidence/gatekeeper-all.png`
- `evidence/gatekeeper-custom.png`

Take these screenshots:

1. Terminal showing 2-3 denial results side by side (labels, latest, limits).

![Gatekeeper constraints denying violations](evidence/gatekeeper-all.png)

2. Terminal showing custom Rego denial (required labels or registry whitelist).

![Custom Rego policy enforcement](evidence/gatekeeper-custom.png)

## Lab 2 — ESO + Supply Chain (Afternoon)

### ESO Evidence

External Secrets Operator syncs `w10/db-password` from AWS Secrets Manager into a K8s Secret every 60 seconds.

Check the synced secret:

```bash
kubectl get secret db-password -n demo -o jsonpath='{.data.password}' | base64 -d
```

Expected result:

```
P@ssw0rd123
```

Verify the infrastructure:

```bash
kubectl get secretstore -n demo
kubectl get externalsecret -n demo
```

Expected:

```
NAME              AGE   STATUS
aws-secret-store   Xm   Valid

NAME           AGE   STATUS
db-password    Xm   SecretSynced
```

Explanation:

- `SecretStore` defines the AWS connection (region `us-west-2`, auth via `aws-secret` K8s Secret containing access key).
- `ExternalSecret` maps AWS key `w10/db-password` → K8s Secret `db-password` with `refreshInterval: 60s`.
- When the password is rotated in AWS, ESO updates the K8s Secret automatically. Pods mounting via volume see the new value without restart.

Screenshot:

- `evidence/eso-secret.png`

Take this screenshot:

1. Terminal showing `kubectl get secret db-password ... | base64 -d` returning `P@ssw0rd123`.

![ESO secret synced from AWS](evidence/eso-secret.png)

### Supply Chain Evidence

Trivy scans the image in CI (fails on CRITICAL/HIGH). Cosign signs the image after scan passes. Sigstore Policy Controller verifies the signature at admission.

Test unsigned image rejection:

```bash
kubectl run unsigned --image=gcr.io/google-samples/hello-app:1.0 -n demo --restart=Never
```

Expected result:

```
Error from server (Forbidden): admission webhook "policy.sigstore.dev" denied the request: ...
```

The signed `w10-api` image (deployed by ArgoCD) should run without issues:

```bash
kubectl get pods -n demo -l app=api
```

Expected: pod `Running`.

Explanation:

- `ClusterImagePolicy` `w10-image-policy` matches `ghcr.io/zacknguyn/w10-api@*` and requires a valid Cosign signature.
- `ClusterImagePolicy` `allow-all-other` matches `**` with `static: {action: pass}` to avoid blocking non-w10 images that power the platform itself.
- Only namespaces with label `policy.sigstore.dev/include=true` are checked.
- The CI pipeline at `.github/workflows/build-push.yml` runs Trivy → then Cosign sign → then pushes the signed image.

Screenshot:

- `evidence/sigstore-deny.png`

Take this screenshot:

1. Terminal showing `kubectl run unsigned ...` being rejected by `policy.sigstore.dev`.

![Sigstore blocking unsigned image](evidence/sigstore-deny.png)

## Challenge — Multi-Tenant Isolation (Take-home 24h)

### Deliverable Structure

```
tenants/payments/   # ns · rbac · quota · limitrange · netpol
apps/payments/      # Rollout + Service for team B
argocd/apps/        # payments.yaml (infra wave -1) + payments-app.yaml (app wave 2)
evidence/           # 4 screenshots below
README.md           # explanation (2 câu vì sao)
```

### Proof 1 — RBAC Isolation

`payments-dev` user must be scoped to `payments` namespace only, with no access to secrets or rolebindings.

```bash
kubectl auth can-i create deployments -n payments --as payments-dev
kubectl auth can-i create deployments -n demo --as payments-dev
kubectl auth can-i get secrets -n payments --as payments-dev
kubectl auth can-i create rolebindings -n payments --as payments-dev
```

Expected:

```
yes
no
no
no
```

Why this works:

- `Role` (namespaced) instead of `ClusterRole` — user cannot act outside `payments`.
- `RoleBinding` binds within namespace — cannot touch `demo` at all.
- Resources `secrets` and `rolebindings` are excluded from the Role rules — prevents privilege escalation.

Screenshot:

- `evidence/challenge-rbac.png`

Take this screenshot:

1. Terminal showing all 4 `auth can-i` commands for `payments-dev` with expected results.

![Challenge RBAC isolation](evidence/challenge-rbac.png)

### Proof 2 — ResourceQuota + LimitRange

ResourceQuota caps total resources. LimitRange injects defaults so pods without `resources.limits` pass Gatekeeper.

```bash
kubectl get resourcequota -n payments
kubectl get limitrange -n payments
```

Expected:

```
NAME             REQUEST                                                        LIMIT
payments-quota   pods: X/10, requests.cpu: X/2, requests.memory: X/2Gi   ...

NAME              AGE
payments-limits   Xm
```

Test quota enforcement:

```bash
kubectl run exceed --image=registry.k8s.io/pause:3.10 -n payments \
  --labels=owner=test --requests=cpu=4,memory=8Gi \
  --overrides='{"spec":{"containers":[{"name":"pause","image":"registry.k8s.io/pause:3.10","resources":{"limits":{"cpu":"4","memory":"8Gi"},"requests":{"cpu":"4","memory":"8Gi"}}}]}}'
```

Expected:

```
Error from server (Forbidden): exceeded quota: payments-quota, requested: ...
```

Explanation:

- `ResourceQuota` hard limits: 2 CPU requests / 4 CPU limits / 2Gi memory requests / 4Gi memory limits / 10 pods.
- `LimitRange` default: 200m CPU / 256Mi memory limits, 100m CPU / 128Mi memory requests.
- Without LimitRange, any pod lacking `resources.limits` would be denied by Gatekeeper and never run.

Screenshot:

- `evidence/challenge-quota.png`

Take this screenshot:

1. Terminal showing `kubectl get resourcequota -n payments` and the exceeded quota denial.

![Challenge quota enforcement](evidence/challenge-quota.png)

### Proof 3 — NetworkPolicy Isolation

Two policies isolate `payments`:

- `default-deny-ingress` — blocks all inbound traffic to payments pods.
- `restrict-egress` — only allows traffic within payments namespace + DNS, blocking calls to `demo`.

```bash
kubectl get networkpolicy -n payments
```

Expected:

```
NAME                   POD-SELECTOR   AGE
default-deny-ingress   <none>         Xm
restrict-egress        <none>         Xm
```

Test (if CNI enforces — minikube Docker driver does not; requires `--cni=calico`):

```bash
kubectl run test-curl --image=curlimages/curl:latest -n payments \
  --labels=owner=test --rm -it --restart=Never -- \
  curl -s --connect-timeout 3 http://api.demo.svc
```

Expected (with Calico CNI): `Connection timed out` or no response.

Explanation:

- Ingress vs Egress: `default-deny-ingress` blocks others from calling INTO payments, `restrict-egress` blocks payments from calling OUT to `demo`. Both are needed for full bidirectional isolation.
- Minikube with Docker driver does not enforce NetworkPolicy. For true enforcement, minikube must start with `--cni=calico`.
- The egress rule explicitly allows traffic to `kube-dns` on port 53 (UDP/TCP) so DNS resolution still works within the namespace.

Screenshot:

- `evidence/challenge-netpol.png`

Take this screenshot:

1. Terminal showing `kubectl get networkpolicy -n payments` listing both policies.

![Challenge network policies](evidence/challenge-netpol.png)

### Proof 4 — Gatekeeper Auto-Apply (Most Important)

Existing constraints automatically apply to `payments` because of the `gatekeeper: enforced` label. No new ConstraintTemplate or Constraint was created for this namespace.

Check the label:

```bash
kubectl get ns payments -o jsonpath='{.metadata.labels}'
```

Expected:

```
{"gatekeeper":"enforced","kubernetes.io/metadata.name":"payments"}
```

Verify constraint files — they use `namespaceSelector`, not `namespaces`:

```bash
kubectl get k8srequiredlabels demo-must-have-owner -o yaml | grep -A5 "match:"
```

Expected: contains `namespaceSelector`, not `namespaces`.

Test that existing constraints block violations in `payments`:

```bash
# Blocked by K8sBlockLatestTag (same rule as Lab 1.2, no new rule created)
kubectl run bad --image=nginx:latest -n payments --restart=Never
  → Forbidden: uses :latest tag

# Blocked by K8sRequiredLabels (custom Rego, no new rule)
kubectl run test --image=registry.k8s.io/pause:3.10 -n payments \
  --overrides='{"spec":{"containers":[{"name":"pause","image":"registry.k8s.io/pause:3.10","resources":{"limits":{"cpu":"100m","memory":"128Mi"}}}]}}'
  → Forbidden: missing labels: {"owner"}
```

Why this works:

- Original constraints used `namespaces: ["demo"]` — only applied to `demo`.
- Changed to `namespaceSelector: matchLabels: {gatekeeper: enforced}` — matches any namespace with the label.
- `payments` namespace has `gatekeeper: enforced` → all 6 constraints fire automatically.
- To onboard a third team: `kubectl create ns team-c && kubectl label ns team-c gatekeeper=enforced`. Done.

Screenshot:

- `evidence/challenge-gk-auto.png`

Take this screenshot:

1. Terminal showing a violation in `payments` being blocked by an existing constraint (e.g. `:latest` tag or missing `owner` label).

![Gatekeeper auto-apply in payments namespace](evidence/challenge-gk-auto.png)

## ArgoCD — All Apps Evidence

Show that the entire platform is GitOps-managed:

```bash
kubectl get app -n argocd
```

Expected — all apps `Synced` and `Healthy`:

```
NAME                  SYNC STATUS   HEALTH STATUS
alert                 Synced        Healthy
analysis              Synced        Healthy
api                   Synced        Healthy
argo-rollouts         Synced        Healthy
common                Synced        Healthy
gatekeeper            Synced        Healthy
gatekeeper-operator   OutOfSync     Healthy    (managed via Helm CLI)
kube-prometheus-stack Synced        Healthy
payments              Synced        Healthy
payments-app          Synced        Healthy
rbac                  Synced        Healthy
root                  Synced        Healthy
```

Explanation:

- `root` is the app-of-apps root, watches `argocd/apps/`.
- `gatekeeper-operator` is OutOfSync by design — the operator is installed via Helm CLI to avoid CRD `status.storedVersions` conflicts.
- `syncPolicy.automated.prune: true` and `selfHeal: true` mean drift is corrected back to Git.
- Sync waves: -1 (namespaces) → 0 (infrastructure) → 1 (config) → 2 (workloads).

Screenshot:

- `evidence/argocd-apps.png`

Take this screenshot:

1. Terminal showing `kubectl get app -n argocd` with all apps Synced/Healthy, or the ArgoCD UI Applications page.

![ArgoCD applications synced](evidence/argocd-apps.png)

## Important Lessons Learned

| Problem | Root Cause | Fix |
|---|---|---|
| K8sRequiredLabels constraint never fired | Rego set comprehension `{label | label = input.parameters.labels[_]}` does not iterate in Gatekeeper 3.17.0; `provided := input.review.object.metadata.labels` is an object, not a set | Use `{label | some i; label := input.parameters.labels[i]}` and `provided := {key | input.review.object.metadata.labels[key]}` |
| ArgoCD reverted in-cluster Rego fix | Auto-sync overwrote manual changes before git push | Commit + push first, then verify ArgoCD picks it up |
| Gatekeeper webhook not enforcing after Helm install | Webhook service selector mismatched pod release label | Update selector via `kubectl get svc ... \| jq ... \| kubectl replace -f -` |
| Minikube DNS broken after host restart | Docker bridge networking stale; quay.io unreachable | `minikube delete && minikube start` is the only reliable fix |
| Unsigned image error also blocks platform pods | Sigstore policy matched all images | Add catch-all `allow-all-other` with `static: {action: pass}` |
| Namespace label ordering | Labeling namespace before image is signed blocks all pods | Label namespace `policy.sigstore.dev/include=true` only after images are signed |
| AWS access key leaked in git | Key committed in `aws-secret.yaml` | Amend commit, rotate key, add to `.gitignore` |
| ESO SecretStore rejected | Wrong region or access key permissions | Verify region and IAM policy allows `secretsmanager:GetSecretValue` |
| Pod creation blocked by quota even when under limit | Previous test pods consume quota without being cleaned | `kubectl delete pods --all -n payments --force` |
| Rollout stuck in Progressing | imagePullPolicy: IfNotPresent + registry unreachable | Pre-load images via `docker save \| minikube cp \| ctr -n k8s.io images import` |
