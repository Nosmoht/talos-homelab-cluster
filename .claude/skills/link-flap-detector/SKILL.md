---
name: link-flap-detector
description: Detect link flaps across nodes via Talos MCP dmesg + carrier_changes sysfs. Correlates cross-node timestamps to distinguish local cable/NIC faults from upstream switch issues. Emits structured JSON with per-node HEALTHY/WARNING/CRITICAL verdict.
disable-model-invocation: true
argument-hint: "[--node <name>] [--baseline <path>] [--json] [--save-baseline] [--window <duration>]"
allowed-tools:
  - mcp__talos__talos_dmesg
  - mcp__talos__talos_read_file
  - mcp__talos__talos_list_files
  - mcp__kubernetes-mcp-server__resources_list
  - Bash
  - Read
  - Write
model: inherit
---

# Link-Flap Detector

Read `carrier_changes` sysfs counters and `dmesg` link events per node via Talos MCP, classify
per-node verdict, correlate timestamps across nodes to distinguish local NIC/cable faults from
upstream switch issues. Emits JSON conforming to `docs/primitive-contract.md`.

## Environment Setup

Read `cluster.yaml` for kubeconfig path. If missing, stop: "Copy
`cluster.yaml.example` to `cluster.yaml` and fill in your cluster details."

Extract before running any commands:
```bash
KUBECONFIG=$(yq '.kubeconfig' cluster.yaml)
```

## Reference Files

Read before acting:
- `references/failure-patterns.md` — severity rules, dmesg parse table, cross-node correlation logic
- `docs/primitive-contract.md` — output schema, fail-closed semantics, schema version
- `.claude/rules/talos-mcp-first.md` — Talos MCP usage policy
- `.claude/rules/kubernetes-mcp-first.md` — Kubernetes MCP usage policy and fallback contract

## Inputs

`$ARGUMENTS` (optional):
- `--node <name>` — limit detection to one node; default: all nodes via `resources_list`
- `--baseline <path>` — diff `carrier_changes` against existing baseline JSON; default: no diff
- `--json` — emit JSON only, no human-readable summary; default: emit both
- `--save-baseline` — persist current `carrier_changes` snapshot under
  `tests/baselines/link-flap-detector/<node>-<YYYY-MM-DD>.json`
- `--window <duration>` — dmesg event window (`5m`, `30m`, `1h`, `6h`, `24h`); default `1h`.
  Bounds the dmesg event count and correlation search; does not bound `carrier_changes` (lifetime).

## Scope Guard

Read-only diagnostic. Does not modify NIC config, restart drivers, or touch switch state. Pairs
with `/nic-health-audit` (broader counter audit) — this skill is the targeted follow-up when
`nic-health-audit` flags `carrier_changes > 0`.

Excluded: switch-side telemetry (SNMP, LLDP), cable certification, SFP DDM. Those are out of
Phase-1a scope.

## Workflow

### 1. Resolve schema version (fail-closed)

Bash strict-mode-safe lookup:

```bash
CONTRACT_PATH="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || echo /nonexistent)}/docs/primitive-contract.md"
SCHEMA_VERSION=$(yq e '.schema_version' "$CONTRACT_PATH" 2>/dev/null) \
  || { jq -n --arg p "link-flap-detector" '{primitive:$p,verdict:"PRECONDITION_NOT_MET",reason:"contract not readable",timestamp:now|todate}'; exit 0; }
[ -z "$SCHEMA_VERSION" ] && SCHEMA_VERSION="unknown"
```

### 2. Discover target nodes

If `--node <name>` is given: resolve its IP via `resources_list` and limit to that one node.

Else, list all nodes:
```
resources_list(apiVersion="v1", kind="Node")
# Fallback: KUBECONFIG=$KUBECONFIG kubectl get nodes -o json
```

Extract internal IPs from `items[].status.addresses[?type=="InternalIP"].address`. Map IP → node
name from `items[].metadata.name`. Audit ALL nodes including taint-isolated ones (e.g.
`node-pi-01`) — Talos MCP does not require pod schedulability.

If `resources_list` returns empty (case b — valid zero result), emit a top-level
`PRECONDITION_NOT_MET` JSON describing "no nodes discovered" and stop. Do not retry against
kubectl on empty.

If `resources_list` errors or times out (case a), retry once, then fall back to `kubectl get
nodes -o json` and log the fallback in the report.

### 3. List physical NIC interfaces per node

For each target node IP:
```
talos_list_files(path="/sys/class/net", nodes=["<node-ip>"])
```

Filter out virtual interfaces: `lo`, `cilium_*`, `lxc*`, `cni*`, `cilium_health`, `cilium_net`,
`cilium_vxlan`, `cilium_geneve`, `kube-ipvs0`, `flannel.*`. Keep physical-NIC candidates only
(typically `eth*`, `enp*`, `eno*`, `ens*`, `bond*`, `wg*`).

If `talos_list_files` fails for a node: mark it `PRECONDITION_NOT_MET` in `results[]`, continue
with others.

### 4. Read carrier_changes per interface

For each (node, interface):
```
talos_read_file(path="/sys/class/net/<iface>/carrier_changes", nodes=["<node-ip>"])
```

