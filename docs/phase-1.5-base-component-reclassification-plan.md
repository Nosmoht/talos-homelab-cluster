# Phase 1.5 — Base-Component-Reklassifikation

**Status:** Proposed
**Created:** 2026-04-30
**Supersedes scope of:** none (gap fix between Phase 1 / PR #153 and Plan #1 execution)
**Blocks:** Plan #1 execution (`docs/talos-platform-base-creation-plan.md`)
**Operates on:** `github.com/Nosmoht/Talos-Homelab` (source repo, non-destructive to downstream split)

## Why Phase 1.5 exists

Phase 1 (PR #153 — `de-homelab-ify Talos patches, Makefile, ArgoCD bootstrap`) classified components by **directory location** (`kubernetes/base/` = base, `kubernetes/overlays/homelab/` = cluster). This passed the obvious tests but left two structural defects in place:

1. **Backend providers parked in base.** Six operators are *Backend Providers* (cloudnative-pg, redis-operator, strimzi-kafka-operator, omada-controller, minio, minio-operator), not platform-generic concerns. A second-tenant cluster might choose Crunchy Postgres, ElastiCache, MSK, Ubiquiti, S3-on-Cloudflare, or a managed object store — none of these would inherit the homelab's specific operator choices. Backend choice is a tenant decision, not a platform decision.

2. **Generic platform building blocks parked in overlay.** Three overlay-only components (`kubevirt`, `kubevirt-cdi`, `multus-cni`) are platform-generic — any tenant cluster running VMs needs the same operator+CR shape. Their current overlay placement is historical (introduced when only the homelab existed), not architectural.

3. **Hardcoded backend reference in base.** `kubernetes/base/infrastructure/loki/values.yaml:17` carries `endpoint: minio.minio.svc.cluster.local:443` — a concrete S3 backend coordinate. A tenant cluster without an in-cluster MinIO cannot start Loki without forking base values. This is a layering violation.

Without this cleanup, **Plan #1 (`talos-platform-base` v0.1.0)** would either:
- Ship the 6 backend providers as base — locking every tenant cluster into the homelab's backend choices, OR
- Silently drop them via filter-repo path tweaking — drifting the base repo from the source repo and inverting the non-destructive principle.

Phase 1.5 closes the gap **in the source repo first**, so Plan #1 just inherits a clean `kubernetes/base/`.

## Architectural principle (confirmed by user 2026-04-30)

> **Authentication and Observability are platform concerns and belong in base. Their backend storage is a tenant choice and belongs in overlay.**

| Layer | Lives in | Examples |
|---|---|---|
| **Platform Consumer** (the *what*) | base | Dex (auth), Loki / Grafana / kube-prometheus-stack / Tetragon / Alloy (observability) |
| **Backend Provider** (the *how*) | overlay | cloudnative-pg → Postgres for Dex; minio → S3 for Loki; redis/kafka/omada → tenant workloads |

**PNI is the contract layer.** Base consumers declare a capability via PNI labels (`platform.io/consume.cnpg-postgres`, `platform.io/consume.s3-object`), the overlay binds the capability to a concrete backend (cnpg cluster + secret, MinIO tenant + credentials). Dex is already correctly factored this way; Loki is not (it has a hardcoded endpoint).

## Scope — Three Workstreams

### Workstream A — Remove from base (6 components)

These are Backend Providers that ship cluster-specific operator+CR pairs. They belong fully in overlay.

| Component | Current `base/` | Current `overlays/homelab/` | After |
|---|---|---|---|
| `cloudnative-pg` | `values.yaml` | full overlay (with cluster CRs) | base dir **removed**; overlay self-contained |
| `redis-operator` | `values.yaml` | full overlay (with smoke-cluster) | base dir **removed**; overlay self-contained |
| `strimzi-kafka-operator` | `values.yaml` | full overlay | base dir **removed**; overlay self-contained |
| `omada-controller` | `values.yaml` | full overlay | base dir **removed**; overlay self-contained |
| `minio` | `kustomization.yaml`, `namespace.yaml`, `values.yaml` | full overlay | base dir **removed**; overlay self-contained |
| `minio-operator` | `kustomization.yaml`, `namespace.yaml`, `values.yaml` | full overlay | base dir **removed**; overlay self-contained |

**Migration mechanic per component:**
1. Inline the base content into the overlay (overlay's `kustomization.yaml` already references `../../../../base/infrastructure/<comp>` — replace this reference with literal resources or with overlay-local equivalents)
2. Delete the `kubernetes/base/infrastructure/<comp>/` directory
3. `kustomize build kubernetes/overlays/homelab` must produce byte-identical output (or a justified diff documented in the PR)

### Workstream B — Move into base (3 components)

These are platform-generic. Their overlay-only placement is historical, not architectural.

| Component | Current `overlays/homelab/` | Resource shape | After |
|---|---|---|---|
| `kubevirt-cdi` | `cdi-operator.yaml`, `cdi-cr.yaml` | Pure operator install + standard CR | base/ **created**; overlay just wraps Application |
| `multus-cni` | `crd.yaml`, `daemonset.yaml`, `rbac.yaml` | Pure CNI plumbing | base/ **created**; overlay just wraps Application |
| `kubevirt` (split) | `kubevirt-operator.yaml`, `kubevirt-cr.yaml`, `net-attach-def-vm-vlan.yaml` | Operator+CR generic; net-attach-def cluster-specific | Operator + CR → base; net-attach-def stays overlay |

**Note on `gateway-api`:** Re-examined and **kept overlay-only (no move)**. The Gateway-API CRDs themselves ship via Talos `extraManifests` (URL pin), so there is no CRD content to "move into base." Everything in `overlays/homelab/infrastructure/gateway-api/resources/` is cluster-specific (Gateway with VIP, GatewayClassConfig with provider details, certificates with hostnames, redirect HTTPRoute). Earlier reasoning that flagged it for migration was wrong; this plan corrects it.

**Migration mechanic per component:**
1. Create `kubernetes/base/infrastructure/<comp>/` with `kustomization.yaml`, `namespace.yaml` (where applicable), and the generic resources copied from overlay
2. Strip `app.kubernetes.io/instance: homelab` and `app.kubernetes.io/part-of: homelab` labels from base copies (these are Kustomize-`commonLabels`-overridable and therefore cluster-suffix in nature)
3. Replace overlay's `resources:` listing with `../../../../base/infrastructure/<comp>` reference
4. Verify `kustomize build kubernetes/overlays/homelab` produces byte-identical output (modulo label-source attribution)

### Workstream C — Refactor Loki S3 endpoint (1 file)

The base file `kubernetes/base/infrastructure/loki/values.yaml:17` contains:

```yaml
endpoint: minio.minio.svc.cluster.local:443
```

This is a **concrete backend coordinate** in a base file — violation. The fix:

**Option C1 (chosen): overlay Helm-values patch.** Move the `endpoint:` line out of `base/infrastructure/loki/values.yaml` into `overlays/homelab/infrastructure/loki/values.yaml` (or equivalent overlay patch mechanism that aligns with existing patterns in this repo). Base values keeps everything else; overlay supplies the endpoint.

**Why C1, not C2 (ConfigMap-ref) or C3 (HelmRelease postRenderer):** This repo already uses overlay-Helm-values composition (e.g. `kubernetes/overlays/homelab/infrastructure/dex/values.yaml`). Following the existing pattern minimizes review surface.

**Verification:** `kustomize build kubernetes/overlays/homelab | grep -A2 "schema_config\|s3:"` must show the homelab endpoint after refactor; an overlay omitting the endpoint must produce a Helm error or empty endpoint (proving base no longer carries the value).

## Acceptance criteria

1. **A.1** `kubernetes/base/infrastructure/{cloudnative-pg,redis-operator,strimzi-kafka-operator,omada-controller,minio,minio-operator}/` directories do not exist.
2. **A.2** `kubernetes/base/infrastructure/{kubevirt,kubevirt-cdi,multus-cni}/` directories exist with `kustomization.yaml` + generic resources.
3. **A.3** `kubernetes/overlays/homelab/infrastructure/kubevirt/resources/net-attach-def-vm-vlan.yaml` still present in overlay (split confirmed).
4. **A.4** `kubernetes/base/infrastructure/loki/values.yaml` does not contain `minio.minio.svc.cluster.local` literal.
5. **A.5** `kustomize build kubernetes/overlays/homelab` exits 0 and produces a manifest set that includes all previously-deployed resources (Loki running with S3 endpoint resolved, KubeVirt CR present, Multus DaemonSet present, MinIO operator present).
6. **A.6** `make -C talos dry-run-all` exits 0 (Talos config unaffected, regression guard).
7. **A.7** `kubectl apply -k kubernetes/overlays/homelab --dry-run=client` exits 0.
8. **A.8** Diff of `kustomize build` output **before** vs **after** Phase 1.5 contains only:
   - Label re-attribution (`app.kubernetes.io/part-of: homelab` source moves from base to overlay-commonLabels — value identical)
   - The Loki endpoint line position (still present in final output, sourced from overlay instead of base)
   - No resource additions / deletions / value changes
9. **A.9** No literal `homelab` in any file under `kubernetes/base/infrastructure/{kubevirt,kubevirt-cdi,multus-cni}/` after the move.
10. **A.10** `gitleaks` + `hard-constraints-check.yml` CI gates green.

## Execution order (single PR or two-PR-split — TBD)

**Recommended: single PR per workstream, three PRs total** (independent risk, clean revert path):
1. **PR α:** Workstream A — 6 base directories removed, overlays self-contained. Smallest blast radius (no resource churn, just reference inlining).
2. **PR β:** Workstream B — 3 components moved into base. Medium risk (resource source attribution changes).
3. **PR γ:** Workstream C — Loki endpoint refactor. Smallest file delta but highest semantic risk (Loki must stay healthy in homelab).

**Inter-PR validation gate:** after each merge to `main`, ArgoCD homelab sync must reach Healthy (or stay Healthy) before the next PR opens. This is a hard gate — no parallelization.

## Risks & mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| `kustomize build` diff non-empty after Workstream A inlining | Medium | Medium — overlay drifts | Snapshot `kustomize build` output to `/tmp/before.yaml` before any edit; diff after each edit; require empty diff (modulo label source) before commit |
| Loki Helm chart re-renders different S3 config when endpoint moves to overlay | Low | High — log pipeline outage | Render Loki StatefulSet+ConfigMap before+after; diff must be byte-identical for the rendered output |
| ArgoCD goes OutOfSync on label-source attribution change (Workstream B) | Medium | Low — false drift signal | Use Kustomize `commonLabels` in overlay to preserve identical `app.kubernetes.io/part-of: homelab` attribution; verify ArgoCD diff post-merge |
| Hidden cross-reference: a base manifest references one of the 6 to-be-removed components | Low | High — broken kustomize build | Pre-flight: `grep -rn "cloudnative-pg\|redis-operator\|strimzi\|omada\|minio" kubernetes/base/` excluding loki/values.yaml; resolve all hits before Workstream A |
| KubeVirt CR re-applied with different resource UID after move | Medium | Medium — VM downtime | KubeVirt CR is cluster-singleton — drift will be reconciled in-place by ArgoCD; verify via `kubectl get kubevirt -n kubevirt -o yaml` before+after |
| Loki refactor breaks Loki for other clusters | N/A | N/A | Only homelab today; other tenant clusters not yet in base/ consumption (Plan #1 not executed yet) |

## Out of scope (explicit)

- Any change to `talos/` directory tree (machine config, schematics, patches) — Phase 1.5 is purely Kubernetes-layer.
- Renaming `kubernetes/overlays/homelab/` → `kubernetes/overlays/<other>/` — that is Plan #3's scope.
- Filter-repo on the source repo — non-destructive principle holds; Phase 1.5 is normal commits in source repo.
- Creating the new repos (`talos-platform-base`, `talos-homelab-cluster`) — Plan #1 / Plan #3 territory, post-Phase-1.5.
- PNI capability registry changes — already correct (Dex consumes `cnpg-postgres`, Loki consumes `s3-object`).
- Office-lab scaffold — out of scope per user directive.

## Source-state pin

This plan is valid against `Talos-Homelab/main` HEAD `99657d3` (the ADR amendment commit) **plus** any merges between drafting and PR α opening. Plan #1 (PR #157) and Plan #3 (PR #158) are merged but **not yet executed**, which is the correct sequence — Phase 1.5 lands in source, then Plans #1 and #3 inherit a clean source.

## Test plan (per-PR checklist)

- [ ] Snapshot `kustomize build kubernetes/overlays/homelab > /tmp/before-<workstream>.yaml`
- [ ] Apply edits per workstream
- [ ] `kustomize build kubernetes/overlays/homelab > /tmp/after-<workstream>.yaml`
- [ ] `diff /tmp/before-<workstream>.yaml /tmp/after-<workstream>.yaml` reviewed; only allowed deltas present
- [ ] `kubectl apply -k kubernetes/overlays/homelab --dry-run=client` exits 0
- [ ] `make -C talos dry-run-all` exits 0
- [ ] CI workflows green (`gitleaks`, `hard-constraints-check`, kustomize render)
- [ ] Post-merge: ArgoCD homelab application reaches Healthy within 5 min, or rollback issued
- [ ] Post-merge (Workstream C): `kubectl logs -n loki loki-0 --tail=50` shows successful S3 connection to MinIO

## Effort estimate (AI-time)

- Workstream A (6 removals): ~30 min planning verification + ~1 h execution+review per Backend (parallel-safe within PR α since they're independent)
- Workstream B (3 moves): ~45 min per move (label-source diff verification dominates)
- Workstream C (Loki refactor): ~30 min (small file delta, larger render-diff verification)
- **Total: ~4–6 h of agent-time across 3 PRs**, gated by post-merge ArgoCD reconcile windows (~5–15 min each).

## Sequencing into broader migration

```
ADR amend (#154 ✓ merged)
  → Plan #1 created (#157 ✓ merged)
  → Plan #2 harness (#156 ✓ merged)
  → Plan #3 created (#158 ✓ merged)
  → Phase 1.5 plan (THIS DOCUMENT)
  → Phase 1.5 execution (3 PRs against Talos-Homelab)
  → Plan #1 execution (talos-platform-base creation, OCI publish)
  → Plan #3 execution (talos-homelab-cluster creation, Multi-Source rewrite)
  → Plan #2 execution (kube-agent-harness extension as plugin)
  → Phase 3D (live homelab cutover)
```
