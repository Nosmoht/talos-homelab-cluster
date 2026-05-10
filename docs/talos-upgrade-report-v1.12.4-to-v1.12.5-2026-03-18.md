# Talos Upgrade Report: v1.12.4 → v1.12.5

**Date:** 2026-03-18
**Executed by:** Claude Code (automated), supervised by @Nosmoht
**Cluster:** Homelab (8 nodes, 3 CP + 4 workers + 1 Pi)
**Duration:** ~2.5 hours (including incident recovery)

## Version Changes

| Component | Before | After |
|-----------|--------|-------|
| Talos | v1.12.4 | v1.12.5 |
| Kernel | 6.18.9-talos | 6.18.15-talos |
| Kubernetes | v1.35.0 | v1.35.0 (unchanged) |
| Cilium | 1.19.1 | 1.19.1 (unchanged) |
| containerd | 2.1.6 | 2.1.6 (unchanged) |

## Upgrade Motivation

- Single patch bump with no breaking changes
- Includes Cilium BPF kernel fix — actively beneficial for cluster stability
- Reviewed by platform-reliability-reviewer (2 passes): LGTM, no blockers

## Execution Summary

### Preflight

All checks passed:
- 8/8 nodes Ready
- 3/3 etcd members healthy (no learners)
- 8/8 Cilium agents Running
- 6/6 LINSTOR satellites Online
- 0 faulty DRBD resources
- Cluster health check passed (etcd, apid, kubelet, boot sequence, diagnostics)

Note: `talosctl health` hung on node discovery because `--worker-nodes` was not specified. All critical sub-checks had already passed. This is cosmetic, not a blocker.

### Git Workflow

1. Stashed uncommitted changes on `feat/forgejo-on-pi`
2. Pruned 3 stale git worktrees that were blocking checkout of `main`
3. Created `chore/talos-v1.12.5` branch from `main`
4. Updated `talos/versions.mk`: `TALOS_VERSION := v1.12.4` → `v1.12.5`
5. Ran `gen-configs`, `validate-generated`, `dry-run-all` — all clean, diffs showed only install image version changes
6. Committed, pushed, created PR #22
7. PR merged by @Nosmoht, then checked out `main` with merged version before starting rolling upgrade

### Rolling Upgrade Results

| Node | Role | DRBD | Result | Duration | Issues |
|------|------|------|--------|----------|--------|
| node-01 | CP | Yes | Clean | ~5 min | DRBD resync ~2 min (2 resources at ~20%) |
| node-02 | CP | Yes | Clean | ~5 min | DRBD resync ~2 min |
| node-03 | CP | Yes | **Incident** | ~30 min | CSI unmount deadlock, required physical power cycle |
| node-04 | Worker | Yes | Clean | ~5 min | LINSTOR satellite reconnect took ~90s |
| node-05 | Worker | Yes | Clean | ~5 min | Clean |
| node-06 | Worker | Yes | Clean | ~5 min | Clean |
| node-gpu-01 | GPU Worker | No | Clean | ~3 min | NVIDIA persistenced started, correct taint verified |
| node-pi-01 | Pi Worker | No | Retry needed | ~8 min | First attempt timed out at "waiting for actor ID"; manual retry succeeded |

### Post-Upgrade Verification

- 8/8 nodes Ready at Talos v1.12.5
- 3/3 etcd members healthy
- 0 faulty DRBD resources
- ArgoCD: 22/24 apps Healthy/Synced, 2 Progressing/Synced (alloy, loki — pod restarts after node reboots, expected)
- node-02 had residual `SchedulingDisabled` status post-upgrade — resolved with `kubectl uncordon` (was already uncordoned but status was stale)

## Incidents

### Incident 1: node-03 CSI Unmount Deadlock (Critical)

**Timeline:**
1. `make -C talos upgrade-node-03` started normally
2. Drain completed, services stopped
3. Phase 5/13 (unmount): `unmountPodMounts` stuck trying to unmount `/var/lib/kubelet/pods/.../pvc-1c17d9ce.../mount` (a DRBD/CSI volume)
4. The `make` command exited with error (client-side timeout), but the upgrade sequence on the node held a lock
5. Node was in a degraded state: etcd Finished, kubelet Finished, cri Finished, but apid still Running
6. Retry with `talosctl upgrade` failed: `etcd member 9fe35453e97353a4 is not healthy`
7. Retry with `--force` failed: `upgrade failed: locked`
8. `talosctl reboot` failed: `reboot failed: locked`
9. **Physical power cycle required** — only resolution for lock held by stuck upgrade sequence

**Root Cause:** DRBD CSI volume unmount entered D-state (uninterruptible sleep), blocking the upgrade unmount phase. The upgrade sequence acquired a node-level lock before starting the unmount phase and never released it because the unmount never completed.

**Impact:**
- node-03 was down for ~15 minutes (from first upgrade attempt to power cycle completion)
- 2/3 etcd members remained healthy throughout — no quorum loss
- DRBD resources on other nodes showed "Connecting(node-03)" during downtime but no data loss
- After power cycle, node came back at v1.12.4 with all services healthy
- Second upgrade attempt succeeded cleanly (unmount phase passed without issue)

**Contributing Factors:**
- The specific PVC (`pvc-1c17d9ce`) was a Diskless replica on node-03 with InUse status — the pod using it may have had I/O in flight when the drain/stop sequence reached the unmount phase
- The upgrade drain phase completed before unmount, but stopping CRI/kubelet may not have fully released the FUSE/CSI mount before the unmount task attempted to force-unmount it

### Incident 2: node-pi-01 Actor ID Timeout (Minor)

