---
name: nic-health-audit
description: Audit NIC health across nodes by reading sysfs counters via Talos MCP. Detects link flaps, CRC errors, ring-buffer drops. Emits structured JSON with per-node HEALTHY/WARNING/CRITICAL verdict.
disable-model-invocation: true
argument-hint: "[--node <name>] [--baseline <path>] [--json] [--save-baseline]"
allowed-tools:
  - mcp__talos__talos_read_file
  - mcp__talos__talos_list_files
  - mcp__kubernetes-mcp-server__resources_list
  - Bash
  - Read
  - Write
model: inherit
---

# NIC Health Audit

Read NIC counters from `/sys/class/net/<iface>/statistics/` per node via Talos MCP, classify a per-node verdict, optionally diff against a baseline. Emits JSON conforming to `docs/primitive-contract.md`.

## Environment Setup

Read `cluster.yaml` for kubeconfig path. If missing, stop: "Copy `cluster.yaml.example` to `cluster.yaml` and fill in your cluster details."

Extract before running any commands:
```bash
KUBECONFIG=$(yq '.kubeconfig' cluster.yaml)
```

## Reference Files

Read before acting:
- `references/sysfs-counter-thresholds.md` — counter list, severity thresholds, root-cause hints
- `docs/primitive-contract.md` — output schema, fail-closed semantics, schema version
- `.claude/rules/talos-mcp-first.md` — Talos MCP usage policy

## Inputs

`$ARGUMENTS` (optional):
- `--node <name>` — limit audit to one node; default: all nodes via `resources_list`
- `--baseline <path>` — diff against existing baseline JSON; default: no diff (current snapshot only)
- `--json` — emit JSON only, no human-readable summary; default: emit both
- `--save-baseline` — persist current snapshot under `tests/baselines/nic-health-audit/<node>-<YYYY-MM-DD>.json`

## Scope Guard

