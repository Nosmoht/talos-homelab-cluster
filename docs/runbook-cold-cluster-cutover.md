# Runbook: Full-Cluster Cold Cutover

Prescriptive runbook for a planned full-cluster shutdown used for
disruptive hardware operations (switch swap, rack move, NIC replacement
on multiple nodes, etc). Captures five gotchas that surfaced during the
Netgear → SG3428 cutover on 2026-04-16 and are not obvious from Talos or
ArgoCD documentation alone.

Scope: this cluster's shape. Not a general-purpose ops doc.

## 1. Drain order — DRBD consumers first, storage peers last

**Rule.** Sequence the shutdown so that every node hosting a DRBD CSI
consumer pod is drained before the nodes that hold the DRBD replica
peers for those volumes. The last node to shut down must hold zero
`InUse` DRBD replicas.

**Why.** Talos will attempt a clean umount of every CSI volume as part
of its shutdown sequence. If the DRBD peer satellites are already gone
at that point, the umount blocks indefinitely (the volume can't cleanly
detach), and the node gets stuck in `unmountPodMounts` with a live
kernel. Only a hard-power-off or `talosctl reboot --mode force` breaks
it.

**How to apply.** Before shutting down each node, run `kubectl linstor
resource list -p` and confirm that no `InUse` replica is on the
next-to-shutdown node; migrate any stray consumer first. For a
CP-last-shutdown order, make sure no platform-service pod that mounts
DRBD has been scheduled onto a CP (see §4 for the NVMe-label trap that
causes this silently).

## 2. `talosctl shutdown` umount-hang escape hatch

**Rule.** If `talosctl shutdown` stalls for more than about two minutes
in the umount phase, escalate out of it — do not wait. Preferred escape
hatch: `talosctl reboot --mode force` (skips graceful teardown
entirely, then shutdown the fresh kernel cleanly). If physical access is
available, a hard-power-off is equivalent and faster.

**Why.** `talosctl shutdown --force` only bypasses the cordon/drain
step. The umount phase still runs and will deadlock if a CSI consumer
can't release the mount. There is deliberately no flag equivalent to
`reboot --mode force` on the shutdown command; the only way to bypass
the graceful teardown for a shutdown is to reboot-force first and then
shutdown a freshly-booted kernel that has no hanging mounts.

**How to apply.** Pull `talosctl dmesg -n <ip>` on the stuck node;
confirm the last log is a pending `unmountPodMounts` line for a CSI
PVC. Then run `talosctl reboot --mode force -n <ip> -e <ip>`. After the
node reboots into a fresh kernel, run `talosctl shutdown --force`
again — it will complete in seconds. In practice during a cold cutover,
a physical power-off yields the same clean boot and takes 5 seconds.

## 3. Drain-only is sufficient — no ArgoCD `syncPolicy` quiesce

**Rule.** For a full-cluster cold cutover, use drain alone. Do not
commit a sweeping `syncPolicy: {}` change across ArgoCD Application
manifests just to quiesce selfHeal during the shutdown.

**Why.** Drain evicts pods; it does not change `Deployment.replicas` in
the live cluster state, and git stays untouched. ArgoCD selfHeal only
reconciles when live state drifts from git-desired state; when both
agree on "replicas = N" even if all the pod instances are Pending or
Terminating, selfHeal does nothing. Post-reboot, ArgoCD restarts,
reads git, sees the cluster reconciling back toward that same N, and
waits it out. No manual `syncPolicy` revert is needed afterwards.

**How to apply.** Skip the quiesce step. Drain nodes in the order
dictated by §1. After the cluster boots back up, verify health with
`kubectl get apps -n argocd` — expect every app to reach `Synced` and
`Healthy` within a reconcile loop. Only uncordon nodes manually if they
come back `SchedulingDisabled` (see §5).

## 4. NVMe NFD label is not a Worker-only selector

**Rule.** Do not rely on `feature.node.kubernetes.io/storage-nvme.present=true`
alone to pin a workload to worker nodes. Pair it with a
control-plane anti-affinity (for example
`node-role.kubernetes.io/control-plane: DoesNotExist` under
`matchExpressions`).

**Why.** This cluster's control-plane nodes also have NVMe drives and
therefore carry the same NFD label. A nodeSelector that checks only the
NVMe label is satisfied by any of the three control-plane nodes too. If
the scheduler starts evaluating placements while only the control
planes have come back online — which is the normal order at the end of
a cold cutover — a workload intended for workers can land on a control
plane and stay there.

**How to apply.** For any Helm chart or manifest that uses the NVMe
label, add a second rule that excludes control-plane nodes. Example:

```yaml
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: feature.node.kubernetes.io/storage-nvme.present
              operator: In
              values: ["true"]
            - key: node-role.kubernetes.io/control-plane
              operator: DoesNotExist
```

## 5. Hook interaction — prefer `talosctl shutdown` over `kubectl drain`

**Rule.** During a cold cutover, use `talosctl shutdown` (which does
its own internal cordon/drain) rather than a separate `kubectl drain`
followed by `talosctl shutdown --force`. Reserve `kubectl drain` for
single-node maintenance.

**Why.** The `.claude/hooks/pre-drain-check.sh` hook intercepts
`kubectl drain` and blocks when it sees any LINSTOR satellite `OFFLINE`
— correct behaviour for single-node ops, but wrong for a deliberate
full-cluster shutdown where satellites go offline by design as the
sequence progresses. `talosctl shutdown` does not trigger this hook, so
it keeps the safety check for single-node ops intact while letting the
cold cutover proceed. The hook also supports an `ALLOWED_OFFLINE`
allowlist for legitimate permacordon cases (for example a permanently
offline helper node).

**How to apply.** For each node except CP-01, run `talosctl shutdown -n
<ip> -e <ip>`. For CP-01 (the last CP), use `--force` to skip the
internal self-drain step, since there are no peers left to evict to.
Consistent with the `talos-mcp-first` guidance in AGENTS.md.

---

## Verification after boot

After the cluster comes back, confirm:

- `kubectl get nodes` → every expected node `Ready` within ten minutes.
- `mcp__talos__talos_etcd` → 3/3 members, all voter, all up.
- `kubectl linstor node list` → every storage node `Online`.
- `kubectl linstor resource list -p` → every resource `UpToDate`, no
  `SyncTarget`, no `Inconsistent`.
- `kubectl get pods -A` → no `CrashLoopBackOff` (pre-existing failures
  are fine, compare against the pre-cutover snapshot from §0 of the
  driving plan).
- Spot-check that workloads intended for worker nodes (see §4) are not
  sitting on control planes.

Uncordon any node still on `SchedulingDisabled` only if its prior drain
was issued as `kubectl drain`; nodes that were taken down via
`talosctl shutdown` without `--force` usually come up uncordoned.
