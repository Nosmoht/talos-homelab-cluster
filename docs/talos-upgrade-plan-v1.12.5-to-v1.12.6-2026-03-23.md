---
plan_source: plan-talos-upgrade
from_version: v1.12.5
to_version: v1.12.6
generated_at: 2026-03-23
status: approved
approved_by: @Nosmoht
approved_at: 2026-03-23
---

# Talos Upgrade Plan: v1.12.5 → v1.12.6

## Resolved Versions

| Component | Current | Target | Notes |
|-----------|---------|--------|-------|
| Talos | v1.12.5 | v1.12.6 | Patch release, same minor |
| Linux kernel | 6.18.15 | 6.18.18 | Three kernel patch releases |
| Kubernetes (repo pin) | v1.35.0 | v1.35.0 | **No change** — repo keeps v1.35.0 |
| Kubernetes (Talos bundled) | v1.35.2 | v1.35.2 | Talos ships v1.35.2, but repo pin governs |
| etcd | 3.6.8 | 3.6.8 | No change |
| Cilium | 1.19.1 | 1.19.1 | **No change** |
| runc | — | 1.3.5 | Updated in v1.12.6 |
| Go | 1.25.8 | 1.25.8 | No change |
| containerd | 2.1.6 | 2.1.6 | No change |

**How versions were determined:**
- `from-version`: Live cluster query (`kubectl get nodes -o wide`) and `talos/versions.mk` both show v1.12.5 — no drift. All 8 nodes running v1.12.5 with kernel 6.18.15-talos.
- `to-version`: GitHub releases API (`repos/siderolabs/talos/releases`), filtered for non-prerelease/non-draft, semver sorted. v1.12.6 is the highest stable release (published 2026-03-19).

**Kubernetes compatibility:** Talos v1.12 supports K8s 1.30–1.35. The repo-pinned v1.35.0 remains fully supported.

## Reviewed Releases

### v1.12.6 (2026-03-19)

**Source:** https://github.com/siderolabs/talos/releases/tag/v1.12.6

**Component updates:**
- Linux kernel 6.18.15 → 6.18.18 (three kernel patch releases)
- runc updated to 1.3.5
- go-blockdevice v2.0.24 → v2.0.26
- go-cmd v0.1.3 → v0.2.0
- gRPC v1.78.0 → v1.79.3
- Kernel: CONFIG_USB_UHCI_HCD enabled on amd64, AMD GPU peer-to-peer DMA enabled

**Bug fixes (relevant to this cluster):**
- **Fix: panic in hardware.SystemInfoController** — prevents a potential panic during hardware info collection. Relevant to all nodes.
- **Fix: accept image cache volume encryption config** — fixes volume encryption config handling for image cache.
- **Fix: prevent stale discovered volumes reads** — improves volume discovery reliability. Relevant to DRBD/LINSTOR nodes.
- **Fix: stop pulling wrong platform for images** — ensures correct platform architecture for container images.
- **Fix: validate missing apiVersion in config document decoder** — better config validation.
- **Fix: dmesg timestamps** — corrects boot time calculation for kernel message timestamps.

**Bug fixes (not relevant to this cluster):**
- Multiple OpenNebula driver improvements (IPv6, aliases, DNS, routes, hostname parsing) — this cluster does not use OpenNebula.

**Breaking changes:** None.

**Deprecations:** None.

**Config schema changes:** None.

**Extension changes:** None — schematics remain compatible.

## Migration Plan

### Cluster-Specific Findings

1. **No coupled changes required.** This is a pure Talos patch bump. Kubernetes version, Cilium version, and schematics do not change.
2. **Schematics do not need regeneration.** No boot parameter or extension changes between v1.12.5 and v1.12.6. Existing schematic IDs remain valid — Image Factory serves the new Talos version with the same schematic ID.
3. **extraManifests URLs unchanged.** The `controlplane.yaml` cache-busting `?v=1.19.1-4` stays the same since Cilium is not being bumped.
4. **No config generation changes needed.** Only `TALOS_VERSION` changes in `versions.mk`, which triggers automatic config regeneration via the `VERSION_STAMP` mechanism.
5. **DRBD/LINSTOR consideration.** The "prevent stale discovered volumes reads" fix may improve volume discovery reliability. Standard pre-upgrade drain precautions apply.
6. **GPU node (node-gpu-01).** No NVIDIA extension changes. GPU schematic ID stays the same.
7. **Pi node (node-pi-01).** No overlay or Pi-specific changes. Pi schematic ID stays the same.

