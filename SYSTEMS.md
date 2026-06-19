# W10 System Architecture & Code Walkthrough

## 1. System Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        GitHub Repository                                │
│  ┌──────────┐  ┌─────────────┐  ┌───────────┐  ┌───────────────────┐   │
│  │ src/api/ │  │ app-api/    │  │ argocd/   │  │ signing/          │   │
│  │ app.py   │  │ rollout.yaml│  │ root.yaml │  │ cluster-image-    │   │
│  │ Dockerfile│  │ service.yaml│  │ apps/*.yaml│  │ policy.yaml      │   │
│  └──────────┘  └─────────────┘  └───────────┘  └───────────────────┘   │
│  ┌──────────┐  ┌──────────────┐ ┌────────────┐ ┌──────────────────┐   │
│  │ eso/     │  │ terraform/   │ │ argocd/    │ │ app-alert/       │   │
│  │ secret-  │  │ main.tf      │ │ gatekeeper/│ │ prometheus-      │   │
│  │ store.yaml│  │ (AWS infra) │ │ constraint*│ │ rules.yaml       │   │
│  └──────────┘  └──────────────┘ └────────────┘ └──────────────────┘   │
│  ┌──────────────┐  ┌───────────────┐ ┌────────────────────────────┐   │
│  │ tenants/     │  │ apps/        │ │ evidence/                  │   │
│  │ payments/    │  │ payments/    │ │ (challenge proofs)          │   │
│  │ (challenge)  │  │ rollout.yaml │ └────────────────────────────┘   │
│  └──────────────┘  └───────────────┘                                    │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │  .github/workflows/                                            │   │
│  │  build-push.yml  →  CI/CD pipeline                             │   │
│  │  validate.yml    →  PR validation                               │   │
│  └─────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                git push (triggers) │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                        GitHub Actions                                    │
│                                                                          │
│  build-push.yml (on push to main touching src/api/**)                    │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐  │
│  │ Checkout │→│ SemVer   │→│ Build &  │→│ Trivy    │→│ Cosign   │  │
│  │ repo     │  │ bump     │  │ Push     │  │ Scan     │  │ Sign     │  │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘  └──────────┘  │
│                                                      │                  │
│                                                      ▼                  │
│  ┌──────────┐  ┌──────────┐  ┌────────────────────────────────────┐    │
│  │ Commit   │→│ Push     │→│  Image ghcr.io/user/w10-api:v0.0.2  │    │
│  │ rollout  │  │ to main  │  │  + signature                        │    │
│  └──────────┘  └──────────┘  └────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌───────────────────────────────────────────────────────────────────────────┐
│                         Minikube Cluster                                  │
│                                                                           │
│  ┌─────────────────────────────────────────────────────────────────┐      │
│  │                     ArgoCD (argocd namespace)                   │      │
│  │  polls git → applies root.yaml → syncs all child apps          │      │
│  │  ┌──────┐  ┌──────┐  ┌──────┐  ┌──────┐  ┌──────┐  ┌──────┐  │      │
│  │  │common│→│prom..│→│alert │→│api   │→│rbac  │→│gate..│  │      │
│  │  │ns    │  │stack │  │rules │  │roll. │  │roles │  │cnstr.│  │      │
│  │  └──────┘  └──────┘  └──────┘  └──────┘  └──────┘  └──────┘  │      │
│  │  ┌──────────────┐  ┌────────────────────┐                       │      │
│  │  │ payments     │→│ payments-app       │  (challenge)          │      │
│  │  │ (ns+rbac+    │  │ (rollout+service)  │                       │      │
│  │  │  quota+netpol)│  └────────────────────┘                       │      │
│  │  └──────────────┘    │                                           │      │
│  └─────────────────────────────────────────────────────────────────┘      │
│                                                                           │
│  ┌─────────────────────────────────────────────────────────────────┐      │
│  │  Admission Control (intercepts every kubectl apply)             │      │
│  │                                                                  │      │
│  │  Request → Gatekeeper (OPA/Rego) → Sigstore (Cosign) → Allowed  │      │
│  │             │ 6 constraints          │ key validation            │      │
│  │             │ matched via            │ - ghcr.io/user/w10-api   │      │
│  │             │ namespaceSelector      │   must be signed          │      │
│  │             │ (label gatekeeper:     │ - all other images pass   │      │
│  │             │  enforced)             │                           │      │
│  │             │ - owner label          │                           │      │
│  │             │ - resource limits      │                           │      │
│  │             │ - no :latest           │                           │      │
│  │             │ - no root user         │                           │      │
│  │             │ - no host network      │                           │      │
│  │             │ - trusted registry     │                           │      │
│  └─────────────────────────────────────────────────────────────────┘      │
│                                                                           │
│  ┌─────────────────────────────────────────────────────────────────┐      │
│  │  External Secrets Operator (external-secrets namespace)         │      │
│  │                                                                  │      │
│  │  SecretStore ──► AWS Secrets Manager ──► ExternalSecret ──►     │      │
│  │  (aws creds)       (w10/db-password)   (db-password)            │      │
│  │                                           │                      │      │
│  │                                           ▼                      │      │
│  │                                     demo/db-password             │      │
│  │                                     (K8s Secret)                 │      │
│  └─────────────────────────────────────────────────────────────────┘      │
│                                                                           │
│  ┌─────────────────────────────────────────────────────────────────┐      │
│  │  Monitoring (monitoring namespace)                              │      │
│  │                                                                  │      │
│  │  API pods ──► ServiceMonitor ──► Prometheus ──► AlertManager    │      │
│  │  /metrics        scrape:15s        rules: SLO     ──► Email     │      │
│  │                                     < 95%                        │      │
│  └─────────────────────────────────────────────────────────────────┘      │
└───────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Key Flows

### Flow A: CI/CD Pipeline (build-push.yml)

```
Developer pushes code to src/api/ on main
          │
          ▼
  GitHub Actions triggered
          │
          ▼
  Step 1: Calculate semantic version
          │  (bumps v{major}.{minor}.{patch} based on commit messages)
          ▼
  Step 2: Log in to ghcr.io using GITHUB_TOKEN
          │
          ▼
  Step 3: Build & push Docker image
          │  Tags: latest, v0.0.X, v0.0.X-<sha>
          ▼
  Step 4: Trivy scan (fail if CRITICAL or HIGH found)
          │
          ▼
  Step 5: Cosign sign image with COSIGN_PRIVATE_KEY
          │
          ▼
  Step 6: Update app-api/rollout.yaml with new version
          │
          ▼
  Step 7: Commit & push updated rollout.yaml
          │
          ▼
  Step 8: Create git tag v0.0.X
          │
          ▼
  ArgoCD detects change → syncs new rollout → canary deploy
```

### Flow B: ArgoCD App-of-Apps Sync

```
kubectl apply -f argocd/root.yaml
          │
          ▼
  ArgoCD reads argocd/apps/ directory
          │
          ▼
  Sync Wave -1:  common         → create demo namespace
                 payments       → create payments namespace + RBAC +
                                  ResourceQuota + LimitRange + NetworkPolicy
  Sync Wave  0:  kube-prometheus-stack → install monitoring stack
                 argo-rollouts          → install Rollouts controller
                 gatekeeper-operator    → (deleted, managed via Helm CLI)
  Sync Wave  1:  alert          → deploy PrometheusRule SLO alerts
                 analysis       → deploy AnalysisTemplate
                 gatekeeper     → deploy constraint templates + constraints
                 rbac           → deploy ClusterRoles + bindings
  Sync Wave  2:  api            → deploy Rollout + Service + ServiceMonitor
                 payments-app   → deploy payments Rollout + Service
```

### Flow C: Admission Control (Gatekeeper + Sigstore)

```
kubectl apply -f pod.yaml -n demo
          │
          ▼
  Kubernetes API Server receives request
          │
          ▼
  Gatekeeper webhook intercepts (MutatingWebhookConfiguration)
          │
          ▼
  Check all 6 constraints:
   1. Has owner label?           ──No──→ DENY
   2. Has resource limits?       ──No──→ DENY
   3. Uses :latest tag?          ──Yes─→ DENY
   4. runAsUser: 0?              ──Yes─→ DENY
   5. hostNetwork: true?         ──Yes─→ DENY
   6. Registry whitelisted?      ──No──→ DENY
     (Constraints match via namespaceSelector label, not hardcoded ns names)
          │
         All pass
          │
          ▼
  Sigstore Policy Controller webhook intercepts
          │
          ▼
  Does image match glob "ghcr.io/user/w10-api@*"?
    ├── Yes → Verify Cosign signature against public key
    │         ├── Valid   → ALLOW
    │         └── Invalid → DENY
    └── No  → Match "**" (allow-all-other)
              → static: pass → ALLOW
          │
          ▼
  Pod admitted to cluster
```

### Flow D: External Secrets Sync

```
  Terraform creates:
    AWS IAM user "eso-sync"
    AWS access key (stored in K8s Secret "aws-secret")
    AWS Secrets Manager secret "w10/db-password" (value: P@ssw0rd123)
          │
          ▼
  External Secrets Operator watches "ExternalSecret" in demo namespace
          │
          ▼
  Reads SecretStore "aws-secret-store":
    → uses aws-secret (AWS access key) to authenticate
    → connects to AWS Secrets Manager in us-west-2
          │
          ▼
  Reads ExternalSecret "db-password":
    → refreshInterval: 60s
    → fetches key "password" from AWS secret "w10/db-password"
          │
          ▼
  Creates/updates K8s Secret "db-password" in demo namespace
    apiVersion: v1
    kind: Secret
    data:
      password: <base64(P@ssw0rd123)>
```

### Flow E: Canary Deployment with Automated Analysis

```
  ArgoCD syncs new rollout.yaml (image: v0.0.2, ERROR_RATE: 0)
          │
          ▼
  Argo Rollouts controller detects change
          │
          ▼
  Canary Step 1:  setWeight=10 → 10% of pods run new version
          │        pause 2m → let metrics accumulate
          ▼
  AnalysisRun starts: queries Prometheus every 30s
    query: success rate over 2m (non-5xx / total)
    successCondition: result >= 0.90
          │
          ▼
  ┌── if ≥ 0.90 ──→ Step 2: setWeight=50 → 50% new version
  │                  pause 2m → AnalysisRun continues
  │                  ┌── if ≥ 0.90 ──→ Step 3: setWeight=100 → full rollout
  │                  │                  Rollout COMPLETE
  │                  └── if < 0.90 ──→ ABORT → auto-rollback to previous version
  └── if < 0.90 ──→ ABORT immediately
```

---

### Flow F: Network Isolation (Challenge — Multi-Tenant)

```
Pod in payments namespace tries to call api.demo.svc
          │
          ▼
  NetworkPolicy "restrict-egress" intercepts
          │
          ▼
  Egress rule check:
    Is destination namespace "payments"?      ──Yes──→ ALLOW
    Is destination kube-dns on port 53?        ──Yes──→ ALLOW
    Everything else                            ──No──→ DENY
          │
          ▼
  Connection to api.demo.svc (demo namespace) is BLOCKED
          │
          ▼
  NetworkPolicy "default-deny-ingress" also blocks any
  external pod from connecting INTO payments
          │
          ▼
  Two namespaces are fully isolated:
  - demo cannot reach payments
  - payments cannot reach demo
  (Requires CNI plugin like Calico to enforce)
```

---

## 3. Line-by-Line Code Walkthrough

### 3.1 `argocd/root.yaml` — App of Apps Root

```yaml
# Lab 5: app-of-apps root
# Root App: App of Apps pattern - quản lý tất cả child applications
apiVersion: argoproj.io/v1alpha1    # ArgoCD CRD API version
kind: Application                   # ArgoCD Application resource
metadata:
  name: root                        # App name in ArgoCD UI
  namespace: argocd                 # ArgoCD watches this namespace for Applications
spec:
  project: default                  # ArgoCD project (RBAC grouping)
  source:
    repoURL: https://github.com/... # Git repo containing child app manifests
    path: argocd/apps               # Directory with child Application YAML files
    targetRevision: main            # Git branch to track
  destination:
    server: https://kubernetes.default.svc  # In-cluster API server
    namespace: argocd                       # Deploy child apps here
  syncPolicy:
    automated:
      prune: true                   # Delete resources removed from git
      selfHeal: true                # Revert manual changes to match git
```

### 3.2 `argocd/apps/*.yaml` — Child Applications (sync waves)

**app-common.yaml** (wave -1):
```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "-1"   # Deploy FIRST (creates namespaces)
spec:
  source:
    path: app-common                      # Points to app-common/ directory
  destination:
    namespace: demo
  syncPolicy:
    syncOptions:
    - CreateNamespace=true                # Auto-create namespace if missing
```

**app-api.yaml** (wave 2):
```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "2"     # Deploy LAST (after infra + config)
spec:
  source:
    path: app-api                         # Points to app-api/ directory
  destination:
    namespace: demo
  syncPolicy:
    syncOptions:
    - ServerSideApply=true                # Use server-side apply (avoids conflicts)
```

### 3.3 `argocd/rbac/cluster-roles.yaml` — RBAC

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole                         # Cluster-scoped (not namespaced)
metadata:
  name: developer                         # Role name
rules:
- apiGroups: [""]                         # Core API group
  resources: ["pods", "services", "configmaps", "pods/log"]
  verbs: ["get", "list", "watch"]         # Read-only on core resources
- apiGroups: ["apps"]                     # Apps API group
  resources: ["deployments", "statefulsets"]
  verbs: ["get", "list", "watch", "create", "update", "patch"]  # Read-write on apps
- apiGroups: ["argoproj.io"]              # Argo Rollouts CRDs
  resources: ["rollouts"]
  verbs: ["get", "list", "watch"]         # Read-only rollouts (SRE manages)

# sre ClusterRole:
# Same as developer + can delete + secrets access + nodes + analysis runs
# Viewer:
# Read-only on pods, services, configmaps, deployments, statefulsets
```

**role-bindings.yaml**:
```yaml
# developer: uses RoleBinding (scoped to demo namespace)
kind: RoleBinding
metadata:
  name: developer-binding
  namespace: demo
subjects:
- kind: User
  name: developer
roleRef:
  kind: ClusterRole
  name: developer

# sre: uses ClusterRoleBinding (cluster-wide)
kind: ClusterRoleBinding
metadata:
  name: sre-binding
subjects:
- kind: User
  name: sre
roleRef:
  kind: ClusterRole
  name: sre

# viewer: same pattern as developer (RoleBinding in demo)
```

### 3.4 `argocd/gatekeeper/constraint-template.yaml` — Rego Policies

**Template 1 — K8sRequiredLabels** (lines 1-29):
```yaml
apiVersion: templates.gatekeeper.sh/v1  # Gatekeeper CRD
kind: ConstraintTemplate
metadata:
  name: k8srequiredlabels               # Template name
spec:
  crd:
    spec:
      names:
        kind: K8sRequiredLabels          # Kind created from this template
      validation:
        openAPIV3Schema:
          properties:
            labels:                      # Parameter: takes a list of required labels
              type: array
  targets:
  - target: admission.k8s.gatekeeper.sh  # Standard admission target
    rego: |
      package k8srequiredlabels
      # violation: fires if required labels are missing
      # NOTE: provided must be a SET of keys, not the raw labels object
      # NOTE: use 'some i' syntax instead of [_] in set comprehensions
      violation[{"msg": msg, "details": details}] {
        provided_keys := {key | input.review.object.metadata.labels[key]}
        required_labels := {label | some i; label := input.parameters.labels[i]}
        missing := required_labels - provided_keys
        count(missing) > 0
        msg := sprintf("missing labels: %v", [missing])
        details := {"missing": missing}
      }
```

**Template 2 — K8sRequiredResources** (lines 31-48):
```yaml
rego: |
  package k8srequiredresources
  # violation: fires if a container has no resource limits
  violation[{"msg": msg}] {
    container := input.review.object.spec.containers[_]  # Iterate all containers
    not container.resources.limits                       # No limits defined?
    msg := sprintf("container %v must specify resource limits", [container.name])
  }
```

**Template 3 — K8sBlockLatestTag** (lines 50-67):
```yaml
rego: |
  package k8sblocklatesttag
  # violation: fires if container image ends with ":latest"
  violation[{"msg": msg}] {
    container := input.review.object.spec.containers[_]
    endswith(container.image, ":latest")                 # String ends with :latest?
    msg := sprintf("container %v uses :latest tag", [container.name])
  }
```

**Template 4 — K8sBlockRootUser** (lines 69-90):
```yaml
rego: |
  package k8sblockrootuser
  # violation 1: pod-level securityContext.runAsUser == 0
  violation[{"msg": msg}] {
    input.review.object.spec.securityContext.runAsUser == 0
    msg := "running as root (runAsUser: 0) is forbidden"
  }
  # violation 2: container-level securityContext.runAsUser == 0
  violation[{"msg": msg}] {
    container := input.review.object.spec.containers[_]
    container.securityContext.runAsUser == 0
    msg := sprintf("container %v runs as root", [container.name])
  }
```

**Template 5 — K8sBlockHostNetwork** (lines 92-108):
```yaml
rego: |
  package k8sblockhostnetwork
  # violation: fires if spec.hostNetwork is true
  violation[{"msg": msg}] {
    input.review.object.spec.hostNetwork
    msg := "hostNetwork: true is forbidden"
  }
```

**Template 6 — K8sAllowedRegistries** (lines 110-140) — Custom Rego:
```yaml
rego: |
  package k8sallowedregistries
  # violation: fires if image doesn't start with any allowed registry prefix
  violation[{"msg": msg}] {
    container := input.review.object.spec.containers[_]
    image := container.image
    not image_from_allowed_registry(image)              # Not in whitelist?
    msg := sprintf("container %v uses untrusted registry: %v", [container.name, image])
  }
  # helper: checks if image starts with any allowed registry prefix
  image_from_allowed_registry(image) {
    registry := input.parameters.registries[_]           # Iterate allowed registries
    startswith(image, registry)                          # Prefix match
  }
```

### 3.5 `argocd/gatekeeper/constraint.yaml` — Constraint Instances

```yaml
# Constraint 1 — K8sRequiredLabels
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sRequiredLabels               # Kind from ConstraintTemplate
metadata:
  name: demo-must-have-owner           # Unique constraint name
spec:
  enforcementAction: deny              # deny | dryrun | warn
  match:
    kinds:
    - apiGroups: [""]
      kinds: ["Pod"]                  # Apply to Pods only
    namespaceSelector:                 # ← Changed from namespaces to label selector
      matchLabels:
        gatekeeper: enforced           # Any namespace with this label gets it
  parameters:
    labels: ["owner"]                 # Require "owner" label

# Constraint 2 — K8sRequiredResources
kind: K8sRequiredResources
name: demo-must-have-limits
# match: any namespace with label gatekeeper=enforced
# (no parameters needed — always checks all containers have limits)

# Constraint 3 — K8sBlockLatestTag
kind: K8sBlockLatestTag
name: demo-no-latest-tag
# same namespaceSelector pattern

# Constraint 4 — K8sBlockRootUser
kind: K8sBlockRootUser
name: demo-no-root-user
# same namespaceSelector pattern

# Constraint 5 — K8sBlockHostNetwork
kind: K8sBlockHostNetwork
name: demo-no-host-network
# same namespaceSelector pattern

# Constraint 6 — K8sAllowedRegistries
kind: K8sAllowedRegistries
name: demo-trusted-registries
# same namespaceSelector pattern
parameters:
  registries:
  - "ghcr.io/zacknguyn/"              # Your own GHCR
  - "quay.io/"                        # Red Hat / ArgoCD images
  - "docker.io/"                      # Docker Hub
  - "registry.k8s.io/"                # K8s official images
```

### 3.6 `signing/cluster-image-policy.yaml` — Sigstore Cosign Policy

```yaml
apiVersion: policy.sigstore.dev/v1beta1    # Sigstore Policy Controller CRD
kind: ClusterImagePolicy
metadata:
  name: w10-image-policy
spec:
  images:
  - glob: ghcr.io/zacknguyn/w10-api@*      # Match by digest (not tag)
                                            # @* means any digest
  authorities:
  - key:                                    # Verify against this public key
      data: |
        -----BEGIN PUBLIC KEY-----
        MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEI3MAFvAbzj7mLAQRD9Xy2xDjasoZ
        8laTFjx6bYbAXN1KUxqgRfDaV2KBvuPfDpt86XYjvFtz04dzsiCH6gG+6A==
        -----END PUBLIC KEY-----
```

### 3.7 `signing/allow-all-other.yaml` — Catch-all Pass

```yaml
apiVersion: policy.sigstore.dev/v1beta1
kind: ClusterImagePolicy
metadata:
  name: allow-all-other
spec:
  images:
  - glob: "**"                              # Match every image
  authorities:
  - static:                                 # No dynamic verification
      action: pass                          # Always allow
```

### 3.8 `.github/workflows/build-push.yml` — CI/CD Pipeline

```yaml
name: Build and Push Image

on:
  push:
    branches:
      - main
    paths:                               # Only trigger on these paths
      - 'src/api/**'                     # API source code changes
      - '.github/workflows/build-push.yml'  # Workflow itself changes
  workflow_dispatch:                     # Manual trigger via UI

env:
  REGISTRY: ghcr.io
  IMAGE_NAME: ${{ github.repository_owner }}/w10-api

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    permissions:
      contents: write                    # Can commit/push to repo
      packages: write                    # Can push to GHCR

    steps:
    - name: Checkout repository
      uses: actions/checkout@v4
      with:
        fetch-depth: 0                   # Full history for semantic versioning

    - name: Calculate semantic version
      id: semver
      uses: paulhatch/semantic-version@v5.4.0
      with:
        tag_prefix: "v"                  # Git tags: v0.0.1, v0.0.2, ...
        major_pattern: "(BREAKING CHANGE:|!:)"   # Commit msg with ! or BREAKING CHANGE
        minor_pattern: "^feat"           # feat: commits bump minor
        version_format: "${major}.${minor}.${patch}"
        bump_each_commit: false

    - name: Log in to Container Registry
      uses: docker/login-action@v3
      with:
        registry: ghcr.io
        username: ${{ github.actor }}
        password: ${{ secrets.GITHUB_TOKEN }}  # Auto-generated token

    - name: Extract metadata
      id: meta
      uses: docker/metadata-action@v5
      with:
        images: ghcr.io/${{ github.repository_owner }}/w10-api
        tags: |
          type=raw,value=latest                 # Tag: latest
          type=raw,value=${{ steps.semver.outputs.version }}  # Tag: 0.0.X
          type=sha,prefix=v${{ steps.semver.outputs.version }}-  # Tag: v0.0.X-<sha>

    - name: Build and push Docker image
      id: build-and-push
      uses: docker/build-push-action@v6
      with:
        context: ./src/api              # Docker build context
        push: true
        tags: ${{ steps.meta.outputs.tags }}
        labels: ${{ steps.meta.outputs.labels }}

    - name: Run Trivy vulnerability scanner
      uses: aquasecurity/trivy-action@0.29.0
      with:
        image-ref: ghcr.io/${{ github.repository_owner }}/w10-api:${{ steps.semver.outputs.version }}
        format: table
        exit-code: 1                      # Fail build if vulnerabilities found
        severity: CRITICAL,HIGH           # Only fail on CRITICAL or HIGH

    - name: Install cosign
      uses: sigstore/cosign-installer@v3.8.1

    - name: Sign the image with Cosign
      env:
        COSIGN_PRIVATE_KEY: ${{ secrets.COSIGN_PRIVATE_KEY }}  # From GitHub Secrets
        COSIGN_PASSWORD: ''               # No password on the key
      run: |
        cosign sign --key env://COSIGN_PRIVATE_KEY \
          ghcr.io/${{ github.repository_owner }}/w10-api@${{ steps.build-and-push.outputs.digest }} \
          --yes

    - name: Update rollout.yaml with new version
      run: |
        # Replace image line with new version
        sed -i "s|image: ghcr.io/.*/w10-api:.*|image: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:${{ steps.semver.outputs.version }}|g" app-api/rollout.yaml
        # Replace VERSION env var value
        sed -i "s|value: \"v.*\"|value: \"v${{ steps.semver.outputs.version }}\"|g" app-api/rollout.yaml

    - name: Commit and push version update
      run: |
        git config user.name "github-actions[bot]"
        git config user.email "github-actions[bot]@users.noreply.github.com"
        git add app-api/rollout.yaml
        if git diff --staged --quiet; then
          echo "No changes to commit"
        else
          git commit -m "chore: bump version to v${{ steps.semver.outputs.version }}"
          git push
        fi

    - name: Create git tag
      run: |
        git tag v${{ steps.semver.outputs.version }}
        git push origin v${{ steps.semver.outputs.version }}