Parse decimal integer. If missing (rare; some virtual drivers don't expose it): record `null`,
do not fail.

### 5. Collect dmesg link events per node

For each node:
```
talos_dmesg(nodes=["<node-ip>"])
```

Filter lines matching the regex `link is down|link is up|Link is Down|Link is Up|NIC Link is|carrier (lost|gained)`.

Parse each matching line into `{timestamp, iface, direction, raw}`:
- `timestamp` — kernel timestamp converted to ISO-8601 UTC (use node boot time + monotonic offset, or
  rely on `talos_dmesg` returning wall-clock when available)
- `iface` — extract first interface token (e.g. `eth0`, `enp1s0`); fall back to `"unknown"` if
  the line lacks a clear iface field
- `direction` — apply the parse table in `references/failure-patterns.md` §"Direction Heuristics"
- `raw` — verbatim dmesg line for human inspection

Apply `--window` filter: keep only events whose timestamp is within the window from "now". Drop
older events from per-node `events[]` and from cross-node correlation input.

If `talos_dmesg` fails for a node: record `dmesg_events: null` for that node, continue. Do not
mark the node `PRECONDITION_NOT_MET` solely on dmesg failure if `carrier_changes` succeeded —
record a finding instead: `"dmesg unavailable — verdict based on carrier_changes only"`.

### 6. Optional baseline diff

If `--baseline <path>` is given:
- `Read` the file
- For each (node, iface), compute `delta = current_carrier_changes - baseline_carrier_changes`
- Negative deltas (counter wrap or NIC reset) → record finding "counter wrap detected — baseline
  stale", treat as no-delta
- Positive deltas feed §7 severity rules as `carrier_changes_in_window` instead of lifetime

If no `--baseline`: severity rules apply against lifetime `carrier_changes` plus
`dmesg_event_count` within window.

### 7. Classify per-node verdict

Apply rules from `references/failure-patterns.md` §"Per-Interface Severity Rules". Each interface
produces an interface verdict; the worst interface verdict becomes the node verdict.

Add root-cause hints to per-node `findings[]` per the patterns in
`references/failure-patterns.md` §"Root-Cause Hint Patterns".

### 8. Cross-node correlation

After per-node verdict, build a flat list of all events (across all nodes, within window).
Sort by timestamp. Sweep a 5-second sliding window: any window with events from ≥ 2 distinct
nodes is a correlation cluster.

For each cluster, append to **every involved node's** `findings[]`:

```
"simultaneous flap on <node-list> at <iso-ts> — likely upstream switch issue or VLAN-trunk reconverge"
```

Promote involved-node verdicts to CRITICAL.

### 9. Emit JSON

Build canonical output:

```json
{
  "primitive": "link-flap-detector",
  "version": "<SCHEMA_VERSION from §1>",
  "timestamp": "<ISO-8601 UTC>",
  "verdict": "<aggregate: worst per-node>",
  "shape": "per_node",
  "preconditions": {
    "required": ["talos_mcp", "sysfs_class_net", "kernel_dmesg"],
    "met": true
  },
  "results": [
    {
      "node": "<name>",
      "verdict": "HEALTHY|WARNING|CRITICAL|PRECONDITION_NOT_MET",
      "metrics": {
        "<iface>": {
          "carrier_changes": N,
          "dmesg_events": N,
          "events": [
            { "timestamp": "<iso>", "iface": "<iface>", "direction": "down|up|carrier-loss|carrier-gain", "raw": "<line>" }
          ]
        }
      },
      "findings": ["<string>", ...]
    }
  ],
  "summary": {
    "healthy": N,
    "warning": N,
    "critical": N
  }
}
```

Aggregate-verdict precedence: `CRITICAL > WARNING > HEALTHY > PRECONDITION_NOT_MET`. If any node
is CRITICAL, aggregate is CRITICAL.

### 10. Optional baseline persist

If `--save-baseline` is given: write per-node `carrier_changes` to
`tests/baselines/link-flap-detector/<node>-<YYYY-MM-DD>.json`. One file per node, current snapshot
only (no verdict, no events — just the lifetime counter per iface). Useful for next-day deltas.

## Output

If `--json`: emit the JSON to stdout. Done.

Else: emit the JSON, then a human-readable summary table:

```
| Node      | Verdict  | carrier_changes | dmesg events | Findings                                  |
|-----------|----------|-----------------|--------------|-------------------------------------------|
| node-01   | HEALTHY  | 2 (eth0)        | 0            | -                                         |
| node-04   | CRITICAL | 14 (eth0)       | 6 in 1h      | repeated flap on eth0 — local cable/NIC   |
| node-pi-01| WARNING  | 4 (eth0)        | 1 in 1h      | isolated event, monitor                   |
```

CRITICAL nodes first, then WARNING, then HEALTHY.

## Hard Rules

- Read-only: never modify sysfs, node config, or switch state.
- Talos MCP `talos_dmesg` / `talos_read_file` / `talos_list_files` for all node access — never
  `talosctl` CLI from this skill.
- Aggregate `verdict` is the worst per-node verdict.
- Never fabricate event timestamps; if a dmesg read fails for a node, record finding "dmesg
  unavailable" and continue with `carrier_changes` only.
- Bash strict-mode (`set -euo pipefail`) compatible — see §1 yq lookup pattern.
- On Kubernetes MCP tool failure: retry once, then run the `# Fallback:` kubectl command from the
  same step. Record the fallback in the report. Applies to all `mcp__kubernetes-mcp-server__*`
  calls in this skill.
- Cross-node correlation window is 5 s by default. Do not widen without verifying chrony skew
  across nodes is < 500 ms — see `references/failure-patterns.md` §Tuning.