### Execution Plan

#### Phase 0: Preflight

```bash
# Verify all nodes are Ready and running v1.12.5
kubectl get nodes -o wide

# Verify etcd health
talosctl -n 192.168.2.61 -e 192.168.2.61 etcd members

# Verify cluster health
talosctl -n 192.168.2.61 -e 192.168.2.61 health \
    --control-plane-nodes 192.168.2.61,192.168.2.62,192.168.2.63

# Verify Cilium health
kubectl -n kube-system get pods -l k8s-app=cilium

# Verify LINSTOR node health
kubectl linstor node list

# Verify DRBD resource health (all UpToDate)
kubectl linstor resource list

# Verify no pods in bad state
kubectl get pods -A | grep -v Running | grep -v Completed
```

#### Phase 1: Repo Changes

1. Update `talos/versions.mk`:
   ```
   TALOS_VERSION := v1.12.6
   ```
   (Kubernetes and Cilium versions stay unchanged.)

2. Generate configs:
   ```bash
   make -C talos gen-configs
   ```

3. Validate generated configs:
   ```bash
   make -C talos validate-generated
   ```

4. Dry-run against all nodes to confirm no unexpected diff:
   ```bash
   make -C talos dry-run-all
   ```

5. Commit and push:
   ```bash
   git add talos/versions.mk
   git commit -m "chore(talos): bump Talos to v1.12.6"
   git push
   ```

#### Phase 2: Control Plane Upgrade (sequential, one at a time)

**Order:** node-01 → node-02 → node-03

For each control plane node:

```bash
# Drain DRBD volumes (control planes run DRBD in this cluster)
kubectl drain node-XX --delete-emptydir-data --ignore-daemonsets --timeout=120s

# Upgrade (apply-config + talosctl upgrade)
make -C talos upgrade-node-XX

# Wait for node to rejoin and become Ready
kubectl get nodes -w

# Verify node version
kubectl get node node-XX -o wide  # should show Talos (v1.12.6), kernel 6.18.18

# Verify etcd health (all 3 members present, no learners)
talosctl -n 192.168.2.61 -e 192.168.2.61 etcd members

# Cluster health gate (must pass before proceeding)
talosctl -n 192.168.2.61 -e 192.168.2.61 health \
    --control-plane-nodes 192.168.2.61,192.168.2.62,192.168.2.63

# Uncordon
kubectl uncordon node-XX

# Verify Cilium agent running on upgraded node
kubectl -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName=node-XX
```

Replace `node-XX` and IPs accordingly:
- node-01: 192.168.2.61
- node-02: 192.168.2.62
- node-03: 192.168.2.63

#### Phase 3: Worker Upgrade (sequential, one at a time)

**Order:** node-04 → node-05 → node-06 → node-gpu-01 → node-pi-01

For each worker node:

```bash
# Drain DRBD volumes and workloads
kubectl drain node-XX --delete-emptydir-data --ignore-daemonsets --timeout=120s

# Upgrade
make -C talos upgrade-node-XX

# Wait for node Ready
kubectl get nodes -w

# Verify node version
kubectl get node node-XX -o wide  # should show Talos (v1.12.6), kernel 6.18.18

# Verify LINSTOR satellite reconnected
kubectl linstor node list

# Uncordon
kubectl uncordon node-XX

# Verify Cilium agent running
kubectl -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName=node-XX
```

**GPU node additional check (node-gpu-01):**
```bash
# Verify NVIDIA driver loaded
talosctl -n 192.168.2.67 -e 192.168.2.67 dmesg | grep -i nvidia
kubectl get node node-gpu-01 -o jsonpath='{.status.allocatable.nvidia\.com/gpu}'
```

#### Phase 4: Post-Upgrade Validation