Read-only diagnostic. ethtool driver-private counters are explicitly out of scope (Phase 1b — Issue #100 ring-buffer-tuner). For ring-buffer or link-flap follow-up, suggest `/link-flap-detector` (Issue #108) or, when available, ring-buffer-tuner.

## Workflow

### 1. Resolve schema version (fail-closed)

Bash strict-mode-safe lookup:

```bash
CONTRACT_PATH="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || echo /nonexistent)}/docs/primitive-contract.md"
SCHEMA_VERSION=$(yq e '.schema_version' "$CONTRACT_PATH" 2>/dev/null) \
  || { jq -n --arg p "nic-health-audit" '{primitive:$p,verdict:"PRECONDITION_NOT_MET",reason:"contract not readable",timestamp:now|todate}'; exit 0; }
[ -z "$SCHEMA_VERSION" ] && SCHEMA_VERSION="unknown"
```

### 2. Discover target nodes

If `--node <name>` is given: resolve its IP via `resources_list` and limit to that one node.

Else, list all nodes:
```
resources_list(apiVersion="v1", kind="Node")
# Fallback: KUBECONFIG=$KUBECONFIG kubectl get nodes -o json
```

Extract internal IPs from `items[].status.addresses[?type=="InternalIP"].address`. Map IP → node name from `items[].metadata.name`.

If `resources_list` returns empty (case b — valid zero result), emit a `PRECONDITION_NOT_MET` JSON describing "no nodes discovered" and stop. Do not retry against kubectl on empty.

If `resources_list` errors or times out (case a), retry once, then fall back to `kubectl get nodes -o json` and log the fallback in the report.

### 3. List NIC interfaces per node

For each target node IP:
```
talos_list_files(path="/sys/class/net", nodes=["<node-ip>"])
```

Filter out virtual interfaces: `lo`, `cilium_*`, `lxc*`, `cni*`, `cilium_health`, `cilium_net`, `cilium_vxlan`, `cilium_geneve`, `kube-ipvs0`, `flannel.*`. Keep physical-NIC candidates only (typically `eth*`, `enp*`, `eno*`, `ens*`, `bond*`, `wg*`).

If `talos_list_files` fails for a node: mark that node `PRECONDITION_NOT_MET` in `results[]`, continue with others.

### 4. Read sysfs counters per interface

Counter list comes from `references/sysfs-counter-thresholds.md` (canonical set: `rx_packets`, `tx_packets`, `rx_errors`, `tx_errors`, `rx_dropped`, `rx_crc_errors`, `rx_frame_errors`, `rx_missed_errors`, `collisions`, `carrier_changes`, `tx_dropped`).

For each (node, interface, counter):
```
talos_read_file(path="/sys/class/net/<iface>/statistics/<counter>", nodes=["<node-ip>"])
```

Parse decimal integer. If a counter is missing (some NIC drivers don't expose all): record as `null` in metrics, do not fail.

### 5. Optional baseline diff

If `--baseline <path>` is given:
- `Read` the file
- For each (node, iface, counter), compute `delta = current - baseline_value`
- Negative deltas (counter wrap or NIC reset) → record finding "counter wrap detected — baseline stale", treat as no-delta
- Positive deltas feed into severity rules below as "delta since baseline"

If no `--baseline`: severity rules apply against absolute (lifetime) counters.

### 6. Classify per-node verdict

Apply rules from `references/sysfs-counter-thresholds.md`. Each interface produces an interface verdict; the worst interface verdict becomes the node verdict.

Add root-cause hints to per-node `findings[]`:
- `carrier_changes > 0` → `"carrier_changes=N — link flap candidate, run /link-flap-detector for details"`
- `rx_missed_errors > 0 && rx_crc_errors == 0` → `"rx_missed=N, crc=0 — ring buffer pressure, candidate for ring-buffer tuning (Phase 1b #100)"`
- `rx_crc_errors > 0` → `"rx_crc=N — physical layer issue (cable, SFP, or duplex mismatch)"`
- `collisions > 0 on full-duplex` → `"collisions=N on switched network — duplex mismatch likely"`

### 7. Cross-node outlier compare

Compute per-counter mean and population standard deviation across all nodes. For each (node, iface, counter), if the value is more than 2σ from the mean AND the absolute value passes a noise floor (counter > 10), append a finding: `"<counter>=N is N.N σ above cluster mean — outlier"`.

This is informational; outlier alone does not raise verdict. It promotes existing WARNING to CRITICAL only if the outlier is on `rx_errors`, `tx_errors`, `rx_crc_errors`, or `carrier_changes`.

### 8. Emit JSON

Build canonical output:

```json
{
  "primitive": "nic-health-audit",
  "version": "<SCHEMA_VERSION from §1>",
  "timestamp": "<ISO-8601 UTC>",
  "verdict": "<aggregate: worst per-node>",
  "shape": "per_node",
  "preconditions": {
    "required": ["talos_mcp", "sysfs_class_net"],
    "met": true
  },
  "results": [
    {
      "node": "<name>",
      "verdict": "HEALTHY|WARNING|CRITICAL|PRECONDITION_NOT_MET",
      "metrics": {
        "<iface>": {
          "rx_errors": N,
          "tx_errors": N,
          "rx_dropped": N,
          "rx_crc_errors": N,
          "rx_frame_errors": N,
          "rx_missed_errors": N,
          "collisions": N,
          "carrier_changes": N,
          "rx_packets": N,
          "tx_packets": N,
          "tx_dropped": N
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

Aggregate-verdict precedence: `CRITICAL > WARNING > HEALTHY > PRECONDITION_NOT_MET`. If any node is CRITICAL, aggregate is CRITICAL.

### 9. Optional baseline persist

If `--save-baseline` is given: write the current `metrics` block per node to `tests/baselines/nic-health-audit/<node>-<YYYY-MM-DD>.json`. One file per node, current-snapshot-only (no verdict, no findings — just raw counters). Useful for next-day diffs.

## Output

If `--json` only: emit the JSON to stdout. Done.

Else: emit the JSON, then a human-readable summary table:

```
| Node      | Verdict  | Findings                            |
|-----------|----------|-------------------------------------|
| node-01   | HEALTHY  | -                                   |
| node-04   | WARNING  | rx_dropped=42 on eth0, see hints    |
| node-pi-01| CRITICAL | carrier_changes=14 on eth0          |
```

CRITICAL nodes first, then WARNING, then HEALTHY.

## Hard Rules

- Read-only: never modify sysfs, node config, or cluster state.
- Talos MCP `talos_read_file` / `talos_list_files` for all sysfs access — never `talosctl read` CLI from this skill.
- Aggregate `verdict` is the worst per-node verdict.
- Never fabricate counter values; if a read fails for a node, record `PRECONDITION_NOT_MET` for that node only and continue with others.
- Bash strict-mode (`set -euo pipefail`) compatible — see §1 yq lookup pattern.
- On Kubernetes MCP tool failure: retry once, then run the `# Fallback:` kubectl command from the same step. Record the fallback in the report. Applies to all `mcp__kubernetes-mcp-server__*` calls in this skill.
