# Evidence Checklist

Take screenshots of each of the following and place them in `evidence/`. Use the naming convention below.

## 1. RBAC — 3 Roles Verified

| Screenshot | Command | Expected |
|---|---|---|
| `evidence/rbac-alice.png` | `kubectl auth can-i create deployments -n demo --as alice` | `yes` |
| `evidence/rbac-alice-deny.png` | `kubectl auth can-i create deployments -n kube-system --as alice` | `no` |
| `evidence/rbac-bob.png` | `kubectl auth can-i get pods -A --as bob` | `yes` |
| `evidence/rbac-carol.png` | `kubectl auth can-i delete nodes --as carol` | `no` |

## 2. Gatekeeper — 6 Constraints Enforced

### 2a. K8sRequiredLabels

| Screenshot | Command | Expected |
|---|---|---|
| `evidence/gk-labels-deny.png` | `kubectl run test-label --image=registry.k8s.io/pause:3.10 -n payments --overrides='{"spec":{"containers":[{"name":"pause","image":"registry.k8s.io/pause:3.10","resources":{"limits":{"cpu":"100m","memory":"128Mi"}}}]}}'` | `Forbidden: missing labels: {"owner"}` |
| `evidence/gk-labels-allow.png` | `kubectl run test-label --image=registry.k8s.io/pause:3.10 -n payments --labels=owner=test --overrides='{"spec":{"containers":[{"name":"pause","image":"registry.k8s.io/pause:3.10","resources":{"limits":{"cpu":"100m","memory":"128Mi"}}}]}}'` | `pod/test-label created` |

### 2b. K8sRequiredResources

| Screenshot | Command | Expected |
|---|---|---|
| `evidence/gk-limits-deny.png` | `kubectl run no-limits --image=registry.k8s.io/pause:3.10 -n demo --labels=owner=test` | `Forbidden: container ... must specify resource limits` |

### 2c. K8sBlockLatestTag

| Screenshot | Command | Expected |
|---|---|---|
| `evidence/gk-latest-deny.png` | `kubectl run bad-tag --image=nginx:latest -n payments --labels=owner=test --restart=Never` | `Forbidden: uses :latest tag` |

### 2d. K8sBlockRootUser

| Screenshot | Command | Expected |
|---|---|---|
| `evidence/gk-rootuser-deny.png` | `kubectl run root-pod --image=registry.k8s.io/pause:3.10 -n demo --labels=owner=test --overrides='{"spec":{"containers":[{"name":"pause","image":"registry.k8s.io/pause:3.10","securityContext":{"runAsUser":0},"resources":{"limits":{"cpu":"100m","memory":"128Mi"}}}]}}'` | `Forbidden: running as root` |

### 2e. K8sBlockHostNetwork

| Screenshot | Command | Expected |
|---|---|---|
| `evidence/gk-hostnet-deny.png` | `kubectl run hostnet --image=registry.k8s.io/pause:3.10 -n demo --labels=owner=test --overrides='{"spec":{"hostNetwork":true,"containers":[{"name":"pause","image":"registry.k8s.io/pause:3.10","resources":{"limits":{"cpu":"100m","memory":"128Mi"}}}]}}'` | `Forbidden: hostNetwork: true` |

### 2f. K8sAllowedRegistries

| Screenshot | Command | Expected |
|---|---|---|
| `evidence/gk-registry-deny.png` | `kubectl run bad-reg --image=unknown.registry.io/pause:1.0 -n payments --labels=owner=test --restart=Never --overrides='{"spec":{"containers":[{"name":"pause","image":"unknown.registry.io/pause:1.0","resources":{"limits":{"cpu":"100m","memory":"128Mi"}}}]}}'` | `Forbidden: uses untrusted registry` |

## 3. ESO — External Secrets

| Screenshot | Command | Expected |
|---|---|---|
| `evidence/eso-secret.png` | `kubectl get secret db-password -n demo -o jsonpath='{.data.password}' \| base64 -d` | `P@ssw0rd123` |
| `evidence/eso-secretstore.png` | `kubectl get secretstore -n demo` | `aws-secret-store` |
| `evidence/eso-externalsecret.png` | `kubectl get externalsecret -n demo` | `db-password` |

## 4. Supply Chain — Trivy + Cosign + Sigstore

| Screenshot | Command | Expected |
|---|---|---|
| `evidence/sigstore-unsigned-deny.png` | `kubectl run unsigned --image=gcr.io/google-samples/hello-app:1.0 -n demo --restart=Never` | `Forbidden by ClusterImagePolicy` |
| `evidence/sigstore-signed-allow.png` | App deployed by ArgoCD (w10-api image) | Pod Running |
| `evidence/ci-trivy.png` | GitHub Actions workflow run (screenshot from Actions tab) | Trivy step passes |
| `evidence/ci-cosign.png` | GitHub Actions workflow run | Cosign sign step succeeds |

## 5. Challenge — Multi-Tenant `payments`

### 5a. RBAC Isolation

| Screenshot | Command | Expected |
|---|---|---|
| `evidence/challenge-rbac-create.png` | `kubectl auth can-i create deployments -n payments --as payments-dev` | `yes` |
| `evidence/challenge-rbac-demo.png` | `kubectl auth can-i create deployments -n demo --as payments-dev` | `no` |
| `evidence/challenge-rbac-secrets.png` | `kubectl auth can-i get secrets -n payments --as payments-dev` | `no` |
| `evidence/challenge-rbac-rolebindings.png` | `kubectl auth can-i create rolebindings -n payments --as payments-dev` | `no` |

### 5b. ResourceQuota

| Screenshot | Command | Expected |
|---|---|---|
| `evidence/challenge-quota.png` | `kubectl get resourcequota -n payments` | Hard limits shown |
| `evidence/challenge-quota-deny.png` | `kubectl run exceed --image=registry.k8s.io/pause:3.10 -n payments --labels=owner=test --requests=cpu=4,memory=8Gi --overrides='{"spec":{"containers":[{"name":"pause","image":"registry.k8s.io/pause:3.10","resources":{"limits":{"cpu":"4","memory":"8Gi"},"requests":{"cpu":"4","memory":"8Gi"}}}]}}'` | `Forbidden: exceeded quota` |

### 5c. NetworkPolicy

| Screenshot | Command | Expected |
|---|---|---|
| `evidence/challenge-netpol.png` | `kubectl get networkpolicy -n payments` | `default-deny-ingress` and `restrict-egress` |

### 5d. Gatekeeper Auto-Apply

| Screenshot | Command | Expected |
|---|---|---|
| `evidence/challenge-gk-deny.png` | `kubectl run bad --image=nginx:latest -n payments --restart=Never` | `Forbidden: uses :latest tag` (the same rule from Lab 1.2 applies in payments without creating a new constraint) |
| `evidence/challenge-ns-label.png` | `kubectl get ns payments -o jsonpath='{.metadata.labels}'` | `"gatekeeper":"enforced"` |

## 6. ArgoCD Applications — All Synced

| Screenshot | Command | Expected |
|---|---|---|
| `evidence/argocd-apps.png` | `argocd app list` or ArgoCD UI screenshot | All apps `Synced` and `Healthy` |
| `evidence/argocd-tree.png` | ArgoCD UI showing app dependency tree | Correct sync wave order |

## 7. Git Repo — Clean

| Screenshot | Command | Expected |
|---|---|---|
| `evidence/git-clean.png` | `grep -ri password . --include="*.yaml" --include="*.yml" \| grep -v secretStoreRef \| grep -v .git \| grep -v secretRef \| grep -v argocd` | No real secrets in git |
