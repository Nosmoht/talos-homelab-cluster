---
name: irq-affinity-auditor
description: Audit IRQ affinity across nodes by parsing /proc/interrupts and /proc/irq/<n>/smp_affinity via Talos MCP. Detects NIC/NVMe IRQs pinned to cpu0 or unevenly distributed. Emits per-node verdict and a set_irqaffinity rebalance shell snippet (never auto-applied).
disable-model-invocation: true
argument-hint: "[--node <name>] [--json] [--save-baseline]"
allowed-tools:
  - mcp__talos__talos_read_file
  - mcp__talos__talos_list_files
  - mcp__kubernetes-mcp-server__resources_list
  - Bash
  - Read
  - Write
model: inherit
---

# IRQ Affinity Auditor

Parse `/proc/interrupts` and per-IRQ `smp_affinity` bitmaps per node via Talos MCP, classify a per-node verdict (`balanced` | `unbalanced` | `pinned-to-cpu0`), and emit a `set_irqaffinity` shell snippet for any node that needs rebalancing. The snippet is written into the JSON output as a string in `findings[]` — it is never auto-applied. Output JSON conforms to `docs/primitive-contract.md`.

## Environment Setup

Read `cluster.yaml` for kubeconfig path. If missing, stop: "Copy `cluster.yaml.example` to `cluster.yaml` and fill in your cluster details."

Extract before running any commands:
```bash
KUBECONFIG=$(yq '.kubeconfig' cluster.yaml)
```

## Reference Files

Read before acting:
- `docs/primitive-contract.md` — output schema, fail-closed semantics, schema version (§B1)
- `.claude/rules/talos-mcp-first.md` — Talos MCP usage policy

No `references/` subdir for this primitive: classification is pure parsing of `/proc/interrupts` columns plus bitmap math, with no static lookup table needed.

## Inputs

`$ARGUMENTS` (optional):
- `--node <name>` — limit audit to one node; default: all nodes via `resources_list`
- `--json` — emit JSON only, no human-readable summary; default: emit both
- `--save-baseline` — persist current per-node `metrics` to `tests/baselines/irq-affinity-auditor/<node>-<YYYY-MM-DD>.json`

## Scope Guard

