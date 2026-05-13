# ArgoCD Self-Cutover Runbook

ArgoCD is one of the 18 components migrated to the rendered-manifests
pattern in Phase D. Unlike the other 17, ArgoCD cannot self-apply the
new manifests cleanly: the moment the new ArgoCD Application begins
syncing its own resources, the running ArgoCD pods can be restarted
mid-transaction and the sync aborts. Team-red finding C4 captures
this risk.

This runbook documents the out-of-band procedure that avoids the
chicken-and-egg.

Cross-refs:
- [`../talos-platform-base/.work/rendered-manifests-migration/plan-v2.md`](../../talos-platform-base/.work/rendered-manifests-migration/plan-v2.md) §Phase D.5
- [`../talos-platform-base/.work/rendered-manifests-migration/team-red-findings.md`](../../talos-platform-base/.work/rendered-manifests-migration/team-red-findings.md) §C4
- `docs/rendered-manifests-application-patterns.md` (the standard 3-App split)

## When this runbook applies

**Only at Phase D cutover.** Day-to-day ArgoCD upgrades after the
migration follow the standard rendered-manifests path (PR → re-render
→ ArgoCD self-syncs the change).

The risk this runbook mitigates is **the one-time switch** from
ArgoCD-managed-by-Helm-at-sync-time to ArgoCD-managed-by-rendered-
directory. After that switch, future config changes to ArgoCD are just
text changes in `_rendered/manifests.yaml` that ArgoCD applies to
itself the same way it applies any other Application — small, safe,
incremental.

## Pre-conditions

1. Every other migrated component (the 17 non-ArgoCD ones) is already
   on the rendered-manifests pattern and reports
   `argocd app list` Synced/Healthy.
2. `vendor/base/` has been pulled at the cutover tag (e.g. `v0.2.0`)
   and `make verify-consumer-rendered` exits 0.
3. `kubernetes/overlays/homelab/infrastructure/argocd/_rendered/manifests.yaml`
   has been generated and committed (Phase C.3) but the ArgoCD
   Application's `kustomization.yaml` STILL points at the old
   Multi-Source pattern. (See note below — this is the order that
   keeps the existing ArgoCD installation operational throughout.)
4. `vault-unseal-keys` Secret in the `vault` namespace is intact
   (Phase A bank-vaults dependency — irrelevant to ArgoCD itself, but
   worth re-checking before any cluster-critical change).

## Procedure

### Step 1 — Verify the rendered manifests are sane

```bash
# Inspect what would be applied. Do NOT pipe directly into kubectl yet.
diff -u \
  <(kubectl get -n argocd deploy argocd-server -o yaml | yq 'del(.metadata.managedFields, .metadata.resourceVersion, .metadata.uid, .metadata.generation, .status, .metadata.creationTimestamp)') \
  <(yq 'select(.kind == "Deployment" and .metadata.name == "argocd-server")' \
      vendor/base/kubernetes/base/infrastructure/argocd/_rendered/manifests.yaml)
```

Sanity check:

- The diff should show only platform-base-overlay-driven changes
  (labels, annotations, capability-* labels). No image bumps unless
  this PR is intentionally also a chart upgrade. No secret data.

If anything unexpected appears, STOP. Fix the diff in a follow-up PR
before continuing.

### Step 2 — Apply with SSA + force-conflicts (out-of-band)

```bash
# CSA cleanup first, scoped to argocd namespace + ArgoCD-owned cluster
# resources (CRDs, ClusterRoles, ClusterRoleBindings).
scripts/cleanup-csa-annotation.sh argocd

# Then: out-of-band kubectl apply, NOT argocd app sync.
kubectl apply --server-side --force-conflicts \
  -f vendor/base/kubernetes/base/infrastructure/argocd/_rendered/manifests.yaml \
  -f vendor/base/kubernetes/base/infrastructure/argocd/_rendered/crds.yaml
```

ArgoCD pods will restart as their Deployment specs change. This is
expected. The kubectl apply runs out-of-band, so it does not depend
on ArgoCD being available.

`--server-side --force-conflicts` is the correct combination for SSA
ownership takeover. Team-red C2 documented that
`argocd app sync --force` is unrelated to SSA.

