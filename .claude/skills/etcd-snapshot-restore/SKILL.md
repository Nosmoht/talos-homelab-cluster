---
name: etcd-snapshot-restore
description: Restore etcd from snapshot after quorum loss or full cluster failure. Covers member re-join and full bootstrap-from-snapshot paths.
argument-hint: "<snapshot-path> [--full-recovery]"
disable-model-invocation: true
allowed-tools:
  - Bash
  - Read
  - mcp__talos__talos_etcd
  - mcp__talos__talos_etcd_snapshot
  - mcp__talos__talos_health
  - mcp__talos__talos_get
---

# Etcd Snapshot Restore

## Environment Setup

Read `cluster.yaml` to load cluster-specific values (node IPs, kubeconfig path).
If the file is missing, tell the user: "Copy `cluster.yaml.example` to `cluster.yaml` and fill in your cluster details."

Control-plane IPs are typically `192.168.2.61` (node-01), `192.168.2.62` (node-02), `192.168.2.63` (node-03).

Use throughout this skill:
- `KUBECONFIG=<kubeconfig>` for all `kubectl` commands
- `-n <node-ip> -e <node-ip>` for all `talosctl` commands targeting a node

## Reference Files

Read before proceeding:
- `.claude/rules/talos-mcp-first.md` — MCP tool mapping, etcd restart restriction, node recovery patterns
- `docs/day2-operations.md` — cluster access, etcd member recovery steps

## Scope Guard — Identify Recovery Path First

**This skill covers two distinct recovery paths. Select one before proceeding:**

### Path A — Single Member Failure (quorum intact)

Symptoms: One CP node is offline or has diverged, but the other two members form quorum (3-node cluster → 2 healthy = quorum). No snapshot needed.