```

### 3.9 `eso/secret-store.yaml` — External Secrets Store

```yaml
apiVersion: external-secrets.io/v1        # ESO CRD
kind: SecretStore                         # Defines HOW to connect to external secrets
metadata:
  name: aws-secret-store
  namespace: demo
spec:
  provider:
    aws:
      service: SecretsManager             # AWS service to connect to
      region: us-west-2                   # AWS region
      auth:
        secretRef:                        # Reference to K8s Secret with AWS creds
          accessKeyIDSecretRef:
            name: aws-secret              # K8s Secret name
            key: access-key               # Key in the Secret
          secretAccessKeySecretRef:
            name: aws-secret
            key: secret-access-key
```

### 3.10 `eso/external-secret.yaml` — External Secret Definition

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret                     # Defines WHAT to sync
metadata:
  name: db-password
  namespace: demo
spec:
  refreshInterval: 60s                   # Re-sync every 60 seconds
  secretStoreRef:
    name: aws-secret-store               # Which SecretStore to use
    kind: SecretStore
  target:
    name: db-password                    # Target K8s Secret name
  data:
  - secretKey: password                  # Key in the resulting K8s Secret
    remoteRef:
      key: w10/db-password              # AWS Secrets Manager secret name
      property: password                 # JSON property within the secret value
```