### Step 3 — Wait for ArgoCD to stabilize

```bash
kubectl wait --for=condition=Available -n argocd deploy/argocd-server --timeout=300s
kubectl wait --for=condition=Available -n argocd deploy/argocd-repo-server --timeout=300s
kubectl wait --for=condition=Available -n argocd deploy/argocd-application-controller --timeout=300s
```

If any of these time out, debug the new pods (`kubectl logs`,
`kubectl describe`) before continuing. Until they are Available, the
cluster has no GitOps reconciliation.

### Step 4 — Switch the Application manifest

Edit `kubernetes/overlays/homelab/infrastructure/argocd/application.yaml`
to remove the Multi-Source block and adopt the standard pattern from
`docs/rendered-manifests-application-patterns.md`:

```yaml
spec:
  source:
    repoURL: https://github.com/Nosmoht/talos-homelab-cluster.git
    targetRevision: main
    path: kubernetes/overlays/homelab/infrastructure/argocd/_rendered
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions:
      - ServerSideApply=true
      - RespectIgnoreDifferences=true
      - CreateNamespace=false
```

Commit and push. ArgoCD will sync this change to itself; because the
underlying resources are now bit-identical to what kubectl already
applied in step 2, the sync is a no-op (Synced + Healthy immediately).

### Step 5 — Verify the loop closed

```bash
argocd app get argocd
# Expected:
#   Status: Synced
#   Health: Healthy
#   Sync Status: Synced (revision = current main HEAD)
```

If `Status: OutOfSync`, ArgoCD's view of the desired state diverges
from what was applied in step 2. Most likely cause: a field that the
ArgoCD operator (or another controller) mutates at runtime needs to
be added to `ignoreDifferences`. Diagnose with `argocd app diff
argocd`.

## Failure modes

### "ArgoCD restarts mid-transaction"

This is the C4 risk this runbook mitigates. Symptom: an `argocd app
sync argocd` invocation triggers `argocd-server` to restart while the
Application controller is still processing the sync transaction; the
sync ends in `OperationFailed` and partial application leaves the
cluster in an undefined state.

**Mitigation**: never `argocd app sync argocd` for the cutover. Steps
1–5 above run kubectl directly so ArgoCD's own availability is not in
the dependency chain.

### "redis password changes break the application controller"

If the new ArgoCD chart version changes the Redis-password mechanism
(externalSecret vs autogen), the application-controller may fail to
reach Redis after step 2 and remain CrashLoopBackOff.

**Mitigation**: as part of step 1 sanity check, diff the `argocd-redis`
Secret expected vs current. If the Secret name or data changes, step 2
should also include `kubectl apply` of the new Secret (or operator
manually populates it from Vault if it is now ESO-managed). Since
ArgoCD redis Secret is not part of the Phase A migration scope (only
the 7 listed in `docs/secrets-vault-paths.md` are), this is a
follow-up risk if a future chart bump moves redis to ESO.

### "vendor/base mismatch between the diff and the apply"

Steps 1 and 2 both reference `vendor/base/`. If the operator runs
step 1, then `make pull-base-oci` updates vendor/base/ to a different
tag, then runs step 2, the kubectl apply writes a different version
than what the diff showed.

**Mitigation**: do not interleave `make pull-base-oci` between steps
1 and 2. Pin `.base-version` for the entire procedure. Re-pull only if
the cutover is restarted.

## After the cutover

ArgoCD self-management is now in steady state:

- Future PRs that change `kube-prometheus-stack/values.yaml` (or any
  other render input) generate a new rendered output, the diff lands
  in `vendor/base/`, the consumer Application's
  `_rendered/manifests.yaml` re-renders, ArgoCD picks up the change
  and reconciles.
- ArgoCD's own version bumps follow the same path: bump
  `talos-platform-base` chart.lock.yaml for argo-cd, re-render, tag a
  new OCI version, consumer pulls, ArgoCD self-syncs the new
  Deployment image.
- Step 1's diff command remains a valid ad-hoc sanity check before
  any consequential ArgoCD change.

The runbook itself is single-use — preserve it for documentation but
the cutover only happens once per cluster.
