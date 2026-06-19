# W10 — Project Introduction & Evidence

## Giới thiệu

Dự án này triển khai một Kubernetes cluster **production-ready** với GitOps, bảo mật đa tầng, và multi-tenant isolation.

**Kiến trúc tổng quan:**

```
GitHub (source of truth)
  │ git push
  ▼
ArgoCD (GitOps — tự động sync cluster từ repo)
  │
  ├── RBAC              → 3 roles: developer, sre, viewer
  ├── Gatekeeper        → 6 OPA/Rego constraints chặn manifest xấu
  ├── ESO               → Secret tự động đồng bộ từ AWS Secrets Manager
  ├── Sigstore/Cosign   → Verify chữ ký image trước khi deploy
  ├── Prometheus Stack  → Metrics + SLO alerts + canary analysis
  └── Payments tenant   → Multi-tenant isolation (Challenge)
```

**Công nghệ sử dụng:** Kubernetes, ArgoCD, Argo Rollouts, OPA Gatekeeper, External Secrets Operator, Sigstore Policy Controller, Cosign, Trivy, Prometheus, Terraform.

---

## Lab 1 — RBAC + Gatekeeper (Buổi sáng)

### Đã làm
- 3 ClusterRoles (`developer`, `sre`, `viewer`) + bindings, phân quyền rõ ràng
- Gatekeeper operator cài qua Helm, 6 ConstraintTemplates + Constraints:
  - `K8sRequiredLabels` — bắt buộc label `owner`
  - `K8sRequiredResources` — bắt buộc `resources.limits`
  - `K8sBlockLatestTag` — cấm tag `:latest`
  - `K8sBlockRootUser` — cấm `runAsUser: 0`
  - `K8sBlockHostNetwork` — cấm `hostNetwork: true`
  - `K8sAllowedRegistries` — chỉ cho phép registry tin cậy (custom Rego)
- Constraint dùng `namespaceSelector` với label `gatekeeper: enforced` — namespace mới tự động thừa hưởng

### Tự kiểm
```
✅ auth can-i khớp đúng 3 role
✅ 6 constraint reject vi phạm, pass hợp lệ
✅ Platform xanh sau khi bật enforce
✅ Mọi thứ qua git → ArgoCD Synced
```

---

## Lab 2 — ESO + Supply Chain (Buổi chiều)

### Đã làm
- **ESO**: SecretStore + ExternalSecret sync `w10/db-password` từ AWS Secrets Manager, refresh 60s
- **Terraform**: IAM user `eso-sync` + access key + Secrets Manager secret
- **Trivy**: Scan image trong CI, fail nếu CVE CRITICAL/HIGH
- **Cosign**: Ký image sau khi scan pass
- **Sigstore Policy Controller**: Verify chữ ký tại admission, chặn image chưa ký
- **Catch-all policy**: `allow-all-other` cho image không phải w10

### Tự kiểm
```
✅ ESO rotate < 60s, pod không restart
✅ CI đỏ khi CVE HIGH
✅ Unsigned image bị reject
✅ git log -p | grep -i password → không lộ secret
```

---

## Challenge — Onboard team `payments` (Take-home 24h)

### Nộp gì

```
tenants/payments/   # ns · rbac · quota · netpol
apps/payments/      # workload team B
argocd/apps/        # payments.yaml (infra) + payments-app.yaml (app)
evidence/           # 4 proofs with screenshots/logs
README.md           # explanation
```

### 4 chứng minh (ĐẠT — đủ cả 4)

#### 1. RBAC isolation — `payments-dev`

```
kubectl auth can-i create deployments -n payments --as payments-dev     → yes
kubectl auth can-i create deployments -n demo --as payments-dev         → no
kubectl auth can-i get secrets -n payments --as payments-dev            → no
kubectl auth can-i create rolebindings -n payments --as payments-dev    → no
```

> Screenshot: `evidence/challenge-rbac.png`

#### 2. ResourceQuota + LimitRange