### 3.11 `app-api/rollout.yaml` — Canary Rollout

```yaml
apiVersion: argoproj.io/v1alpha1         # Argo Rollouts CRD
kind: Rollout                            # Like Deployment but with progressive delivery
metadata:
  name: app
  namespace: demo
  labels:
    app: api
  annotations:
    argocd.argoproj.io/sync-wave: "0"    # Within the app-api ArgoCD app, deploy first
spec:
  replicas: 4                            # 4 pod replicas
  selector:
    matchLabels:
      app: api
  template:
    metadata:
      labels:
        app: api                         # Must match selector
    spec:
      containers:
      - name: api
        image: ghcr.io/zacknguyn/w10-api:0.0.1
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 8080
          protocol: TCP
        env:
        - name: VERSION
          value: "v0.0.1"               # Injected into app as env var
        - name: ERROR_RATE
          value: "0"                     # 0 = no injected errors (0.15 = 15% errors)
        livenessProbe:                   # Restart if /healthz fails
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 5
        readinessProbe:                  # Remove from Service if /healthz fails
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 3
        resources:
          limits:                        # Satisfies Gatekeeper constraint
            cpu: 200m
            memory: 128Mi
  strategy:
    canary:                              # Canary deployment strategy
      analysis:
        templates:
        - templateName: success-rate     # Reference AnalysisTemplate
        startingStep: 1                  # Start analysis after step 1
      steps:
      - setWeight: 10                    # Step 1: 10% traffic to new version
      - pause: {duration: 2m}           # Wait 2 min for metrics
      - setWeight: 50                    # Step 2: 50% traffic
      - pause: {duration: 2m}           # Wait 2 min for metrics
      - setWeight: 100                   # Step 3: 100% traffic (full rollout)
```