Read-only diagnostic. The skill never writes to `/proc/irq/<n>/smp_affinity`, never executes `set_irqaffinity`, and never modifies cluster state. The generated rebalance snippet is emitted as text only — the operator decides if and when to apply it. Driver-level IRQ coalescing and queue tuning (RSS / RPS / XPS) are out of scope here; see Phase 1b ring-buffer-tuner (#100) for follow-up.

## Workflow

### 1. Resolve schema version (fail-closed)

Bash strict-mode-safe lookup:

```bash
CONTRACT_PATH="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || echo /nonexistent)}/docs/primitive-contract.md"
SCHEMA_VERSION=$(yq e '.schema_version' "$CONTRACT_PATH" 2>/dev/null) \
  || { jq -n --arg p "irq-affinity-auditor" '{primitive:$p,verdict:"PRECONDITION_NOT_MET",reason:"contract not readable",timestamp:now|todate}'; exit 0; }
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

### 3. Read /proc/interrupts per node

For each target node IP:
```
talos_read_file(path="/proc/interrupts", nodes=["<node-ip>"])
```

If the read fails for a node: mark that node `PRECONDITION_NOT_MET` in `results[]`, continue with others.

Parse line-by-line. Header line names the CPUs (e.g. `CPU0 CPU1 CPU2 ...`); record `cpu_count` from header column count. Each subsequent IRQ line has the form:
```
  <irq>: <count_cpu0> <count_cpu1> ... <count_cpuN>  <controller>  <type>  <name>
```

For each IRQ row, capture:
- `irq` — strip trailing colon; integer (skip non-numeric like `NMI`, `LOC`, `ERR`, `MIS`)
- `counts[]` — per-CPU interrupt counts (decimal integers)
- `name` — last whitespace-delimited field (or last 1–2 tokens for multi-token names like `mlx5_comp0`); used to classify NIC vs NVMe

### 4. Classify IRQs as NIC / NVMe / other

Use the trailing name field. NIC IRQs commonly match: `eth*`, `enp*`, `eno*`, `ens*`, `bond*`, `mlx*`, `i40e*`, `ixgbe*`, `ice*`, `igc*`, `r8169*`, `r8152*`, `e1000e*`, `iwlwifi*`, plus generic `<iface>-rx-N`, `<iface>-tx-N`, `<iface>-TxRx-N`. Cross-reference against the `/sys/class/net` interface set discovered earlier in the run if available; if not available, accept the prefix list above.

NVMe IRQs match: `nvme*` (typically `nvme0q0`, `nvme0q1`, … per submission/completion queue).

Anything else is `other` and not used for verdict classification (it still counts toward `irq_count_total`).

If NIC and NVMe sets are both empty after classification: emit `PRECONDITION_NOT_MET` for that node with reason `"no NIC or NVMe IRQs found in /proc/interrupts"`.

### 5. Compute CPU distribution

For every IRQ in `nic_irqs` ∪ `nvme_irqs`, find the CPU index with the highest count for that IRQ and record it as the IRQ's "primary CPU". Build `cpu_distribution: {0: N, 1: N, ...}` — count of NIC+NVMe IRQs whose primary CPU is each given CPU index. CPUs with zero are omitted.

Definitions:
- An IRQ is **pinned-to-cpu0** if its primary CPU is `0` AND counts on all other CPUs are zero.
- An IRQ's **primary CPU** is informational; the verdict uses `cpu_distribution` plus per-IRQ pinning.

### 6. Read smp_affinity bitmaps (NIC + NVMe only)

For each NIC and NVMe IRQ identified in step 4:
```
talos_list_files(path="/proc/irq", nodes=["<node-ip>"])    # once per node, to confirm IRQ dir presence
talos_read_file(path="/proc/irq/<n>/smp_affinity", nodes=["<node-ip>"])
```

Parse the hex bitmap (e.g. `00000001` = cpu0 only, `0000000f` = cpu0..3, `ffffffff` = any CPU). Record alongside the IRQ. If the file is missing or unreadable, record `affinity_mask: null` and add a finding `"irq=<n> smp_affinity unreadable"` (does not raise verdict by itself).

To minimise tool calls: if `nic_irqs` ∪ `nvme_irqs` exceeds 64 entries on a node, sample the first 64 and append a finding `"irq sampling capped at 64 — node has <N> NIC+NVMe IRQs"`. The verdict still classifies on the sampled set; cluster-wide imbalance signal remains intact at this scale.

### 7. Classify per-node verdict

Apply rules in this order; first match wins:

1. **CRITICAL — `pinned-to-cpu0`**: ALL NIC IRQs are pinned-to-cpu0, OR ALL NVMe IRQs are pinned-to-cpu0. Single-CPU concentration of an entire device class is a clear bottleneck.
2. **WARNING — `unbalanced`**: NIC IRQs span fewer than 2 CPUs (i.e. `len({primary_cpu for nic_irqs}) < 2`), OR NVMe IRQs span fewer than 2 CPUs, but rule 1 did not match (i.e. concentrated on a CPU other than cpu0, or only some IRQs pinned).
3. **HEALTHY — `balanced`**: Both NIC IRQs and NVMe IRQs span at least 2 distinct primary CPUs each.

Special case: if a node has only 1 CPU, no rebalance is possible — classify HEALTHY with a finding `"single-CPU node — IRQ rebalance not applicable"`.

Add findings:
- For rule 1: `"all <class> IRQs pinned to cpu0 (<N> IRQs)"`, where `<class>` is `NIC`, `NVMe`, or both.
- For rule 2: `"<class> IRQs concentrated on cpu<N> (<M>/<total>)"`.
- Always include the `set_irqaffinity` snippet finding when verdict is WARNING or CRITICAL — see step 8.

### 8. Generate set_irqaffinity rebalance snippet (verdict ≠ HEALTHY)

For nodes classified WARNING or CRITICAL, generate a multi-line `echo <bitmap> > /proc/irq/<n>/smp_affinity` snippet that round-robins each NIC and NVMe IRQ across the available CPUs. Algorithm:

```
cpu_count = <from /proc/interrupts header>
irqs = sort(nic_irqs + nvme_irqs)        # stable order: NIC first, then NVMe, ascending IRQ
for i, irq in enumerate(irqs):
    target_cpu = i % cpu_count
    mask_hex = printf("%08x", 1 << target_cpu)
    line = "echo " + mask_hex + " > /proc/irq/" + irq + "/smp_affinity"
```

Wrap as a single multi-line string and append to `findings[]`:
```
set_irqaffinity (apply manually — never auto-applied):
echo 00000001 > /proc/irq/24/smp_affinity
echo 00000002 > /proc/irq/25/smp_affinity
echo 00000004 > /proc/irq/26/smp_affinity
...
```

The snippet is text only. The skill must NOT write it to `/proc/irq/*` and must NOT shell out to apply it.

### 9. Emit JSON

Build canonical output:

```json
{
  "primitive": "irq-affinity-auditor",
  "version": "<SCHEMA_VERSION from §1>",
  "timestamp": "<ISO-8601 UTC>",
  "verdict": "<aggregate: worst per-node>",
  "shape": "per_node",
  "preconditions": {
    "required": ["talos_mcp", "proc_interrupts", "proc_irq_smp_affinity"],
    "met": true
  },
  "results": [
    {
      "node": "<name>",
      "verdict": "HEALTHY|WARNING|CRITICAL|PRECONDITION_NOT_MET",
      "metrics": {
        "irq_count_total": N,
        "cpu_count": N,
        "nic_irqs": [
          {"irq": 24, "name": "eth0-TxRx-0", "primary_cpu": 0, "affinity_mask": "00000001"}
        ],
        "nvme_irqs": [
          {"irq": 80, "name": "nvme0q1", "primary_cpu": 0, "affinity_mask": "00000001"}
        ],
        "cpu_distribution": {"0": 8, "1": 0, "2": 0, "3": 0}
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

Aggregate-verdict precedence: `CRITICAL > WARNING > HEALTHY > PRECONDITION_NOT_MET`. Top-level `verdict` is the worst per-node verdict.

### 10. Optional baseline persist

If `--save-baseline` is given: write the per-node `metrics` block (no verdict, no findings — just IRQ list, CPU distribution, affinity masks) to `tests/baselines/irq-affinity-auditor/<node>-<YYYY-MM-DD>.json`. Useful for spotting affinity drift across upgrades.

## Output

If `--json` only: emit the JSON to stdout. Done.

Else: emit the JSON, then a human-readable summary table:

```
| Node       | Verdict  | NIC | NVMe | CPU distribution | Findings                              |
|------------|----------|-----|------|------------------|---------------------------------------|
| node-01    | HEALTHY  |   8 |    4 | cpu0:3 cpu1:3 .. | -                                     |
| node-04    | WARNING  |   8 |    4 | cpu0:0 cpu2:12   | NIC+NVMe concentrated on cpu2         |
| node-pi-01 | CRITICAL |   2 |    0 | cpu0:2           | all NIC IRQs pinned to cpu0; snippet  |
```

CRITICAL nodes first, then WARNING, then HEALTHY.

## Hard Rules

- Read-only: never write to `/proc/irq/*`, never apply the generated `set_irqaffinity` snippet, never shell out to `taskset` or similar.
- Talos MCP `talos_read_file` / `talos_list_files` for all `/proc` access — never `talosctl read` CLI from this skill.
- Aggregate `verdict` is the worst per-node verdict.
- Never fabricate IRQ counts, primary CPUs, or affinity masks; if a read fails for a node, record `PRECONDITION_NOT_MET` for that node only and continue with others.
- Bash strict-mode (`set -euo pipefail`) compatible — see §1 yq lookup pattern.
- On Kubernetes MCP tool failure: retry once, then run the `# Fallback:` kubectl command from the same step. Record the fallback in the report. Applies to all `mcp__kubernetes-mcp-server__*` calls in this skill.
- The `set_irqaffinity` snippet is mandatory in `findings[]` for every node with verdict WARNING or CRITICAL — Issue-AC requirement.
