---
plan_source: plan-cilium-upgrade
from_version: 1.19.1
to_version: 1.19.2
generated_at: 2026-03-24
status: approved
approved_by: @Nosmoht
approved_at: 2026-03-24
---

# Cilium Upgrade Plan: 1.19.1 → 1.19.2

## Version Resolution

| Property | Value | Source |
|----------|-------|--------|
| From version | 1.19.1 | Live cluster DaemonSet image (`quay.io/cilium/cilium:v1.19.1`) confirmed matching `talos/versions.mk` — no drift |
| To version | 1.19.2 | Latest stable release per GitHub Releases API (published 2026-03-23, `isPrerelease: false`) |
| Version hop | Patch-only (1.19.1 → 1.19.2) | Same minor — no multi-minor skip concerns |
| Kubernetes compat | v1.35.0 running, supported by Cilium 1.19.x | CI added k8s 1.35 testing in this release |
| Talos compat | v1.12.6 | No Talos-specific constraints for this patch bump |

## Intermediate Releases Reviewed

Only one release between source and target:

| Version | Published | Source |
|---------|-----------|--------|
| v1.19.2 | 2026-03-23 | [GitHub Release](https://github.com/cilium/cilium/releases/tag/v1.19.2) |

## Cluster-Specific Findings

### Enabled High-Risk Features (from bootstrap manifest and live ConfigMap)

| Feature | Config Value | Upgrade Relevance |
|---------|-------------|-------------------|
| kube-proxy replacement | `true` | No changes in 1.19.2 |
| Gateway API | `true` (+ external Envoy proxy) | **Two Gateway API bugfixes** — hostname intersection fix for cert-manager challenges, TLSRoute attachment fixes |
| Hubble | `true` (relay + UI + metrics) | No Hubble-specific changes |
| L2 announcements | `true` | No changes |
| LB IPAM | `true` | Load-balancing backend slot fix (traffic misrouting with maintenance backends) |
| VXLAN tunnel mode | `routing-mode: tunnel` | No tunnel changes |
| L7 proxy | `true` | L7 LB hairpin redirect fix on bridge devices; bypassing ingress policies fix for local backends |
| External Envoy proxy | `true` | Envoy admin socket security fix (was world-accessible) |

### Repo-Managed Cilium Resources

- 58 files with `CiliumNetworkPolicy`, `CiliumClusterwideNetworkPolicy`, `CiliumLoadBalancerIPPool`, `CiliumL2AnnouncementPolicy`, `GatewayClass`, `Gateway`, or `HTTPRoute`
- `kubernetes/bootstrap/cilium/extras.yaml` — GatewayClass resource
- `kubernetes/bootstrap/cilium/values.yaml` — Helm values for bootstrap rendering
- `talos/patches/controlplane.yaml` — extraManifests URL with cache-busting `?v=1.19.1-4`

### Live vs Repo Comparison

- Live cluster: `v1.19.1` (DaemonSet + Operator images)
- Repo pin: `CILIUM_VERSION := 1.19.1`
- **No drift detected**

## Breaking Changes and Required Migrations

**None.** This is a patch release. The v1.19.2 release notes contain no breaking changes, no deprecations, no removed flags, and no default flips.

### Notable Bugfixes Relevant to This Cluster

1. **Gateway API hostname intersection fix** (cilium/cilium#44492) — fixes cert-manager ACME challenge routing. If you've seen cert-manager HTTP-01 challenges fail, this resolves it.
2. **L7 LB ingress policy bypass fix** (cilium/cilium#44693) — fixes bypassing ingress policies for local backends. Relevant because this cluster uses L7 proxy + external Envoy.
3. **Envoy admin socket permissions** (cilium/cilium#44512) — admin socket was created world-accessible; now properly restricted. Security improvement.
4. **LB backend slot gap fix** (cilium/cilium#43902) — fixes potential traffic misrouting when maintenance backends exist in service load balancing.
5. **Neighbor reconciler rate limiting** (cilium/cilium#43928) — reduces CPU usage and memory churn. Helpful for node-dense or churn-heavy workloads.
6. **XDP attach type upgrade fix** (cilium/cilium#44209) — enables upgrade/downgrade when existing XDP attach types differ from new programs.

### Not Relevant to This Cluster

- ztunnel/Helm changes (Istio ambient mesh — not used)
- IPSec key rotation fix (IPSec not enabled)
- aws-cni chaining fix (not using AWS CNI)
- VTEP ARP fix (VTEP disabled)
- ClusterMesh/MCS-API fixes (ClusterMesh disabled)
- BGP changes (BGP not used)

## Execution Plan

### Phase 1: Preflight (Before Any Changes)

```bash
# 1. Verify cluster health
KUBECONFIG=/tmp/homelab-kubeconfig kubectl get nodes -o wide
KUBECONFIG=/tmp/homelab-kubeconfig kubectl -n kube-system get pods -l k8s-app=cilium
KUBECONFIG=/tmp/homelab-kubeconfig kubectl -n kube-system get pods -l app.kubernetes.io/name=cilium-operator
KUBECONFIG=/tmp/homelab-kubeconfig kubectl get ciliumnode

# 2. Verify current version
KUBECONFIG=/tmp/homelab-kubeconfig kubectl -n kube-system get ds cilium \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
# Expected: quay.io/cilium/cilium:v1.19.1@sha256:...

# 3. Check for any pending policy drops or issues
KUBECONFIG=/tmp/homelab-kubeconfig kubectl -n kube-system exec ds/cilium -- \
  cilium-dbg status --brief

# 4. Verify Gateway traffic is flowing
KUBECONFIG=/tmp/homelab-kubeconfig kubectl get gateway -A
KUBECONFIG=/tmp/homelab-kubeconfig kubectl get httproute -A
```

### Phase 2: Repo Changes

```bash
# 1. Update version pin
# Edit talos/versions.mk:
#   CILIUM_VERSION := 1.19.2

# 2. Regenerate bootstrap manifest (uses helm template with new version)
make -C talos cilium-bootstrap

# 3. Validate the rendered manifest
make -C talos cilium-bootstrap-check

# 4. Update cache-busting param in controlplane.yaml extraManifests URL
# Change: ?v=1.19.1-4  →  ?v=1.19.2-1
# in talos/patches/controlplane.yaml

# 5. Regenerate Talos configs
make -C talos gen-configs

# 6. Dry-run all nodes
make -C talos dry-run-all
```

### Phase 3: Commit and Push

```bash
# Commit all changes
git add talos/versions.mk \
       kubernetes/bootstrap/cilium/cilium.yaml \
       talos/patches/controlplane.yaml
git commit -m "chore(cilium): upgrade 1.19.1 → 1.19.2

Patch release with Gateway API hostname intersection fix,
L7 LB ingress policy bypass fix, Envoy admin socket
permissions fix, and LB backend slot gap fix."
git push
```

### Phase 4: Roll Out via Talos Workflow

The bootstrap manifest is consumed via `extraManifests` in the control plane config. After pushing to `main`, the new manifest is available at the raw GitHub URL. Apply to control plane nodes first, then workers.

```bash
# Control plane nodes (one at a time, verify between each)
make -C talos apply-node-01
# Wait for cilium pods to restart on node-01, verify:
KUBECONFIG=/tmp/homelab-kubeconfig kubectl -n kube-system get pods -l k8s-app=cilium \
  --field-selector spec.nodeName=node-01
# Confirm new image version in pod

make -C talos apply-node-02
# Verify...

make -C talos apply-node-03
# Verify...

# Worker nodes
make -C talos apply-node-04
make -C talos apply-node-05
make -C talos apply-node-06
make -C talos apply-node-gpu-01
```

> **Note:** For a pure Cilium version bump (no Talos version change), `apply-<node>` is sufficient — it re-applies the config which includes the updated `extraManifests` URL. The Cilium DaemonSet update triggers a rolling restart. If Talos does not re-fetch the manifest due to caching, use `make -C talos upgrade-k8s` which forces `extraManifests` reconciliation.

### Phase 5: Alternative — `upgrade-k8s` Path

If per-node `apply` does not trigger Cilium pod restarts (due to Talos caching the old extraManifests URL), use:

```bash
make -C talos upgrade-k8s
```

This re-applies control-plane configuration including `extraManifests`, forcing the new bootstrap manifest to be fetched and applied.

## Validation Plan

### Immediate (After Each Node)

```bash
# Cilium agent version on the node
KUBECONFIG=/tmp/homelab-kubeconfig kubectl -n kube-system get pod -l k8s-app=cilium \
  --field-selector spec.nodeName=<node> \
  -o jsonpath='{.items[0].spec.containers[0].image}'
# Expected: quay.io/cilium/cilium:v1.19.2@sha256:7bc7e0be845cae0a70241e622cd03c3b169001c9383dd84329c59ca86a8b1341

# Cilium status
KUBECONFIG=/tmp/homelab-kubeconfig kubectl -n kube-system exec ds/cilium -- \
  cilium-dbg status --brief
```

### Post-Upgrade (All Nodes Complete)

```bash
# 1. All cilium pods running
KUBECONFIG=/tmp/homelab-kubeconfig kubectl -n kube-system get pods -l k8s-app=cilium
KUBECONFIG=/tmp/homelab-kubeconfig kubectl -n kube-system get pods -l app.kubernetes.io/name=cilium-operator

# 2. CiliumNode health
KUBECONFIG=/tmp/homelab-kubeconfig kubectl get ciliumnode

# 3. Operator version
KUBECONFIG=/tmp/homelab-kubeconfig kubectl -n kube-system get deploy cilium-operator \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
# Expected: quay.io/cilium/operator-generic:v1.19.2@sha256:e363f4f634c2a66a36e01618734ea17e7b541b949b9a5632f9c180ab16de23f0

# 4. Hubble relay
KUBECONFIG=/tmp/homelab-kubeconfig kubectl -n kube-system get pods -l k8s-app=hubble-relay

# 5. Gateway API — verify traffic
KUBECONFIG=/tmp/homelab-kubeconfig kubectl get gateway -A -o wide
# Check external IP is still assigned and listeners are programmed

# 6. L2 announcements — verify VIP
KUBECONFIG=/tmp/homelab-kubeconfig kubectl get ciliuml2announcementpolicy -A
KUBECONFIG=/tmp/homelab-kubeconfig kubectl get ciliumloadbalancerippool -A

# 7. Network policy — spot-check no unexpected drops
KUBECONFIG=/tmp/homelab-kubeconfig kubectl -n kube-system exec ds/cilium -- \
  hubble observe --type drop --last 100

# 8. Node connectivity (optional, thorough)
KUBECONFIG=/tmp/homelab-kubeconfig kubectl -n kube-system exec ds/cilium -- \
  cilium-dbg connectivity test --single-node
```

## Rollback and Recovery

### Rollback Path

Since this is a patch release within the same minor:

1. **Revert the repo commit** — `git revert <commit>` restores `CILIUM_VERSION := 1.19.1` and the old bootstrap manifest
2. **Regenerate and push** — `make -C talos cilium-bootstrap && git push`
3. **Re-apply** — `make -C talos upgrade-k8s` or per-node `apply-<node>`

Cilium supports rollback within the same minor version. The 1.19.1 → 1.19.2 hop introduces no schema, CRD, or data-plane format changes that would block a revert.

### Pre-Upgrade Safety

- The pre-upgrade bootstrap manifest is preserved in git history
- `talos/versions.mk` change is a single-line diff, trivially revertable

### If Cilium Pods Don't Recover

```bash
# Check pod events
KUBECONFIG=/tmp/homelab-kubeconfig kubectl -n kube-system describe pod -l k8s-app=cilium

# Check agent logs
KUBECONFIG=/tmp/homelab-kubeconfig kubectl -n kube-system logs ds/cilium --tail=200

# If crash-looping, revert to 1.19.1 (see rollback path above)
```

### If Gateway Traffic Fails

```bash
# Check Envoy proxy pods
KUBECONFIG=/tmp/homelab-kubeconfig kubectl -n kube-system get pods -l k8s-app=cilium-envoy

# Check gateway status
KUBECONFIG=/tmp/homelab-kubeconfig kubectl get gateway homelab-gateway -n infrastructure -o yaml

# If broken, revert (Gateway API changes in 1.19.2 are bugfixes, so revert is safe)
```

### If Policy Drops Spike

```bash
# Identify affected pods
KUBECONFIG=/tmp/homelab-kubeconfig kubectl -n kube-system exec ds/cilium -- \
  hubble observe --type drop --last 500

# The L7 LB policy bypass fix (cilium/cilium#44693) could change behavior
# if traffic was previously bypassing ingress policies incorrectly.
# If this surfaces new drops, they represent traffic that SHOULD have been
# policy-checked but wasn't. Add appropriate CNP rules rather than rolling back.
```

## Risks and Open Questions

### Low Risk

1. **L7 LB ingress policy fix may surface new policy drops** — If local-backend traffic was previously bypassing ingress policies (the bug fixed in #44693), upgrading will enforce those policies correctly. This is the intended behavior but could cause unexpected denials if CNPs are incomplete. **Mitigation:** Monitor `hubble observe --type drop` after upgrade; add missing CNP rules if needed.

2. **Talos extraManifests caching** — Talos caches extraManifests by URL. The cache-busting query parameter (`?v=1.19.2-1`) should force re-download, but if Talos doesn't re-fetch, use `make -C talos upgrade-k8s`. **Mitigation:** Verify pod image tag after apply.

### Open Questions

1. **Is `make -C talos apply-<node>` sufficient or is `upgrade-k8s` required?** — For a pure Cilium version bump with no Talos version change, `apply` should work if the extraManifests URL changed (cache-busting param). Verify on node-01 before proceeding to other nodes.

## Self-Review

### What Was Checked

- [x] Single version hop reviewed (1.19.1 → 1.19.2 patch release)
- [x] Target release is stable (not RC/beta), published 2026-03-23
- [x] Live cluster version and repo pin compared — no drift
- [x] Kubernetes v1.35.0 compatibility confirmed (CI testing added in this release)
- [x] Talos v1.12.6 compatibility — no constraints
- [x] All enabled Cilium features mapped against release changes
- [x] Commands use repo's GitOps and Talos operating model (`make -C talos` targets)
- [x] No step uses `kubectl apply` against ArgoCD-managed or bootstrap-managed resources
- [x] No `--reuse-values` used
- [x] Rollback path documented
- [x] Envoy admin socket security fix noted (relevant to external-envoy-proxy: true)

### What Was Uncertain

- Whether `make -C talos apply-<node>` alone triggers extraManifests re-fetch, or whether `upgrade-k8s` is needed. Both paths are documented.
- Whether the L7 LB policy bypass fix will surface new drops in this cluster. Called out as a risk with monitoring guidance.

### Assessment

**Safe to execute as written.** This is a low-risk patch upgrade within the same minor version. No breaking changes, no migration actions required. The most impactful change is the L7 LB ingress policy enforcement fix, which corrects previously-broken behavior — monitor for new policy drops post-upgrade.