### 3.12 `app-api/service.yaml` — Service

```yaml
apiVersion: v1
kind: Service
metadata:
  name: api
  namespace: demo
  labels:
    app: api
  annotations:
    argocd.argoproj.io/sync-wave: "1"    # Deploy AFTER Rollout creates pods
spec:
  selector:
    app: api                              # Routes traffic to pods with label app=api
  ports:
  - name: http
    port: 80                              # Service port
    targetPort: 8080                      # Container port
```

### 3.13 `app-api/servicemonitor.yaml` — Prometheus Scrape Config

```yaml
apiVersion: monitoring.coreos.com/v1      # Prometheus Operator CRD
kind: ServiceMonitor
metadata:
  name: api
  namespace: demo
  labels:
    app: api
  annotations:
    argocd.argoproj.io/sync-wave: "2"     # Deploy AFTER Service is ready
spec:
  selector:
    matchLabels:
      app: api                             # Scrape pods behind Service with this label
  endpoints:
  - port: http                             # Use Service port named "http"
    path: /metrics                         # Flask metrics endpoint
    interval: 15s                          # Scrape every 15 seconds
```

### 3.14 `app-analysis/analysis-template.yaml` — Canary Analysis

```yaml
apiVersion: argoproj.io/v1alpha1          # Argo Rollouts CRD
kind: AnalysisTemplate
metadata:
  name: success-rate
  namespace: demo
spec:
  metrics:
  - name: success-rate
    interval: 30s                         # Query Prometheus every 30 seconds
    successCondition: result >= 0.90      # Pass if success rate ≥ 90%
    failureLimit: 10                      # Allow up to 10 failures before aborting
    provider:
      prometheus:
        address: http://kube-prometheus-stack-prometheus.monitoring.svc:9090
        query: |
          scalar(
            sum(rate(flask_http_request_duration_seconds_count{
              namespace="demo",app="api",status!~"5.."}[2m]))   # non-5xx requests / 2m
            /
            sum(rate(flask_http_request_duration_seconds_count{
              namespace="demo",app="api"}[2m]))                 # total requests / 2m
          )
```

