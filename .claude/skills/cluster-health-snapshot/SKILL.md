---
name: cluster-health-snapshot
description: "Check cluster health across Talos, Kubernetes, Cilium, LINSTOR, and PKI. Use after upgrades, maintenance, or ArgoCD syncs to verify all subsystems are healthy."
argument-hint: "[--subsystem talos|k8s|cilium|storage|pki|all]"
disable-model-invocation: true
allowed-tools:
  - Bash
  - Read
  - Write
  - mcp__talos__talos_health
  - mcp__talos__talos_etcd
  - mcp__talos__talos_version
  - mcp__kubernetes-mcp-server__resources_list
  - mcp__kubernetes-mcp-server__resources_get
  - mcp__kubernetes-mcp-server__pods_list
  - mcp__kubernetes-mcp-server__pods_list_in_namespace
  - mcp__kubernetes-mcp-server__nodes_top
---

# Cluster Health Snapshot

## Environment Setup

Read `cluster.yaml` for kubeconfig path, CP node IPs, and full node IP map.
If the file is missing, stop: "Copy `cluster.yaml.example` to `cluster.yaml` and fill in your cluster details."

Extract variables before running any commands:
```bash
CP1=$(yq '.nodes.control_plane[0].ip' cluster.yaml)
CP2=$(yq '.nodes.control_plane[1].ip' cluster.yaml)
CP3=$(yq '.nodes.control_plane[2].ip' cluster.yaml)
KUBECONFIG=$(yq '.kubeconfig' cluster.yaml)
```
If any variable is empty after extraction, stop: "Required field missing in `cluster.yaml`. Check `cluster.yaml.example` for the schema."

## Reference Files

Read before acting:
- `cluster.yaml` — kubeconfig, CP IPs, node inventory
- `docs/day2-operations.md` — "Cluster Health Checks" section (commands per subsystem, thresholds)
- `.claude/rules/talos-mcp-first.md` — etcd quorum thresholds, D-state recovery guidance

## Inputs

- `$ARGUMENTS`: Optional `--subsystem` filter. Supported values: `talos`, `k8s`, `cilium`, `storage`, `pki`, `all`. Default: `all`.

Examples:
```
/cluster-health-snapshot
/cluster-health-snapshot --subsystem cilium
/cluster-health-snapshot --subsystem storage
```

## Scope Guard

This is a read-only health check. If remediation is needed, suggest the appropriate skill:
- ArgoCD sync failures → `/gitops-health-triage`
- Storage degraded/DRBD issues → `/linstor-storage-triage`
- XFS corruption (mount exit 32, bad superblock) → `/linstor-volume-repair` (after triage)
- Cilium policy drops → `/cilium-policy-debug`
- Node config or upgrade needed → `/talos-apply` or `/talos-upgrade`

Do not attempt remediation from this skill.

## Workflow

### 1. Talos layer (skip if --subsystem not talos/all)

Run:
```
talos_health(nodes=["$CP1"])
talos_etcd(subcommand="members", nodes=["$CP1"])
talos_etcd(subcommand="status", nodes=["$CP1"])
# Fallback: talosctl -n $CP1 -e $CP1 health --control-plane-nodes $CP1,$CP2,$CP3 && talosctl -n $CP1 -e $CP1 etcd members && talosctl -n $CP1 -e $CP1 etcd status
```

If `talos_health` returns an error or connection failure, record as **CRIT**: "Cannot reach control plane node $CP1. Verify the node is up before running this skill."
If `talos_health` returns a health failure, record as **CRIT** with the specific error.
If etcd member count < 3 or learner count > 0, record as **WARN**.
If any member is unhealthy, record as **CRIT**.

### 2. Kubernetes layer (skip if --subsystem not k8s/all)

Run:
```
resources_list(apiVersion="v1", kind="Node")
pods_list(fieldSelector="status.phase!=Running,status.phase!=Succeeded")
nodes_top()
# Fallback: KUBECONFIG=$KUBECONFIG kubectl get nodes -o wide && KUBECONFIG=$KUBECONFIG kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded && KUBECONFIG=$KUBECONFIG kubectl top nodes
```

Note: `pods_list` returns structured `containerStatuses`. CrashLoopBackOff is
a container state, not a pod phase — detect it client-side from
`containerStatuses[].state.waiting.reason`, not via `fieldSelector`.

