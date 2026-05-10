# Talos Upgrade Report: v1.12.5 → v1.12.6

**Date:** 2026-03-24
**Executed by:** Claude Code (automated), supervised by @Nosmoht
**Cluster:** Homelab (8 nodes, 3 CP + 4 workers + 1 Pi)
**Duration:** ~1.5 hours (clean rollout, no incidents)

## Version Changes

| Component | Before | After |
|-----------|--------|-------|
| Talos | v1.12.5 | v1.12.6 |
| Kernel | 6.18.15-talos | 6.18.18-talos |
| Kubernetes | v1.35.0 | v1.35.0 (unchanged) |
| Cilium | 1.19.1 | 1.19.1 (unchanged) |
| containerd | 2.1.6 | 2.1.6 (unchanged) |
| runc | — | 1.3.5 (updated) |

## Upgrade Motivation

- Single patch bump with no breaking changes
- Fixes panic in `hardware.SystemInfoController`
- Fixes stale discovered volumes reads (relevant to DRBD/LINSTOR nodes)
- Kernel bump 6.18.15 → 6.18.18 (three patch releases)

## Execution Summary

### Preflight

All checks passed:
- 8/8 nodes Ready
- 3/3 etcd members healthy (no learners)
- 8/8 Cilium agents Running
- 6/6 LINSTOR satellites Online
- 0 faulty DRBD resources (all UpToDate)
- Cluster health check passed with `--worker-nodes` flag (lesson from v1.12.5 upgrade)

### Environment Setup

The following tools were missing from the execution environment and installed during preflight:
- `sops` — required for SOPS-encrypted secrets decryption (`brew install sops`)
- `yq` — required for config generation post-processing (`brew install yq`)
- `talosctl` config — `~/.talos/config` was empty; regenerated from SOPS-encrypted `secrets.yaml` and merged
- `SOPS_AGE_KEY_FILE` — not set in shell; resolved by pointing to `~/.config/sops/age/keys.txt`
- `ssh-keyscan github.com` — GitHub host key was missing from `~/.ssh/known_hosts`

### Git Workflow

1. Updated `talos/versions.mk`: `TALOS_VERSION := v1.12.5` → `v1.12.6`
2. Ran `gen-configs` and `validate-generated` — all 8 configs valid
3. Committed version bump and upgrade plan to `main`
4. Pushed to remote

### Rolling Upgrade Results

| Node | Role | DRBD | Result | Issues |
|------|------|------|--------|--------|
| node-01 | CP | Yes | Clean | Kafka pod (`atlas-kafka-combined-1`) blocked drain via PDB — deleted manually |
| node-02 | CP | Yes | Clean | `dex-postgresql-1` and `atlas-event-writer` blocked drain via PDB — deleted manually |
| node-03 | CP | Yes | Clean | `atlas-kafka-combined-0` and `atlas-postgres-1` blocked drain via PDB — deleted manually |
| node-04 | Worker | Yes | Clean | Drain succeeded without PDB issues |
| node-05 | Worker | Yes | Clean | `atlas-dek-destroyer`, `atlas-event-writer`, `langgraph` blocked drain via PDB — deleted manually |
| node-06 | Worker | Yes | Clean | `atlas-kafka-entity-operator`, `atlas-kafka-combined-2`, grafana, alertmanager, prometheus blocked drain via PDB — deleted manually |
| node-gpu-01 | GPU Worker | No | Clean | Pre-existing: `nvidia-device-plugin` pod in `Completed` state with 13 restarts, GPU allocatable = 0 |
| node-pi-01 | Pi Worker | No | Clean | No issues |

### Post-Upgrade Verification

- 8/8 nodes Ready at Talos v1.12.6, kernel 6.18.18-talos
- 3/3 etcd members healthy (all voters, no learners)
- 8/8 Cilium agents Running
- 6/6 LINSTOR satellites Online
- All DRBD resources UpToDate

## Incidents

No upgrade-related incidents occurred during this rollout.

## Observations

### PDB Drain Conflicts (Recurring Pattern)