### 3.15 `app-alert/prometheus-rules.yaml` — SLO Alerts

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: slo-alerts
  namespace: monitoring
  labels:
    prometheus: kube-prometheus-stack      # Must match Prometheus ruleSelector
    release: kube-prometheus-stack
spec:
  groups:
  - name: slo
    interval: 30s
    rules:
    # Recording rule: pre-computes success rate for faster queries
    - record: api:success_rate:5m
      expr: |
        sum(rate(flask_http_request_duration_seconds_count{status!~"5.."}[5m]))
        /
        sum(rate(flask_http_request_duration_seconds_count[5m]))

    # Alerting rule: fires when SLO breached
    - alert: SLOViolation
      expr: api:success_rate:5m < 0.95    # SLO: 95% success rate
      for: 2m                              # Must be below for 2 minutes
      labels:
        severity: critical
      annotations:
        summary: "API SLO Violation"
        description: "Success rate {{ $value | humanizePercentage }} (SLO: 95%)"
```

### 3.16 `terraform/main.tf` — AWS Infrastructure

```hcl
variable "aws_region" {
  default = "us-west-2"                    # Region for Secrets Manager
}

resource "aws_iam_policy" "eso_read" {
  name = "ESO-SecretsManager-Read"         # IAM policy name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource = ["*"]                     # Read any secret in the account
    }]
  })
}