```
kubectl get resourcequota -n payments
  → payments-quota: 2 CPU / 4Gi memory / 10 pods

# Vượt quota → bị từ chối
kubectl run exceed --image=registry.k8s.io/pause:3.10 -n payments \
  --labels=owner=test --requests=cpu=4,memory=8Gi \
  --overrides='{"spec":{"containers":[{"name":"pause","image":"registry.k8s.io/pause:3.10","resources":{"limits":{"cpu":"4","memory":"8Gi"},"requests":{"cpu":"4","memory":"8Gi"}}}]}}'
  → Forbidden: exceeded quota

# Pod thiếu limits vẫn chạy nhờ LimitRange
kubectl run no-limits --image=registry.k8s.io/pause:3.10 -n payments \
  --labels=owner=test
  → pod/no-limits created (LimitRange injects defaults)
```

> Screenshot: `evidence/challenge-quota.png`

#### 3. NetworkPolicy — cô lập

```
kubectl get networkpolicy -n payments
  → default-deny-ingress   (chặn ai gọi vào payments)
  → restrict-egress        (chỉ gọi trong payments + DNS)

# Pod trong payments không gọi được api.demo.svc
kubectl run test-curl --image=curlimages/curl:latest -n payments \
  --labels=owner=test --rm -it --restart=Never -- \
  curl -s --connect-timeout 3 http://api.demo.svc
  → Connection timed out (nếu CNI enforce)
```

> Screenshot: `evidence/challenge-netpol.png`

#### 4. Gatekeeper tự động áp dụng (quan trọng nhất)

Constraint dùng `namespaceSelector.matchLabels.gatekeeper: enforced` — không hardcode namespace.

```
# payments namespace có label
kubectl get ns payments -o jsonpath='{.metadata.labels}'
  → {"gatekeeper":"enforced","kubernetes.io/metadata.name":"payments"}

# Constraint cũ tự động chặn vi phạm trong payments (không cần tạo luật mới)
kubectl run bad --image=nginx:latest -n payments --restart=Never
  → Forbidden: uses :latest tag

kubectl run bad --image=unknown.registry.io/pause:1.0 -n payments \
  --labels=owner=test --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"pause","image":"unknown.registry.io/pause:1.0","resources":{"limits":{"cpu":"100m","memory":"128Mi"}}}]}}'
  → Forbidden: uses untrusted registry
```

> Screenshot: `evidence/challenge-gk-auto-enforce.png`

### Vì sao guardrail cũ tự áp cho team B?

Constraint chuyển từ `namespaces: ["demo"]` sang `namespaceSelector.matchLabels.gatekeeper: enforced`. Khi namespace `payments` có label `gatekeeper: enforced`, tất cả 6 constraint tự động match. Thêm team mới: chỉ cần `kubectl label ns team-c gatekeeper=enforced`.

### Vì sao Role/RoleBinding giữ cô lập?

`Role` + `RoleBinding` là namespaced — user `payments-dev` chỉ có quyền trong namespace `payments`. Không dùng `ClusterRole`/`ClusterRoleBinding` vì sẽ cho quyền sang namespace khác (vd `demo`). Role cũng không cấp `secrets` hay `rolebindings` để tránh leo thang đặc quyền.

---

## Evidence screenshots

Place these in `evidence/`:

| File | Nội dung |
|---|---|
| `challenge-rbac.png` | 4 lệnh `auth can-i` cho payments-dev |
| `challenge-quota.png` | Quota hiện tại + lệnh vượt quota bị chặn |
| `challenge-netpol.png` | `kubectl get networkpolicy -n payments` |
| `challenge-gk-auto-enforce.png` | Vi phạm bị constraint cũ chặn trong payments |
| `rbac-roles.png` | 3 role verified (alice, bob, carol) |
| `gatekeeper-constraints.png` | 6 constraint đều deny |
| `eso-secret.png` | Secret sync từ AWS |
| `sigstore-deny.png` | Unsigned image bị chặn |
| `argocd-synced.png` | Tất cả app Synced/Healthy |