If `resources_list` for `Node` fails, record as **CRIT**: "Kubernetes API unreachable."
If `nodes_top` fails (metrics-server unavailable), record as **WARN**: "Resource usage unavailable — metrics-server not running." Continue with other checks.
NotReady nodes: **CRIT**. CrashLoopBackOff or OOMKilled pods in non-completed state: **WARN**. Nodes above 90% CPU or memory: **WARN**.

### 3. Cilium layer (skip if --subsystem not cilium/all)

Run:
```
pods_list_in_namespace(namespace="kube-system", labelSelector="k8s-app=cilium")
resources_list(apiVersion="cilium.io/v2", kind="CiliumNode")
# Fallback: KUBECONFIG=$KUBECONFIG kubectl -n kube-system get pods -l k8s-app=cilium -o wide && KUBECONFIG=$KUBECONFIG kubectl get ciliumnode -o wide
```

If `resources_list` for `CiliumNode` returns an empty list, record as **CRIT**: "No CiliumNode objects — Cilium may not be running."
Any Cilium agent not Running: **CRIT**. Stale or mismatched CiliumNode IPs: **WARN**.

**Interpreting `cilium-dbg status` Modules Health line**: the format is `Stopped(N) Degraded(M) OK(K)`. `Stopped(N)` lists *completed one-shot Hive jobs* (init, cleanup, restore, sync-crds, proxy-bootstrapper, etc.) reporting their final post-completion state — not failed modules. As of Cilium 1.19.2 the steady-state count is **24 STOPPED** on every node regardless of role. The actual failure signal is `Degraded(M) ≠ 0`, or a `Stopped(N)` count that diverges across nodes. Do not flag a uniform Stopped count as a defect.

### 4. LINSTOR/Storage layer (skip if --subsystem not storage/all)

Run:
```bash
# kubectl-only: kubectl-linstor plugin has no MCP equivalent
KUBECONFIG=$KUBECONFIG kubectl linstor node list
KUBECONFIG=$KUBECONFIG kubectl linstor resource list
KUBECONFIG=$KUBECONFIG kubectl linstor storage-pool list
```

If `kubectl linstor` returns "unknown command", record as **WARN**: "kubectl-linstor plugin not installed — storage checks skipped." Continue with other layers.
Satellite OFFLINE or UNKNOWN: **CRIT**. Resources in Degraded/SyncTarget/Inconsistent state: **WARN**. Storage pools below 20% free: **WARN**.

### 5. PKI layer (skip if --subsystem not pki/all)

Run:
```
resources_list(apiVersion="cert-manager.io/v1", kind="ClusterIssuer")
resources_list(apiVersion="cert-manager.io/v1", kind="Certificate")
# Fallback: KUBECONFIG=$KUBECONFIG kubectl get clusterissuer && KUBECONFIG=$KUBECONFIG kubectl get certificate -A
```

If `resources_list` for `ClusterIssuer` returns an empty list, record as **WARN**: "cert-manager not installed — PKI checks skipped." Continue with other layers.
ClusterIssuer not Ready: **CRIT**. Certificates expired or expiring within 7 days: **WARN**.

## Output

Present a health report table to the user:

```
| Layer   | Status | Issues |
|---------|--------|--------|
| Talos   | OK/WARN/CRIT | details |
| K8s     | OK/WARN/CRIT | details |
| Cilium  | OK/WARN/CRIT | details |
| Storage | OK/WARN/CRIT | details |
| PKI     | OK/WARN/CRIT | details |
```

List CRIT items first. For each issue, cite the relevant section from `docs/day2-operations.md` and the appropriate follow-up skill.

Optionally write a snapshot to `docs/cluster-health-<date>.md` if the user requests a record.

## Hard Rules

- Read-only: never modify cluster state. Observation only.
- Use `-n $CP1 -e $CP1` (first control plane IP from cluster.yaml) for all talosctl commands. Never use VIP.
- Do not attempt automated remediation — report findings and point to the appropriate skill.
- If a command fails due to tool unavailability (linstor plugin, metrics-server), record as WARN and continue — do not stop the entire health check.
- On Kubernetes MCP tool failure: retry once, then run the `# Fallback:` kubectl command from the same step. Record the fallback in the report. Applies to all `mcp__kubernetes-mcp-server__*` calls in this skill.