resource "aws_iam_user" "eso_sync" {
  name = "eso-sync"                        # IAM user for ESO
}

resource "aws_iam_user_policy_attachment" "eso_attach" {
  user       = aws_iam_user.eso_sync.name
  policy_arn = aws_iam_policy.eso_read.arn # Attach read policy to user
}

resource "aws_iam_access_key" "eso_sync_key" {
  user = aws_iam_user.eso_sync.name        # Create access key for the user
}

resource "aws_secretsmanager_secret" "db_password" {
  name = "w10/db-password"                 # Secret name in AWS
}

resource "aws_secretsmanager_secret_version" "db_password_val" {
  secret_id = aws_secretsmanager_secret.db_password.id
  secret_string = jsonencode({
    username = "admin"
    password = "P@ssw0rd123"               # Actual secret value
  })
}

output "access_key_id" {
  value = aws_iam_access_key.eso_sync_key.id
}

output "secret_access_key" {
  value     = aws_iam_access_key.eso_sync_key.secret
  sensitive = true                         # Masked in terraform output
}
```

### 3.17 `src/api/app.py` — Flask Application

```python
import os
import random
from flask import Flask, jsonify
from prometheus_flask_exporter import PrometheusMetrics

app = Flask(__name__)
PrometheusMetrics(app)        # Auto-exposes /metrics with Flask request metrics
# Metrics: request count, duration, error count, etc.

ERROR_RATE = float(os.getenv("ERROR_RATE", "0"))  # 0.0 to 1.0 — injects failures
VERSION = os.getenv("VERSION", "v1")