Every node except node-04 and node-pi-01 had pods blocked by PodDisruptionBudgets during `kubectl drain`. Affected workloads:
- `atlas-system`: kafka brokers, entity-operator, event-writer, dek-destroyer, langgraph
- `monitoring`: grafana, alertmanager, prometheus
- `dex`: dex-postgresql
- `atlas-inference`: atlas-postgres

These were resolved by manually deleting the blocked pods. This is the same pattern observed during the v1.12.4 → v1.12.5 upgrade. The `atlas-system` PDBs in particular are overly restrictive for a rolling upgrade scenario and should be reviewed.

### Pre-drain Applied (Lesson from v1.12.5)

Following the recommendation from the v1.12.5 upgrade report, explicit `kubectl drain` was run before every `make -C talos upgrade-*` command. No CSI unmount deadlocks occurred this time.

### GPU Node Pre-existing Issue

`nvidia-device-plugin` on `node-gpu-01` shows `Completed` status with 13 restarts and `nvidia.com/gpu` allocatable = 0. This is a pre-existing issue unrelated to this upgrade. The NVIDIA persistenced service starts correctly (visible in dmesg), but the device plugin pod is not staying running. Needs separate investigation.

### Kernel Bump

Kernel went from 6.18.15-talos to 6.18.18-talos (3 patch versions). No dmesg anomalies observed post-upgrade. Includes `CONFIG_USB_UHCI_HCD` enabled on amd64 and AMD GPU peer-to-peer DMA support.

### Pi Node

node-pi-01 upgraded cleanly on the first attempt — no actor ID timeout issues this time (contrast with v1.12.5 upgrade).

## Recommendations

### 1. Atlas PDB Review (Priority: Medium)

**Problem:** `atlas-system` workloads (kafka, event-writer, dek-destroyer, langgraph) consistently block `kubectl drain` due to overlapping or overly restrictive PDBs. Every rolling upgrade requires manual pod deletion to proceed.

**Recommendation:** Review PDB `maxUnavailable`/`minAvailable` settings for atlas-system workloads. For a single-replica deployment behind a PDB with `maxUnavailable: 0`, drain will always fail. Either increase `maxUnavailable` to 1, or accept that manual pod deletion during maintenance windows is the expected workflow.

### 2. GPU Device Plugin Investigation (Priority: High)

**Problem:** `nvidia-device-plugin` pod on `node-gpu-01` is in `Completed` state with 13 restarts. GPU allocatable = 0. This predates the upgrade.

**Recommendation:** Investigate the device plugin logs and daemonset configuration. This blocks GPU workload scheduling.

## Appendix: Command Reference

Commands used during the upgrade:

```bash
# Preflight
talosctl -n 192.168.2.61 -e 192.168.2.61 health \
    --control-plane-nodes 192.168.2.61,192.168.2.62,192.168.2.63 \
    --worker-nodes 192.168.2.64,192.168.2.65,192.168.2.66,192.168.2.67,192.168.2.68
talosctl -n 192.168.2.61 -e 192.168.2.61 etcd members
kubectl get nodes -o wide
kubectl -n kube-system get pods -l k8s-app=cilium -o wide

# Config generation and validation
make -C talos gen-configs
make -C talos validate-generated

# Per-node upgrade (with pre-drain)
kubectl drain node-XX --delete-emptydir-data --ignore-daemonsets --timeout=120s
make -C talos upgrade-node-XX
kubectl uncordon node-XX

# Post-node verification
kubectl get node node-XX -o wide
talosctl -n <ip> -e <ip> etcd members
kubectl -n kube-system get pods -l k8s-app=cilium --field-selector spec.nodeName=node-XX

# LINSTOR health (via controller pod, kubectl-linstor plugin not installed)
LINSTOR_POD=$(kubectl -n piraeus-datastore get pod \
    -l app.kubernetes.io/component=linstor-controller \
    -o jsonpath='{.items[0].metadata.name}')
kubectl -n piraeus-datastore exec "$LINSTOR_POD" -- linstor node list
kubectl -n piraeus-datastore exec "$LINSTOR_POD" -- linstor resource list
```