**Timeline:**
1. `make -C talos upgrade-node-pi-01` started
2. Config applied successfully
3. `talosctl upgrade` hung at "waiting for actor ID" until the 10-minute timeout
4. Manual retry with 15-minute timeout succeeded immediately — the Pi processed the upgrade request

**Root Cause:** Likely a transient gRPC connection issue between the client and the Pi's apid. The Pi (ARM64 on USB storage) is the slowest node in the cluster. The first upgrade request was received by the node (visible in dmesg) but the actor ID response was lost or delayed past the client's polling window.

**Impact:** None — the node was still at v1.12.4 and Ready when the retry started. No services were interrupted.

## Observations

### DRBD Resync Timing
- Typical resync time after node reboot: 1-3 minutes
- Resync percentage at first check (~60-90s post-boot): ~20%
- No resync exceeded the 5-minute safety window defined in the plan
- LINSTOR satellite reconnection took 60-120s after node reboot (pod needs to be scheduled, pull image if evicted, start)

### Kernel Bump
- Kernel went from 6.18.9-talos to 6.18.15-talos (6 patch versions)
- This was not called out in the upgrade plan but is expected — Talos bundles its own kernel
- Includes the Cilium BPF fix that motivated this upgrade

### GPU Node
- Different installer image schemaId (expected — GPU extensions change the image factory hash)
- `ext-nvidia-persistenced` service started automatically during boot
- Cilium agent-not-ready taint cleared within 30 seconds
- Final taint correctly shows `nvidia.com/gpu=present:NoSchedule`

### Stale Worktrees
- 3 stale git worktrees were blocking checkout of `main`
- `git worktree prune` resolved this immediately
- These were left over from previous Claude Code agent sessions that used isolation worktrees

## Recommendations for Skill/Process Improvement

### 1. CSI Volume Pre-drain (Priority: High)

**Problem:** DRBD CSI volumes in D-state during unmount can deadlock the entire upgrade sequence with no programmatic recovery path.

**Recommendation:** Before initiating `talosctl upgrade`, add a pre-drain step that identifies CSI-mounted PVCs on the target node and ensures their pods are evicted and volumes detached *before* Talos starts its own drain/unmount sequence. This could be:
- `kubectl drain <node> --delete-emptydir-data --ignore-daemonsets --timeout=120s` as an explicit pre-step
- Or verify that no DRBD Diskless+InUse resources exist on the target node

**Note:** The upgrade plan stated "explicit drain not needed — `talosctl upgrade` does graceful reboot; drain only needed for network interface changes." This is true in the common case but does not account for CSI unmount deadlocks. The plan should be updated to include an explicit pre-drain as a safety measure for DRBD nodes.

### 2. Node-Level Lock Recovery (Priority: Medium)

**Problem:** When an upgrade sequence holds a lock and the triggering phase is stuck, there is no API-level recovery. Physical power cycle is the only option.

**Recommendation:** Document this in CLAUDE.md under Talos Operations gotchas: "Upgrade sequence lock stuck on CSI unmount: only fixable with physical power cycle. `talosctl reboot`, `talosctl upgrade --force`, and `talosctl reset` all fail with 'locked'."

### 3. Pi Upgrade Timeout (Priority: Low)

**Problem:** The default 10-minute timeout in the Makefile may not be sufficient for the Pi's slower hardware, especially when the gRPC connection is flaky.

**Recommendation:** Consider increasing the timeout for the Pi target in the Makefile, or add a retry loop to the `upgrade-node-pi-01` target.

### 4. Health Check Worker Nodes Flag (Priority: Low)

**Problem:** `talosctl health --control-plane-nodes` without `--worker-nodes` causes the check to hang on node discovery.

**Recommendation:** Always pass `--worker-nodes` to `talosctl health`, or use a wrapper that auto-discovers worker IPs. Add this to CLAUDE.md.

### 5. Post-Upgrade Uncordon Verification (Priority: Low)

**Problem:** node-02 retained `SchedulingDisabled` status after a successful upgrade. The `talosctl upgrade --wait` completion should have uncordoned, but the status was stale.

**Recommendation:** Add an explicit `kubectl uncordon <node>` to the post-upgrade verification checklist for each node, not just as a final cleanup step.

### 6. Upgrade Plan Template Updates (Priority: Medium)

Based on this execution, the `plan-talos-upgrade` skill should incorporate:
- Explicit pre-drain step for DRBD nodes (not relying solely on Talos's built-in drain)
- LINSTOR Diskless+InUse resource check before upgrade (not just `--faulty`)
- Actor ID timeout handling for slow nodes (Pi)
- Lock recovery documentation (physical power cycle as last resort)
- Post-node uncordon verification

## Appendix: Command Reference

Commands used during the upgrade that may be useful for future reference:

```bash
# Preflight
talosctl -n 192.168.2.61 -e 192.168.2.61 health --control-plane-nodes 192.168.2.61,192.168.2.62,192.168.2.63
kubectl linstor resource list --faulty

# Config generation and validation
make -C talos gen-configs
make -C talos validate-generated
make -C talos dry-run-all

# Per-node upgrade
make -C talos upgrade-node-XX

# Post-node verification
talosctl -n <ip> -e <ip> version
talosctl -n 192.168.2.61 -e 192.168.2.61 etcd members
kubectl linstor node list
kubectl linstor resource list --faulty
kubectl -n kube-system get pods -l k8s-app=cilium -o wide | grep node-XX

# Incident recovery
talosctl -n <ip> -e <ip> services          # Check service states
talosctl -n <ip> -e <ip> dmesg | grep -E "(unmount|upgrade|lock)"
# Physical power cycle required for stuck upgrade lock

# ArgoCD deep check
kubectl -n argocd get applications -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.health.status}{"\t"}{.status.sync.status}{"\n"}{end}'
```