@app.get("/")
def index():
    if random.random() < ERROR_RATE:  # Randomly fail based on ERROR_RATE
        return jsonify(error="injected", version=VERSION), 500
    return jsonify(ok=True, version=VERSION)

@app.get("/healthz")                   # Liveness + readiness probe target
def healthz():
    return "ok", 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
```

### 3.18 `src/api/Dockerfile` — Container Image

```dockerfile
FROM python:3.13-alpine                  # Minimal Python base image
RUN pip install flask prometheus-flask-exporter  # Dependencies
COPY app.py /app/app.py                  # Copy source
WORKDIR /app
ENV FLASK_APP=app.py
EXPOSE 8080
CMD ["flask", "run", "--host=0.0.0.0", "--port=8080"]
```

---

## 4. Challenge — Multi-Tenant Isolation (Take-Home)

### 4.1 `tenants/payments/namespace.yaml` — Payments Namespace

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: payments
  labels:
    gatekeeper: enforced          # ← Critical: enables Gatekeeper constraint matching
```
The `gatekeeper: enforced` label is what the constraints now match on via `namespaceSelector`. Any namespace with this label automatically gets all 6 security policies — no new rules needed.

### 4.2 `tenants/payments/rbac.yaml` — Least-Privilege Role

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role                             # Namespace-scoped (not cluster-wide)
metadata:
  name: payments-dev
  namespace: payments
