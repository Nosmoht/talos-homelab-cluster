# Cilium Upgrade Execution Record: 1.19.1 → 1.19.2

## Metadata

| Field | Value |
|-------|-------|
| Approved plan | `docs/cilium-upgrade-plan-1.19.1-to-1.19.2-2026-03-24.md` |
| Approved by | @Nosmoht |
| Execution date | 2026-03-24 |
| From version | 1.19.1 |
| To version | 1.19.2 |

## Baseline Health (Pre-Change)

- All 8 nodes Ready (node-01..06, node-gpu-01, node-pi-01)
- Talos v1.12.6, Kubernetes v1.35.0
- Cilium DaemonSet: `quay.io/cilium/cilium:v1.19.1`
- Cilium Operator: `quay.io/cilium/operator-generic:v1.19.1`
- Repo pin: `CILIUM_VERSION := 1.19.1`
- No drift between live cluster and repo
- All 24 ArgoCD applications: Synced/Healthy
- Gateway `homelab-gateway`: Programmed, VIP 192.168.2.70

## Commands Executed

### Phase 2: Repo Changes

1. Updated `talos/versions.mk`: `CILIUM_VERSION := 1.19.2`
2. Updated `talos/patches/controlplane.yaml`: cache-busting `?v=1.19.1-4` → `?v=1.19.2-1`
3. `make -C talos cilium-bootstrap` — regenerated bootstrap manifest
4. `make -C talos cilium-bootstrap-check` — passed (no static hubble tls secrets)
5. `make -C talos gen-configs` — regenerated all 8 node configs

### Phase 3: Commit and Push

```
git commit -m "chore(cilium): upgrade 1.19.1 → 1.19.2"
git push
```

Commit: `da2010e`

### Phase 4: Rollout

1. `make -C talos apply-node-01` — applied config (extraManifests URL diff only, no reboot)
2. Observed DaemonSet spec still at v1.19.1 — `apply-config` alone does not reconcile extraManifests
3. `make -C talos upgrade-k8s` — reconciled extraManifests across all control-plane nodes
   - Cilium agent, cilium-envoy, cilium-operator, hubble-relay all updated to v1.19.2 images
   - DaemonSet rolling restart triggered automatically

### Rollout Completion

- `kubectl -n kube-system rollout status ds/cilium` — completed (8/8 pods updated and available)
- `kubectl -n kube-system rollout status deploy/cilium-operator` — completed

## Final Verification

| Check | Result |
|-------|--------|
| Cilium DaemonSet image | `quay.io/cilium/cilium:v1.19.2@sha256:7bc7e0be845cae0a70241e622cd03c3b169001c9383dd84329c59ca86a8b1341` |
| Cilium Operator image | `quay.io/cilium/operator-generic:v1.19.2@sha256:e363f4f634c2a66a36e01618734ea17e7b541b949b9a5632f9c180ab16de23f0` |
| Cilium pods | 8/8 Running, 1/1 Ready, 0 restarts |
| Cilium Operator pods | 2/2 Running |
| CiliumNode objects | 8/8 present with correct IPs |
| `cilium-dbg status --brief` | OK |
| Hubble Relay | 1/1 Running |
| Hubble UI | 2/2 Running |
| Gateway `homelab-gateway` | Programmed, VIP 192.168.2.70 |
| L2 Announcement Policies | 2 active (homelab-l2, homelab-ui-l2) |
| LB IP Pools | 2 active, no conflicts |
| All nodes | 8/8 Ready |
| ArgoCD applications | 24/24 Synced/Healthy |
| Repo pin | `CILIUM_VERSION := 1.19.2` |

## Incidents

None. Upgrade completed without incidents.

## Notes

- `make -C talos apply-<node>` is insufficient for Cilium version bumps — the extraManifests URL change is recognized but Talos does not re-fetch and reconcile the manifest content. `make -C talos upgrade-k8s` is required to trigger extraManifests reconciliation.
- The `upgrade-k8s` command also re-applies kube-apiserver, kube-controller-manager, kube-scheduler, and kubelet configs (all already at v1.35.0, so these were no-ops with brief pod restarts).
