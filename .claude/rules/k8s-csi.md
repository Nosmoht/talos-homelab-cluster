---
paths:
  - "kubernetes/**/storage-class*.yaml"
  - "kubernetes/**/storageclass*.yaml"
---

# Kubernetes CSI

## Scope

**Inclusion**: CSI-driver-agnostic patterns — CSI volume lifecycle, mount/unmount semantics, common failure modes that apply across drivers.

**Exclusion** (with named pointers):
- LINSTOR / Piraeus / DRBD-specific behaviour → `.claude/rules/linstor-storage-guardrails.md`
- Longhorn → its own rule file when first added
- ceph-csi → its own rule file when first added

## CSI Volume Unmount + Talos Upgrade Deadlock

Any CSI volume in D-state during `unmountPodMounts` deadlocks the Talos upgrade sequence. `talosctl reboot`, `talosctl upgrade --force`, and `talosctl reset` all fail with `locked` once a CSI mount enters kernel D-state — only physical power cycle recovers the node.

**Mitigation** (driver-agnostic): drain the node before any Talos lifecycle operation that touches a CSI-using node:
```bash
kubectl drain <node> --delete-emptydir-data --ignore-daemonsets --timeout=120s
```

The drain releases live mounts cleanly before they can wedge in D-state. Combine with driver-specific pre-checks where applicable.

**Driver-specific recovery**: see `.claude/rules/linstor-storage-guardrails.md` §Known Failure Modes for the DRBD-specific manifestation of this pattern (DRBD D-state deadlock + the `pre-drain-check.sh` hook flow). DRBD is the only CSI driver in this cluster today that triggers this in practice; if a second CSI driver is added, document its trigger conditions in this file.
