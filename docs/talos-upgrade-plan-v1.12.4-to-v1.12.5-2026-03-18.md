---
plan_source: plan-talos-upgrade
from_version: v1.12.4
to_version: v1.12.5
generated_at: 2026-03-18
status: approved
approved_by: @Nosmoht
approved_at: 2026-03-18
---

# Talos Upgrade Plan: v1.12.4 → v1.12.5

## Resolved Versions

| Component | Current | Target | Notes |
|-----------|---------|--------|-------|
| Talos | v1.12.4 | v1.12.5 | Patch release, same minor |
| Linux kernel | 6.18.9 | 6.18.15 | Bundled with Talos |
| Kubernetes (repo pin) | v1.35.0 | v1.35.0 | **No change** — repo keeps v1.35.0 |
| Kubernetes (Talos bundled) | v1.35.0 | v1.35.2 | Talos ships newer K8s, but repo pin governs |
| etcd | 3.6.x | 3.6.8 | Updated in Talos v1.12.5 |
| Cilium | 1.19.1 | 1.19.1 | **No change** |
| Go | 1.25.7 | 1.25.8 | Build toolchain only |
| containerd | 2.1.6 | 2.1.6 | No change expected |

**How versions were determined:**
- `from-version`: Live cluster query (`talosctl version` on node-01) and `talos/versions.mk` both show v1.12.4 — no drift.
- `to-version`: GitHub releases API, filtered for non-prerelease/non-draft, semver sorted. v1.12.5 is the highest stable release (published 2026-03-09).

**Kubernetes compatibility:** Talos v1.12 supports K8s 1.30–1.35. The repo-pinned v1.35.0 remains fully supported.

## Reviewed Releases

### v1.12.5 (2026-03-09)

**Source:** https://github.com/siderolabs/talos/releases/tag/v1.12.5

**Component updates:**
- Linux kernel 6.18.9 → 6.18.15 (six kernel patch releases)
- etcd 3.6.x → 3.6.8
- Go 1.25.7 → 1.25.8

**Bug fixes (relevant to this cluster):**
- **Cilium BPF verifier kernel patch** — kernel-level fix for Cilium BPF program rejection. Directly relevant since this cluster runs Cilium as CNI.
- Fix: correctly calculate end ranges for nftables sets
- Fix: use correct DHCP option for unicast DHCP renewal
- Fix: ignore image digest when doing `upgrade-k8s` — avoids issues when image references include digests
- Fix: patch with delete for LinkConfigs
- Fix: stop Kubernetes client from dynamically reloading certs
- Fix: hold user volumes root mountpoint
- Fix: handle raw encryption keys with `\n` properly
- Fix: remove stale endpoints
- Fix: read multi-doc machine config with newer talosctl