rules:
- apiGroups: [""]
  resources: ["pods", "services", "configmaps", "pods/log"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  # NO "secrets" — payments-dev cannot read secrets
  # NO "rolebindings" — cannot escalate their own permissions
- apiGroups: ["apps"]
  resources: ["deployments", "statefulsets"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]

---
kind: RoleBinding                      # Binds to Role (not ClusterRoleBinding)
metadata:
  name: payments-dev-binding
  namespace: payments
subjects:
- kind: User
  name: payments-dev
roleRef:
  kind: Role
  name: payments-dev
```
Key difference from `argocd/rbac/cluster-roles.yaml`:
- `Role` (namespaced) vs `ClusterRole` (cluster-wide) — user can only act in `payments`
- No `secrets`, `nodes`, `events`, `rolebindings` access — stricter than `sre` role
- `RoleBinding` binds within namespace — cannot touch `demo` at all

### 4.3 `tenants/payments/resource-quota.yaml` — Budget Cap

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: payments-quota
  namespace: payments
spec:
  hard:
    requests.cpu: "2"                   # Total CPU requests across all pods ≤ 2 cores
    requests.memory: 2Gi                # Total memory requests ≤ 2 GiB
    limits.cpu: "4"                     # Total CPU limits ≤ 4 cores
    limits.memory: 4Gi                  # Total memory limits ≤ 4 GiB
    pods: "10"                          # Max 10 pods in the namespace
```

### 4.4 `tenants/payments/limit-range.yaml` — Default Limits

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: payments-limits
  namespace: payments
spec:
  limits:
  - default:                            # Applied when pod omits limits
      cpu: 200m
      memory: 256Mi
    defaultRequest:                     # Applied when pod omits requests
      cpu: 100m
      memory: 128Mi
    type: Container
```
Without this, a pod with no resource limits would be **denied by Gatekeeper** and never run. LimitRange auto-injects defaults so the pod passes the constraint.

### 4.5 `tenants/payments/network-policy.yaml` — Full Isolation

```yaml
# Policy 1: Default-deny ingress (blocks ALL incoming traffic to payments)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: payments
spec:
  podSelector: {}                      # Applies to all pods in namespace
  policyTypes:
  - Ingress                            # Only ingress (incoming)
  # No ingress rules → all inbound traffic denied

---
# Policy 2: Restrict egress (blocks payments from calling demo)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: restrict-egress
  namespace: payments
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
  - to:                                # Allow traffic within payments namespace
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: payments
  - to:                                # Allow DNS resolution (coreDNS/kube-dns)
    - namespaceSelector: {}
      podSelector:
        matchLabels:
          k8s-app: kube-dns
    ports:
    - port: 53
      protocol: UDP
    - port: 53
      protocol: TCP
  # No rule for demo namespace → traffic to api.demo.svc is DENIED
```
**Ingress vs Egress**: `default-deny-ingress` blocks others from calling INTO payments, `restrict-egress` blocks payments from calling OUT to demo. Both are needed for full isolation. Requires a CNI that enforces NetworkPolicy (Calico, Cilium). Minikube with Docker driver does NOT enforce — must use `minikube start --cni=calico`.

### 4.6 `apps/payments/rollout.yaml` — Team B Workload

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: payments-app
  namespace: payments
  labels:
    app: payments-api
spec:
  replicas: 2                          # Smaller than team A's 4 replicas
  selector:
    matchLabels:
      app: payments-api
  template:
    metadata:
      labels:
        app: payments-api
        owner: payments-team           # ← Satisfies K8sRequiredLabels "owner"
    spec:
      containers:
      - name: api
        image: ghcr.io/zacknguyn/w10-api:0.0.1  # Pinned version, trusted registry
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 8080
        env:
        - name: VERSION
          value: "v0.0.1"
        - name: ERROR_RATE
          value: "0"
        resources:
          limits:                      # Satisfies K8sRequiredResources
            cpu: 200m
            memory: 128Mi
  strategy:
    canary:                            # Simpler canary than team A (2 steps)
      steps:
      - setWeight: 50
      - pause: {duration: 30s}
      - setWeight: 100
```

### 4.7 `apps/payments/service.yaml` — Team B Service

```yaml
apiVersion: v1
kind: Service
metadata:
  name: payments-api
  namespace: payments
  labels:
    app: payments-api
spec:
  selector:
    app: payments-api
  ports:
  - name: http
    port: 80
    targetPort: 8080
```

### 4.8 `argocd/apps/payments.yaml` — Payments Infra App

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: payments
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-1"  # Deploy early (namespace + infra)
spec:
  project: default
  source:
    repoURL: https://github.com/zacknguyn/cluster-security-gitops-demo.git
    path: tenants/payments
    targetRevision: main
  destination:
    namespace: payments
  syncPolicy:
    syncOptions:
    - CreateNamespace=true              # Auto-create namespace on sync
```

### 4.9 `argocd/apps/payments-app.yaml` — Payments Workload App

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: payments-app
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "2"   # Deploy after infra is ready
spec:
  source:
    path: apps/payments
  destination:
    namespace: payments
```

### 4.10 Key Insight: How Constraints Auto-Apply

The original `argocd/gatekeeper/constraint.yaml` was changed from:

```yaml
# Before (manual per-namespace):
    match:
      kinds:
      - apiGroups: [""]
        kinds: ["Pod"]
      namespaces: ["demo"]              # ← Only applied to demo

# After (dynamic via label):
    match:
      kinds:
      - apiGroups: [""]
        kinds: ["Pod"]
      namespaceSelector:
        matchLabels:
          gatekeeper: enforced           # ← Matches ANY namespace with this label
```

This is why Team B's `payments` namespace automatically inherits all 6 constraints:
- Label `gatekeeper: enforced` on `payments` namespace → Gatekeeper matches it
- The same `K8sRequiredLabels`, `K8sRequiredResources`, `K8sBlockLatestTag`, `K8sBlockRootUser`, `K8sBlockHostNetwork`, and `K8sAllowedRegistries` policies fire
- No new ConstraintTemplate or Constraint instances needed

To onboard a third team: `kubectl create ns team-c` + `kubectl label ns team-c gatekeeper=enforced`. Done.

---

## 5. Gatekeeper Webhook Fix

After every `helm install gatekeeper ...` or full cluster reinstall, the webhook service selector
may point to the wrong revision label. Symptoms: constraints don't enforce despite correct Rego.

```bash
# Fix: update webhook svc selector to match current pod release label
WEBHOOK_POD_RELEASE=$(kubectl get pods -n gatekeeper-system \
  -l control-plane=controller-manager -o jsonpath='{.items[0].metadata.labels.release}')
kubectl get svc gatekeeper-webhook-service -n gatekeeper-system -o json | \
  jq --arg rel "$WEBHOOK_POD_RELEASE" '.spec.selector.release = $rel' | \
  kubectl replace -f -
```

Without this fix, the webhook is unreachable and no constraints fire.

---

## 6. File Map Summary

| File | Purpose |
|---|---|
| `argocd/root.yaml` | App-of-apps root — syncs entire cluster from git |
| `argocd/apps/*.yaml` | 11 child apps in sync wave order |
| `argocd/gatekeeper/constraint-template.yaml` | 6 Rego templates (OPA policies) |
| `argocd/gatekeeper/constraint.yaml` | 6 constraint instances via `namespaceSelector` |
| `argocd/rbac/cluster-roles.yaml` | developer / sre / viewer ClusterRoles |
| `argocd/rbac/role-bindings.yaml` | Bindings for each role |
| `signing/cluster-image-policy.yaml` | Cosign signature enforcement for w10 images |
| `signing/allow-all-other.yaml` | Catch-all: pass all other images |
| `eso/secret-store.yaml` | AWS Secrets Manager connection config |
| `eso/external-secret.yaml` | Maps AWS secret → K8s Secret |
| `app-api/rollout.yaml` | Argo Rollout with 10→50→100 canary |
| `app-api/service.yaml` | Service exposing port 80 → 8080 |
| `app-api/servicemonitor.yaml` | Prometheus scrape target |
| `app-analysis/analysis-template.yaml` | Prometheus query for canary auto-decision |
| `app-alert/prometheus-rules.yaml` | SLO alert (success rate < 95%) |
| `app-common/demo-namespace.yaml` | demo namespace (labeled `gatekeeper: enforced`) |
| `terraform/main.tf` | AWS: IAM user + Secrets Manager secret |
| `src/api/app.py` | Flask app with /metrics + error injection |
| `src/api/Dockerfile` | Python 3.13-alpine container |
| `.github/workflows/build-push.yml` | CI/CD: build → Trivy → sign → deploy |
| `.github/workflows/validate.yml` | PR validation with kubeconform |
| `SETUP.md` | Full install guide from scratch |
| **Challenge files** | |
| `tenants/payments/namespace.yaml` | payments namespace with `gatekeeper: enforced` label |
| `tenants/payments/rbac.yaml` | Role + RoleBinding (no secrets, namespaced) |
| `tenants/payments/resource-quota.yaml` | Cap: 2 CPU / 4Gi memory / 10 pods |
| `tenants/payments/limit-range.yaml` | Default limits for unnamed pods |
| `tenants/payments/network-policy.yaml` | Ingress deny-all + egress restrict |
| `apps/payments/rollout.yaml` | Team B Rollout (2 replicas, simple canary) |
| `apps/payments/service.yaml` | Team B Service (port 80 → 8080) |
| `argocd/apps/payments.yaml` | ArgoCD app for payments infra (wave -1) |
| `argocd/apps/payments-app.yaml` | ArgoCD app for payments workload (wave 2) |
| `tenants/payments/.gitkeep` | Placeholder for empty file tracking |
