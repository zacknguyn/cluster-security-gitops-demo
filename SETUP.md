# W10 Cluster Security + GitOps Demo — Full Setup Guide

## Prerequisites

- Linux with Docker installed
- `minikube`, `kubectl`, `helm`, `git`, `jq` installed
- `cosign` binary installed ([install guide](https://docs.sigstore.dev/system_config/installation/))
- User has `sudo` access
- An AWS account (free tier is fine) with credentials configured via `aws configure`
- A GitHub fork of this repo

---

## 0. Fork & Clone

```bash
# Fork the repo on GitHub, then clone YOUR fork
git clone https://github.com/<YOUR-GITHUB-USER>/<YOUR-FORK>.git
cd <repo>
```

### Update repoURL to your fork

```bash
# ArgoCD root app must point to YOUR repo
sed -i "s|repoURL: https://github.com/zacknguyn/cluster-security-gitops-demo.git|repoURL: https://github.com/YOUR_USER/YOUR_REPO.git|" argocd/root.yaml
```

### Update registry whitelist to your GHCR namespace

```bash
# Constraint whitelist must allow YOUR ghcr.io images
sed -i "s|ghcr.io/zacknguyn/|ghcr.io/YOUR_USER/|g" argocd/gatekeeper/constraint.yaml
```

### Update signing policy to your GHCR namespace

```bash
sed -i "s|ghcr.io/zacknguyn/|ghcr.io/YOUR_USER/|g" signing/cluster-image-policy.yaml
```

Check all references:
```bash
grep -rn 'zacknguyn' --include='*.yaml' --include='*.yml'
```

---

## 1. Start Minikube

```bash
minikube -p w10 start --cpus=2 --memory=4096
```

Verify quay.io is reachable from inside the VM:
```bash
minikube -p w10 ssh -- "curl -sS --connect-timeout 5 https://quay.io | head -c 200"
```

### DNS broken? (common after host restart)

If quay.io / any external domain times out from inside the VM:

```bash
sudo systemctl restart docker
minikube -p w10 stop
minikube -p w10 start --cpus=2 --memory=4096
```

### Still broken? Pre-load images into containerd

```bash
# On host, pull and save the ArgoCD image
docker pull quay.io/argoproj/argocd:v2.14.0
docker save quay.io/argoproj/argocd:v2.14.0 -o /tmp/argocd.tar

# Copy into minikube and import
minikube -p w10 cp /tmp/argocd.tar /tmp/argocd.tar
minikube -p w10 ssh -- "sudo ctr -n k8s.io images import /tmp/argocd.tar"

# Patch all ArgoCD deployments to use imagePullPolicy: Never
for dep in $(kubectl -n argocd get deploy -o name); do
  kubectl -n argocd patch $dep -p '{"spec":{"template":{"spec":{"containers":[{"name":"argocd-application-controller","imagePullPolicy":"Never"}]}}}}' --type=merge 2>/dev/null
  kubectl -n argocd patch $dep -p '{"spec":{"template":{"spec":{"containers":[{"name":"argocd-applicationset-controller","imagePullPolicy":"Never"}]}}}}' --type=merge 2>/dev/null
  kubectl -n argocd patch $dep -p '{"spec":{"template":{"spec":{"containers":[{"name":"argocd-dex-server","imagePullPolicy":"Never"}]}}}}' --type=merge 2>/dev/null
  kubectl -n argocd patch $dep -p '{"spec":{"template":{"spec":{"containers":[{"name":"argocd-notifications-controller","imagePullPolicy":"Never"}]}}}}' --type=merge 2>/dev/null
  kubectl -n argocd patch $dep -p '{"spec":{"template":{"spec":{"containers":[{"name":"argocd-redis","imagePullPolicy":"Never"}]}}}}' --type=merge 2>/dev/null
  kubectl -n argocd patch $dep -p '{"spec":{"template":{"spec":{"containers":[{"name":"argocd-repo-server","imagePullPolicy":"Never"}]}}}}' --type=merge 2>/dev/null
  kubectl -n argocd patch $dep -p '{"spec":{"template":{"spec":{"containers":[{"name":"argocd-server","imagePullPolicy":"Never"}]}}}}' --type=merge 2>/dev/null
done
# Restart pods to pick up change
kubectl -n argocd delete pod --all
```

### Free up disk space (minikube VM often runs low)

```bash
minikube -p w10 ssh -- "docker system prune -af"
```

---

## 2. Install ArgoCD

```bash
kubectl create ns argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl wait --for=condition=Ready pods --all -n argocd --timeout=300s
```

### (Optional) Access ArgoCD UI

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
# In another terminal:
kubectl port-forward svc/argocd-server -n argocd 8080:443
```
Open `https://localhost:8080`, login as `admin`.

---

## 3. Create Additional Namespaces

```bash
kubectl create ns demo
kubectl create ns gatekeeper-system
kubectl create ns external-secrets
```

---

## 4. Install Gatekeeper (Helm CLI — DO NOT use ArgoCD for this)

```bash
helm repo add gatekeeper https://open-policy-agent.github.io/gatekeeper/charts
helm install gatekeeper gatekeeper/gatekeeper --namespace gatekeeper-system --wait
kubectl wait --for=condition=Ready pods --all -n gatekeeper-system --timeout=120s
```

### Fix Gatekeeper webhook selector

ArgoCD's root app creates a conflicting `gatekeeper-operator` app that overwrites the service selector. Fix it:

```bash
WEBHOOK_POD_RELEASE=$(kubectl get pods -n gatekeeper-system \
  -l control-plane=controller-manager \
  -o jsonpath='{.items[0].metadata.labels.release}')
kubectl get svc gatekeeper-webhook-service -n gatekeeper-system -o json | \
  jq --arg rel "$WEBHOOK_POD_RELEASE" '.spec.selector.release = $rel' | \
  kubectl replace -f -

# Verify endpoints have 3 IPs
kubectl get endpoints -n gatekeeper-system gatekeeper-webhook-service
```

### Delete conflicting ArgoCD apps (will be recreated by root, but we manage gatekeeper manually)

```bash
kubectl delete application gatekeeper-operator -n argocd --ignore-not-found
kubectl delete application gatekeeper -n argocd --ignore-not-found
```

---

## 5. Apply RBAC

```bash
kubectl apply -f argocd/rbac/cluster-roles.yaml
kubectl apply -f argocd/rbac/role-bindings.yaml
```

---

## 6. Apply Gatekeeper Constraints

```bash
kubectl apply -f argocd/gatekeeper/constraint-template.yaml
kubectl apply -f argocd/gatekeeper/constraint.yaml
```

---

## 7. Provision AWS Resources (Terraform)

```bash
cd terraform
terraform init
terraform apply -auto-approve
```

After apply, capture the outputs:
```bash
terraform output aws_access_key_id
terraform output aws_secret_access_key
```

---

## 8. Install External Secrets Operator (Helm CLI)

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets --namespace external-secrets --wait
kubectl wait --for=condition=Ready pods --all -n external-secrets --timeout=120s
```

### Create AWS credentials secret

`eso/aws-secret.yaml` is gitignored for safety. Create it manually:

```bash
cat > eso/aws-secret.yaml << 'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: aws-secret
  namespace: demo
type: Opaque
stringData:
  access-key: <AWS_ACCESS_KEY_ID_FROM_TERRAFORM>
  secret-key: <AWS_SECRET_ACCESS_KEY_FROM_TERRAFORM>
EOF
kubectl apply -f eso/aws-secret.yaml
```

### Apply ESO resources

```bash
kubectl apply -f eso/secret-store.yaml
kubectl apply -f eso/external-secret.yaml
```

Verify secret synced (should print password):
```bash
kubectl get secret db-password -n demo -o jsonpath="{.data.password}" | base64 -d
echo
```

---

## 9. Apply ArgoCD Root App (bootstraps everything else)

```bash
kubectl apply -f argocd/root.yaml
```

After ArgoCD syncs, re-delete the gatekeeper apps (root recreates them):
```bash
kubectl delete application gatekeeper-operator -n argocd --ignore-not-found
kubectl delete application gatekeeper -n argocd --ignore-not-found
```

Also fix the webhook selector once more (root resets it):
```bash
WEBHOOK_POD_RELEASE=$(kubectl get pods -n gatekeeper-system \
  -l control-plane=controller-manager \
  -o jsonpath='{.items[0].metadata.labels.release}')
kubectl get svc gatekeeper-webhook-service -n gatekeeper-system -o json | \
  jq --arg rel "$WEBHOOK_POD_RELEASE" '.spec.selector.release = $rel' | \
  kubectl replace -f -
kubectl get endpoints -n gatekeeper-system gatekeeper-webhook-service
```

Verify ArgoCD apps:
```bash
kubectl get applications -n argocd
```

---

## 10. Install Sigstore Policy Controller

```bash
helm repo add sigstore https://sigstore.github.io/helm-charts
helm install policy-controller sigstore/policy-controller \
  --namespace cosign-system --create-namespace --wait
kubectl wait --for=condition=Ready pods --all -n cosign-system --timeout=120s
```

> If install fails with `check-ignore-label.gatekeeper.sh` webhook error, run the webhook fix from Step 4, then retry.

### Apply image policies

```bash
kubectl apply -f signing/cluster-image-policy.yaml
kubectl apply -f signing/allow-all-other.yaml
kubectl label ns demo policy.sigstore.dev/include=true --overwrite
```

---

## 11. Verify Everything

```bash
kubectl get pods -A
kubectl get applications -n argocd
```

Expected healthy pods:
| Namespace | Pods | Count |
|---|---|---|
| `argocd` | application-controller, appsets-controller, dex-server, notifications, redis, repo-server, server | 7 |
| `gatekeeper-system` | controller-manager ×3, audit | 4 |
| `external-secrets` | external-secrets ×3 | 3 |
| `cosign-system` | policy-controller-webhook | 1 |
| `demo` | w10-api-* ×4 | 4 |
| `monitoring` | prometheus, alertmanager, grafana | ~7 |

### Test enforcement

```bash
# Should be DENIED by Gatekeeper (missing limits, no owner label)
kubectl run test-nginx --image=nginx -n demo --restart=Never 2>&1

# Should PASS (trusted registry, has limits, has owner label, no :latest tag)
kubectl run test-pause --image=registry.k8s.io/pause:3.10 -n demo --restart=Never \
  --labels=owner=test \
  --overrides='{"spec":{"containers":[{"name":"pause","image":"registry.k8s.io/pause:3.10","resources":{"limits":{"cpu":"100m","memory":"128Mi"}}}]}}'

# Clean up
kubectl delete pod test-pause -n demo --force --grace-period=0 2>/dev/null
```

---

## 12. Set Up CI/CD (GitHub Actions)

### Add Cosign private key to GitHub Secrets

```bash
# Generate key pair (overwrites any existing keys)
cosign generate-key-pair
```

1. `cat cosign.key` — copy the entire output
2. Go to GitHub repo → Settings → Secrets and variables → Actions → New repository secret
3. Name: `COSIGN_PRIVATE_KEY`, paste the key
4. `cosign.key` is already in `.gitignore` — will not be committed

### Push the repo

```bash
git add -A
git commit -m "feat: complete W10 setup"
git push
```

The next push to `main` touching `src/api/` triggers:
**Build image → Trivy scan (CRITICAL+HIGH, exit-code 1) → Cosign sign → Bump rollout.yaml → Commit**

---

## Troubleshooting

### Gatekeeper webhook refusing connections

Run the webhook selector fix (Step 4). This is needed:
- Right after Gatekeeper Helm install
- Right after applying ArgoCD root app (root resets the selector)
- Anytime endpoints show `<none>`

### Sigstore blocks everything

Make sure `signing/allow-all-other.yaml` is applied — it passes all images not matching the specific policy.

### Secrets not syncing from AWS

- Verify `eso/aws-secret.yaml` is applied in `demo` namespace with correct credentials
- Check `kubectl describe externalsecret db-password -n demo`
- The SecretStore points to `us-west-2` — verify your secret is in that region

### Minikube out of disk space

```bash
minikube -p w10 ssh -- "docker system prune -af"
```