**Firmware updates:**
- Linux firmware updated to 20260221 (may include i915, realtek, nvidia firmware updates relevant to this cluster's schematics)

**Kernel config changes:**
- Enable MLX5 Scalable Functions and TC offload (not used by this cluster but harmless)

**Breaking changes:** None.
**Deprecations:** None.
**Migration requirements:** None.
**Config schema changes:** None.

## Migration Plan

### Cluster-Specific Findings

1. **No config schema or extension changes** — patch release within same minor; schematics are unchanged.
2. **Schematic IDs remain valid** — extensions (drbd, gvisor, i915, intel-ucode, nvme-cli, nvidia, realtek-firmware, rpi_generic overlay) are unchanged between v1.12.4 and v1.12.5. The same schematic IDs work; only `TALOS_VERSION` in the install image URL changes.
3. **No `make schematics` needed** — schematics are version-independent; the factory resolves the correct image for the requested Talos version using the existing schematic ID.
4. **Kubernetes version stays at v1.35.0** — no `upgrade-k8s` step needed. The repo pin is not changing.
5. **Cilium not coupled** — no Cilium version bump, no `extraManifests` URL changes, no bootstrap manifest re-render needed.
6. **Cilium BPF kernel fix is beneficial** — the kernel patch for BPF verifier rejection is a proactive stability improvement for Cilium on this cluster.
7. **Pi node (node-pi-01)** — uses separate schematic with `rpi_generic` overlay. Same schematic ID applies; upgrade follows same process.
8. **DRBD/LINSTOR** — storage nodes run DRBD extension. Node reboots during upgrade require standard DRBD precautions (verify no single-replica volumes on the node being upgraded).

### Breaking Changes and Required Migrations

**None.** This is a patch release with no breaking changes, no deprecated fields, and no config schema modifications.

### Execution Plan

#### Phase 0: Preflight (before any node changes)

```bash
# 1. Verify cluster health
talosctl -n 192.168.2.61 -e 192.168.2.61 health \
    --control-plane-nodes 192.168.2.61,192.168.2.62,192.168.2.63

# 2. Verify all nodes are Ready
kubectl get nodes -o wide

# 3. Verify etcd health
talosctl -n 192.168.2.61 -e 192.168.2.61 etcd members

# 4. Verify Cilium health
kubectl -n kube-system get pods -l k8s-app=cilium

# 5. Verify LINSTOR health — no degraded resources
kubectl linstor node list
kubectl linstor resource list --faulty

# 6. Verify no single-replica DRBD volumes
kubectl linstor resource list | grep -v "UpToDate"
```

#### Phase 1: Repo changes

```bash
# 1. Update TALOS_VERSION in versions.mk
#    Change: TALOS_VERSION := v1.12.4 → TALOS_VERSION := v1.12.5
#    KUBERNETES_VERSION and CILIUM_VERSION remain unchanged

# 2. Regenerate configs
make -C talos gen-configs

# 3. Validate generated configs
make -C talos validate-generated

# 4. Dry-run against all nodes to verify no unexpected diff
make -C talos dry-run-all

# 5. Commit and push
git add talos/versions.mk
git commit -m "chore(talos): bump Talos to v1.12.5"
git push
```

#### Phase 2: Control plane nodes (one at a time)

**Order:** node-01 → node-02 → node-03

For each control plane node:

```bash
# Upgrade node (applies config + upgrades install image + reboots)
make -C talos upgrade-node-01

# Wait for node to come back Ready
kubectl get nodes -w

# Verify Talos version on upgraded node
talosctl -n 192.168.2.61 -e 192.168.2.61 version

# Verify etcd health (quorum intact)
talosctl -n 192.168.2.61 -e 192.168.2.61 etcd members

# Verify cluster health before next node
talosctl -n 192.168.2.61 -e 192.168.2.61 health \
    --control-plane-nodes 192.168.2.61,192.168.2.62,192.168.2.63

# Verify Cilium agent running on upgraded node
kubectl -n kube-system get pods -l k8s-app=cilium -o wide | grep node-01
```

Repeat for node-02 (192.168.2.62) and node-03 (192.168.2.63).

**Stop condition:** If etcd loses quorum or health check fails, do NOT proceed to the next control plane node.

#### Phase 3: Worker nodes

**Order:** node-04 → node-05 → node-06

For each worker node:

```bash
# Check DRBD replicas before upgrade
kubectl linstor resource list | grep node-04

# Upgrade node
make -C talos upgrade-node-04

# Wait for node Ready
kubectl get nodes -w

# Verify LINSTOR satellite reconnects
kubectl linstor node list

# Verify Cilium agent
kubectl -n kube-system get pods -l k8s-app=cilium -o wide | grep node-04
```

Repeat for node-05 and node-06.

#### Phase 4: GPU worker

```bash
# Upgrade GPU node
make -C talos upgrade-node-gpu-01

# Wait for Ready
kubectl get nodes -w

# Verify NVIDIA driver loaded
talosctl -n 192.168.2.67 -e 192.168.2.67 dmesg | grep -i nvidia

# Verify GPU node taint still present
kubectl describe node node-gpu-01 | grep Taints
```

#### Phase 5: Pi worker

```bash
# Upgrade Pi node
make -C talos upgrade-node-pi-01

# Wait for Ready
kubectl get nodes -w

# Verify Pi node taint still present
kubectl describe node node-pi-01 | grep Taints
```

#### Phase 6: Post-upgrade verification

```bash
# Full cluster health
talosctl -n 192.168.2.61 -e 192.168.2.61 health \
    --control-plane-nodes 192.168.2.61,192.168.2.62,192.168.2.63

# All nodes at v1.12.5
kubectl get nodes -o wide

# All Cilium agents healthy
kubectl -n kube-system get pods -l k8s-app=cilium

# LINSTOR fully healthy
kubectl linstor node list
kubectl linstor resource list --faulty

# ArgoCD apps healthy
kubectl -n argocd get applications

# Verify kernel version updated (should show 6.18.15)
talosctl -n 192.168.2.61 -e 192.168.2.61 version
```

### Validation Plan

| Check | When | Expected |
|-------|------|----------|
| `talosctl version` | After each node | Tag: v1.12.5 |
| `kubectl get nodes` | After each node | STATUS: Ready, OS-IMAGE: Talos (v1.12.5) |
| `talosctl etcd members` | After each CP node | 3 members, all healthy |
| `talosctl health` | After each CP node | All checks pass |
| Cilium pods | After each node | 1/1 Running on upgraded node |
| `kubectl linstor node list` | After each worker | Satellite Online |
| `kubectl linstor resource list --faulty` | After each worker | No faulty resources |
| NVIDIA dmesg | After GPU node | nvidia modules loaded |
| Node taints | After GPU and Pi nodes | Taints preserved |

### Rollback and Recovery

**Downgrade support:** Talos patch-level downgrades within the same minor are generally supported by re-running `make -C talos upgrade-<node>` with the previous `TALOS_VERSION` pin. However, etcd data format changes (3.6.8) could make downgrade non-trivial if etcd compacts with new features.

**Pre-upgrade safety:**
- The repo commit with `TALOS_VERSION := v1.12.4` can be restored by reverting the version bump commit.
- Schematic IDs are unchanged and don't need rollback.

**Per-node recovery scenarios:**

| Scenario | Action |
|----------|--------|
| Node fails to boot after upgrade | Physical power cycle; if persistent, revert `versions.mk` and `make -C talos upgrade-<node>` with old version |
| Node stuck in "shutting down" (DRBD D-state) | Physical power cycle (documented known issue) |
| Etcd member doesn't rejoin | Wait 2-3 min for learner promotion; if stuck, `talosctl reset --system-labels-to-wipe EPHEMERAL --reboot --graceful=false` |
| Kubelet CSR pending | `kubectl get csr` then `kubectl certificate approve <name>` |
| Cilium agent CrashLoop after kernel update | Check dmesg for BPF verifier errors; the v1.12.5 kernel patch should fix these, not cause them |

**Stop conditions — halt the upgrade if:**
- Etcd quorum is lost (fewer than 2 healthy members)
- More than 1 node is NotReady simultaneously
- LINSTOR reports degraded resources that cannot self-heal
- Cilium agents fail to start on upgraded nodes

## Risks

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| DRBD node stuck on reboot | Low | Medium | Verify no single-replica volumes; drain if needed |
| etcd quorum loss during CP upgrade | Very Low | High | One CP node at a time; verify quorum after each |
| Kernel 6.18.15 regression | Very Low | Medium | Monitor dmesg post-upgrade; revert version if needed |
| Pi node ARM image issue | Low | Low | Pi node is last; cluster unaffected if it fails |
| NVIDIA driver incompatibility with kernel 6.18.15 | Low | Low | GPU node is second-to-last; verify nvidia modules in dmesg |

**Open questions:**
- None blocking. This is a straightforward patch release with no schema or extension changes.

## Self-Review

**What was checked:**
- Live cluster version confirmed on all 8 nodes (v1.12.4, uniform)
- Repo pin in `talos/versions.mk` matches live cluster (no drift)
- Target version v1.12.5 confirmed as latest stable via GitHub API (released 2026-03-09)
- Full release notes for v1.12.5 reviewed — 19 commits, all bug fixes and component updates
- No breaking changes, deprecations, or config schema changes
- Kubernetes v1.35.0 confirmed compatible with Talos v1.12 (support matrix: K8s 1.30–1.35)
- Schematic files reviewed — no extension changes needed between patch releases
- All three schematic types (standard, GPU, Pi) verified with existing IDs
- Upgrade commands align with repo Makefile targets
- Node ordering matches documented procedure (CP first, workers, GPU, Pi last)
- DRBD/LINSTOR precautions included
- No forbidden practices from CLAUDE.md used
- Cilium BPF kernel fix noted as beneficial for this cluster

**What was uncertain:**
- Whether etcd 3.6.8 introduces any format changes that would complicate rollback (unlikely for patch release, but not explicitly documented)
- Whether Linux firmware 20260221 includes specific fixes for i915 or realtek hardware in this cluster (beneficial if so, harmless if not)

**Assessment:** This plan is safe to execute as written. It is a low-risk, single patch bump within the same minor with no breaking changes. The Cilium BPF kernel fix makes this upgrade actively beneficial for cluster stability.
