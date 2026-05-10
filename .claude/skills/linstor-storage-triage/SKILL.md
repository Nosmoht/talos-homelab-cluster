---
name: linstor-storage-triage
description: "Triage LINSTOR/DRBD storage health: degraded resources, satellite status, sole-replica safety check before node drain, and HA controller behavior."
argument-hint: "[--node <node-name>] [--resource <resource-name>] [--post-drain]"
disable-model-invocation: true
allowed-tools: Bash, Read
---

# LINSTOR Storage Triage

## Environment Setup

Read `cluster.yaml` for kubeconfig path and node IP map.
If the file is missing, stop: "Copy `cluster.yaml.example` to `cluster.yaml` and fill in your cluster details."

Extract before running any commands:
```bash
KUBECONFIG=$(yq '.kubeconfig' cluster.yaml)
```

## Reference Files

Read before acting:
- `cluster.yaml` — kubeconfig, node IP map
- `docs/day2-operations.md` — LINSTOR health commands
- `.claude/rules/talos-mcp-first.md` — "DRBD volumes in D-state deadlock upgrade" gotcha — critical reading before any node operation

## Inputs

- `--node <name>`: Scope to a specific node. Without `--post-drain`, runs the pre-drain sole-replica safety check. With `--post-drain`, runs post-maintenance sync verification instead.
- `--resource <name>`: Focus on a single LINSTOR resource by its LINSTOR resource name (not PVC name — use `kubectl linstor resource list` to find the resource name).
- `--post-drain`: When used with `--node`, runs post-drain sync verification instead of the pre-drain check.

Examples:
```
/linstor-storage-triage
/linstor-storage-triage --node talos-worker-01
/linstor-storage-triage --node talos-worker-01 --post-drain
/linstor-storage-triage --resource pvc-abc123-xyz
```

## Scope Guard

If a node drain is blocked by this triage:
- Run this skill FIRST to diagnose the blocking resources
- Then use `/talos-apply` or `/talos-upgrade` for the node operation itself

If the issue is an ArgoCD sync failure for the Piraeus operator:
- Stop. Suggest `/gitops-health-triage` instead.

## Workflow

### 1. Node health

Run:
```bash
KUBECONFIG=$KUBECONFIG kubectl linstor node list
```

If this command fails, stop and report: "kubectl-linstor plugin unavailable or LINSTOR controller unreachable. Check Piraeus operator health."
Flag any satellite OFFLINE or UNKNOWN as **CRIT** — stop and report:
> "Satellite <name> is OFFLINE. DRBD cannot replicate. Resolve this before any node operations. Check `docs/day2-operations.md` LINSTOR section."

### 2. Storage pool saturation

Run:
```bash
KUBECONFIG=$KUBECONFIG kubectl linstor storage-pool list
```

Flag pools below 20% free as **WARN**. Flag pools below 5% free as **CRIT**.

### 3. Degraded resources

Run:
```bash
KUBECONFIG=$KUBECONFIG kubectl linstor resource list
```

If `--resource` is specified, filter the output to rows containing that resource name.

Check the `State` column for each resource replica. LINSTOR aggregates DRBD disk-state (UpToDate, Inconsistent, Outdated, DUnknown, Failed) and replication-state (SyncTarget, SyncSource, Established) into the `State` column. Flag any replica showing `SyncTarget`, `Inconsistent`, `Outdated`, or `Failed` as **WARN**. Flag multiple simultaneous degraded resources as **CRIT** — data loss risk.

Note: TieBreaker replicas (diskless quorum members) show as `TieBreaker` in the `State` column and hold no data. Do not count them as UpToDate data replicas.

### 4. HA controller status

Run:
```bash
KUBECONFIG=$KUBECONFIG kubectl -n piraeus-datastore get pods -l app.kubernetes.io/name=piraeus-ha-controller
KUBECONFIG=$KUBECONFIG kubectl -n piraeus-datastore logs -l app.kubernetes.io/name=piraeus-ha-controller --tail=50
```

Flag: pod not Running as **CRIT**. More than 3 restarts as **WARN**. Log entries containing "quorum loss" or "evict" as **WARN**.

### 5. Pre-drain sole-replica check (only when --node specified WITHOUT --post-drain)

Run:
```bash
KUBECONFIG=$KUBECONFIG kubectl linstor resource list
```

For each LINSTOR resource that has a replica on the target node, count the number of other nodes where the replica `State` column shows `UpToDate` (excluding TieBreaker replicas).

Example: if output shows:
```
| resource-abc | talos-worker-01 | UpToDate |
| resource-abc | talos-worker-02 | UpToDate |
```
Then draining talos-worker-01 leaves 1 UpToDate replica — this is acceptable (≥1 other).

If ANY resource on the target node has 0 other UpToDate replicas (only its own replica is UpToDate), **BLOCK immediately** and output:

> "BLOCK: Node <name> cannot be safely drained.
> DRBD resource <X> has no other UpToDate replica — draining this node would make data unavailable.
> To resolve: add a replica on another node first:
> `kubectl linstor resource create <X> <other-node>`
> Then re-run `/linstor-storage-triage --node <name>` to confirm it is safe."

**Stop the skill here. Do not produce any further output. Do not present Step 6.**

### 6. Post-drain sync verification (only when --node specified WITH --post-drain)

This step verifies that a node that has returned from maintenance has successfully resynced all its DRBD resources. Run this only after the node is back online.

Run:
```bash
KUBECONFIG=$KUBECONFIG kubectl linstor resource list
```

Filter to resources on the returning node. Confirm all replicas on that node show `UpToDate` in the `State` column.

If all replicas are UpToDate: report **OK — sync complete**.
If any replica shows `SyncTarget` or `Inconsistent` (still syncing): report **WARN** with count of resources still syncing. Recommend re-running this skill in 2–5 minutes.
If any replica shows `Failed` or `DUnknown` after more than 10 minutes: report **CRIT** — manual intervention needed. Check `docs/day2-operations.md` LINSTOR section.

## Output

Present a storage health report:

```
| Check              | Status      | Details |
|--------------------|-------------|---------|
| Satellites         | OK/CRIT     | N online |
| Pool saturation    | OK/WARN/CRIT| pools below threshold |
| Resource health    | OK/WARN/CRIT| N degraded |
| HA controller      | OK/WARN     | events summary |
| Pre-drain check    | PASS/BLOCK  | resources at risk (if --node) |
| Post-drain sync    | OK/WARN/CRIT| N resources syncing (if --node --post-drain) |
```

If the pre-drain check blocks, output **only** the BLOCK message with resource names and the exact replica-add command. Do not continue to other output.

## Escalation

If triage reveals XFS corruption (resource UpToDate but pod fails with mount exit code 32
or "bad superblock" in events), escalate to:
`/linstor-volume-repair --resource <name> --node <node>`

## Hard Rules

- Read-only: this skill observes storage state, never modifies it.
- If the sole-replica check fails, stop immediately and output only the BLOCK message. No override. No "proceed with caution" path.
- DRBD D-state (as documented in `.claude/rules/talos-mcp-first.md` §Node Recovery) requires power-cycle recovery — never attempt to proceed through it.
- TieBreaker replicas hold no data and must NOT be counted as UpToDate data replicas in the sole-replica check.