→ Jump to [Path A Workflow](#path-a-single-member-recovery).

### Path B — Full Cluster Recovery (quorum lost)

Symptoms: All CP nodes are unreachable, API server is not responding, or `talos_etcd(subcommand="status")` shows fewer than `(n/2)+1` members healthy.

→ Jump to [Path B Workflow](#path-b-full-recovery-from-snapshot).

---

## Path A — Single Member Recovery

### A1. Assess etcd state

```
talos_etcd(subcommand="members", nodes=["<healthy-cp-ip>"])
talos_etcd(subcommand="status", nodes=["<healthy-cp-ip>"])
# Fallback: talosctl etcd members -n <ip> -e <ip>
#           talosctl etcd status -n <ip> -e <ip>
```

Identify the failed member ID from the members list.

**Quorum Gate:** If fewer than 2 members show `started` on a 3-node cluster, **abort Path A** — this
is quorum-loss. Capture a fresh snapshot (if any node is reachable) and switch to Path B.

### A2. Remove the failed member

The `talos_etcd` MCP tool does not expose `remove-member` — use `talosctl` CLI:

```bash
talosctl etcd remove-member -n <healthy-cp-ip> -e <healthy-cp-ip> <member-id>
```

### A3. Reset the failed node (EPHEMERAL wipe only)

This clears the stale etcd data without wiping the installed OS.

**Confirmation gate:** Present to user before executing:
```
Path A — Member Reset: <node-name> (<ip>)
Action: talosctl reset --system-labels-to-wipe EPHEMERAL --reboot --graceful=false
Effect: Wipes EPHEMERAL partition. Node will reboot and rejoin etcd as a new learner.
Rollback: Not possible after reboot — ensure quorum is intact on remaining members first.
Proceed? (yes/no)
```

After confirmation:
```bash
talosctl reset --system-labels-to-wipe EPHEMERAL --reboot --graceful=false \
  -n <failed-node-ip> -e <failed-node-ip>
```

### A4. Wait for learner promotion

After reboot, etcd learner promotion is automatic (~1–2 min). Poll until member rejoins:

```
# Poll up to 12 × 10 s = 2 min
for i in $(seq 1 12); do
  talos_etcd(subcommand="members", nodes=["<healthy-cp-ip>"])
  # Check if recovered node appears as "started"
  sleep 10
done
```

### A5. Verify cluster health

```
talos_health(nodes=["<all-cp-ips>"])
talos_etcd(subcommand="status", nodes=["<healthy-cp-ip>"])
# Fallback: talosctl -n <ip> -e <ip> health --control-plane-nodes 192.168.2.61,192.168.2.62,192.168.2.63
```

All members must show `started`. Learner must be promoted to voter. If promotion does not happen within 2 min, escalate — do not force.

---

## Path B — Full Recovery From Snapshot

**Warning:** This procedure replaces all etcd data with the snapshot. Any writes after the snapshot was taken are permanently lost. Confirm with the user which snapshot to restore and acknowledge the data-loss window.

### B1. Verify the snapshot exists and is accessible

```bash
# Snapshot is a local file (taken previously via talos_etcd_snapshot or talosctl etcd snapshot)
ls -lh <snapshot-path>
```

If no recent snapshot exists: stop. A snapshot older than the last etcd compaction cannot be restored. Report state and halt.

### B2. Take a fresh snapshot if any node is still reachable

If at least one CP node is alive (even if degraded), capture a final snapshot first:

```
talos_etcd_snapshot(nodes=["<last-alive-cp-ip>"], path="/tmp/etcd-recovery-<date>.snapshot")
# Fallback: talosctl etcd snapshot /tmp/etcd-recovery-<date>.snapshot -n <ip> -e <ip>
```

### B3. Confirmation gate

Present before any destructive step:
```
Path B — Full etcd Recovery
Snapshot: <snapshot-path> (<size>, <mtime>)
Action: Bootstrap one CP node from snapshot. All other CP nodes will have EPHEMERAL wiped.
Data loss: All writes after <snapshot-mtime> are permanently lost.
Affected nodes: node-01, node-02, node-03
This is IRREVERSIBLE.
Proceed? (yes/no — type exactly "yes" to confirm)
```

### B3b. Snapshot sanity check (before wiping any node)

Verify the snapshot is readable **before** destroying any etcd data. Once a node is reset there is
no fallback — an unreadable snapshot discovered after B4 leaves the cluster unrecoverable via this path.

```bash
ls -lh <snapshot-path>
file <snapshot-path>  # etcd snapshots show as "data" (raw BoltDB)
# If etcdutl is installed (preferred):
etcdutl snapshot status <snapshot-path>
```

If the snapshot file is missing, zero bytes, or `file` reports it as unrecognized: **abort**.
The data-loss window is unavoidable — do not proceed with a corrupt snapshot.

### B4. Reset all CP nodes (EPHEMERAL wipe)

Reset nodes one at a time to avoid overwhelming the network:

```bash
for ip in 192.168.2.61 192.168.2.62 192.168.2.63; do
  talosctl reset --system-labels-to-wipe EPHEMERAL --reboot --graceful=false \
    -n $ip -e $ip
  sleep 30  # Stagger to avoid simultaneous reboot
done
```

Wait for all nodes to reach maintenance mode (API reachable but etcd not yet running):
```bash
for ip in 192.168.2.61 192.168.2.62 192.168.2.63; do
  talosctl version -n $ip -e $ip
done
```

### B5. Bootstrap from snapshot on first CP node

```bash
talosctl bootstrap --recover-from=<snapshot-path> \
  -n 192.168.2.61 -e 192.168.2.61
```

Wait for the API server to come up (poll `kubectl get nodes` for up to 5 min).

### B6. Wait for remaining members to rejoin

The other two CP nodes will auto-discover and join as learners once node-01 bootstraps.
Monitor:

```
# Poll up to 18 × 10 s = 3 min
for i in $(seq 1 18); do
  talos_etcd(subcommand="members", nodes=["192.168.2.61"])
  sleep 10
done
```

All three members must appear with `started` status.

### B7. Verify cluster health

```
talos_health(nodes=["192.168.2.61", "192.168.2.62", "192.168.2.63"])
# Fallback: talosctl health -n 192.168.2.61 -e 192.168.2.61 \
#   --control-plane-nodes 192.168.2.61,192.168.2.62,192.168.2.63
```

Check Kubernetes API is responsive:
```bash
KUBECONFIG=<kubeconfig> kubectl get nodes
KUBECONFIG=<kubeconfig> kubectl get pods -n argocd
```

### B8. Trigger ArgoCD reconciliation

After cluster recovery, ArgoCD may show stale sync state:
```bash
KUBECONFIG=<kubeconfig> kubectl annotate application --all -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite
```

---

## Post-Recovery Checklist

- [ ] All three etcd members show `started` (`talos_etcd subcommand=status`)
- [ ] All CP nodes show `Ready` in `kubectl get nodes`
- [ ] `talos_health` reports healthy
- [ ] ArgoCD applications are syncing
- [ ] LINSTOR satellites are `Running` (if applicable): `kubectl get pods -n piraeus-datastore`
- [ ] GPU taint intact on node-gpu-01: `kubectl get node node-gpu-01 -o jsonpath='{.spec.taints}'`

## Hard Rules

- Never run Path B without explicit user confirmation for the data-loss window.
- Never bootstrap from snapshot on more than one node simultaneously.
- The `talos_reset` tool is not available in this skill's `allowed-tools` — use `talosctl` CLI for reset steps (both paths).
- After Path B recovery, take a new snapshot immediately:
  ```
  talos_etcd_snapshot(nodes=["192.168.2.61"], path="/tmp/etcd-post-recovery-<date>.snapshot")
  ```
- **DRBD/storage caveat:** Path A's EPHEMERAL wipe is safe on this cluster because CP nodes
  (`node-01..03`) are not LINSTOR/Piraeus storage nodes — storage is confined to worker nodes
  with the `feature.node.kubernetes.io/storage-nvme.present=true` NFD label. Do NOT apply Path A
  to a hyperconverged CP node that also runs DRBD volumes without draining DRBD first.