```bash
# All nodes on v1.12.6
kubectl get nodes -o wide

# Full cluster health
talosctl -n 192.168.2.61 -e 192.168.2.61 health \
    --control-plane-nodes 192.168.2.61,192.168.2.62,192.168.2.63

# Cilium status
kubectl -n kube-system get pods -l k8s-app=cilium

# LINSTOR/DRBD health
kubectl linstor node list
kubectl linstor resource list

# ArgoCD applications healthy
kubectl -n argocd get applications

# No degraded pods
kubectl get pods -A | grep -v Running | grep -v Completed
```

### Validation Plan

| Check | Expected Result | When |
|-------|----------------|------|
| `kubectl get nodes -o wide` | All nodes `Ready`, OS-IMAGE `Talos (v1.12.6)`, kernel `6.18.18-talos` | After each node |
| `talosctl etcd members` | 3 members, no learners | After each CP node |
| `talosctl health` | All checks pass | After each CP node, after all nodes |
| `kubectl linstor node list` | All satellites `Online` | After each DRBD node |
| `kubectl linstor resource list` | All resources `UpToDate` | After each DRBD node |
| Cilium agent pod | `Running 1/1` on each node | After each node |
| GPU allocatable | `nvidia.com/gpu: 1` on node-gpu-01 | After node-gpu-01 |
| ArgoCD apps | All `Synced` / `Healthy` | After all nodes |

## Rollback and Recovery

**Talos downgrades are not officially supported.** If a node fails to boot on v1.12.6:

1. **Node fails to upgrade / stuck rebooting:**
   - Check `talosctl -n <ip> -e <ip> dmesg` for boot errors
   - The node still has the previous OS image partition; Talos will fall back if the new image fails to boot
   - If completely unresponsive: physical power cycle, then `talosctl reset --system-labels-to-wipe EPHEMERAL --reboot --graceful=false` as last resort for CP nodes

2. **DRBD node stuck in "shutting down":**
   - Physical power cycle required (D-state processes on DRBD volumes)
   - This is why we drain before upgrading

3. **Etcd member fails to rejoin:**
   ```bash
   talosctl -n <ip> -e <ip> reset --system-labels-to-wipe EPHEMERAL --reboot --graceful=false
   ```
   Node will rejoin as learner, auto-promoted in ~1-2 minutes.

4. **Stop conditions (halt further upgrades):**
   - Etcd quorum lost (fewer than 2 healthy members)
   - More than 1 node fails to rejoin cluster
   - DRBD volumes degraded with no healthy replica
   - Cilium agents not converging after node reboot

5. **Preserving pre-upgrade state:**
   - Repo pin `TALOS_VERSION := v1.12.5` can be restored via `git revert`
   - Schematic IDs are unchanged and remain valid for both versions
   - Already-upgraded nodes remain functional on v1.12.6 even if remaining nodes stay on v1.12.5 (same-minor mixed versions are tolerated)

## Risks and Open Questions

### Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| DRBD node stuck during reboot | Medium | Pre-drain with `kubectl drain --timeout=120s` before each upgrade |
| Kernel regression (6.18.15 → 6.18.18) | Low | Three patch releases; monitor dmesg post-upgrade for errors |
| hardware.SystemInfoController panic on current version | Low (fix) | v1.12.6 fixes this — upgrade improves stability |

### Open Questions

None. This is a straightforward patch release with no breaking changes, no config schema changes, and no extension changes.

## Self-Review

**Checked:**
- [x] Single intermediate release (v1.12.6) — only version between v1.12.5 and v1.12.6
- [x] v1.12.6 is a stable release (not RC or beta), published 2026-03-19
- [x] Live cluster version (v1.12.5) matches repo pin — no drift
- [x] Kubernetes v1.35.0 remains supported by Talos v1.12.x
- [x] No Cilium version coupling — extraManifests URL unchanged
- [x] No schematic/extension changes required
- [x] No config schema or deprecated field changes
- [x] Upgrade commands align with repo Makefile targets
- [x] No forbidden practices from CLAUDE.md (no `kubectl apply` of managed resources, no SecureBoot, etc.)
- [x] DRBD drain precaution included for all nodes
- [x] All release notes read and mapped to cluster-specific impact
- [x] Rollback limitations documented honestly (downgrade not supported)

**Uncertain:**
- Nothing significant. This is a minimal patch release.

**Assessment:** Plan is safe to execute as written. No blockers identified.
