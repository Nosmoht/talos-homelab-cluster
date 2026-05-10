---
schema_version: "1.0.0-draft"
applies_to: [skills]
status: draft
phase: 1a
---

# Primitive Output Contract — Phase 1a

This document defines the shared contract for `area: claude-harness` Phase-1a foundation primitives (Issues #98, #108, #110, #111). All Phase-1a primitives emit JSON conforming to the schema in §B3 and follow the frontmatter spec in §B2.

Phase 1b (#100 ring-buffer-tuner, #102 network-latency-matrix, #105 fio-node-benchmark, #107 mtu-path-verifier) extends this contract with ephemeral-pod sections — added when Phase 1b is planned. Phase 1b prerequisites are listed at the end of this document for reference.

## B1. Schema Version (single source of truth)

The `schema_version` field in this file's YAML frontmatter is the canonical source. Skills look it up at runtime, fail-closed:

```bash
CONTRACT_PATH="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || echo /nonexistent)}/docs/primitive-contract.md"
SCHEMA_VERSION=$(yq e '.schema_version' "$CONTRACT_PATH" 2>/dev/null) \
  || { jq -n --arg p "<primitive-name>" '{primitive:$p,verdict:"PRECONDITION_NOT_MET",reason:"contract not readable",timestamp:now|todate}'; exit 0; }
[ -z "$SCHEMA_VERSION" ] && SCHEMA_VERSION="unknown"
```

Robustness:
- `git rev-parse 2>/dev/null` + `echo /nonexistent` fallback prevents exit-non-zero under bash strict mode (`set -euo pipefail`)
- yq read failure (file missing OR malformed YAML) collapses to PRECONDITION_NOT_MET — fail-closed by design

Bump from `1.0.0-draft` to `1.0.0` only after the Phase-5 composite (#113 node-health-snapshot) consumes the schemas without errors. SemVer thereafter; minor for additive shape fields, major for breaking changes to required keys.

## B2. Frontmatter Spec for Skills (Phase 1a)

```yaml
---
name: <primitive-name>            # lowercase-hyphens, must match directory name
description: <≤300 chars>
disable-model-invocation: true    # Manual-only — Phase-1a Diagnostics convention
argument-hint: "[--node <name>] [--baseline <path>] [--json] [--save-baseline]"
allowed-tools:                    # ENUMERATED — wildcards not supported
  - mcp__talos__talos_read_file
  - mcp__talos__talos_list_files       # if needed for sysfs/proc directory listing
  - mcp__kubernetes-mcp-server__resources_list
  - Bash
  - Read
  - Write
model: inherit
---
```

Per-skill `allowed-tools` is the union of generic (Bash/Read/Write) plus the primitive-specific MCP tools listed in §B5.

## B3. JSON Output Schema (canonical, shape=per_node)

All Phase-1a primitives emit `shape: per_node` — one verdict per node. Pair- and target-shapes are reserved for Phase 1b.

```json
{
  "primitive": "<primitive-name>",
  "version": "<schema_version from §B1>",
  "timestamp": "<ISO-8601 UTC>",
  "verdict": "HEALTHY|WARNING|CRITICAL|PRECONDITION_NOT_MET",
  "shape": "per_node",
  "preconditions": {
    "required": ["<capability>", "..."],
    "met": true
  },
  "results": [
    {
      "node": "<node-name>",
      "verdict": "HEALTHY|WARNING|CRITICAL|PRECONDITION_NOT_MET",
      "metrics": { /* primitive-specific */ },
      "findings": [/* string list, may be empty */]
    }
  ],
  "summary": {
    "healthy": <int>,
    "warning": <int>,
    "critical": <int>
  }
}
```

Aggregate-verdict precedence: `CRITICAL > WARNING > HEALTHY > PRECONDITION_NOT_MET`. The top-level `verdict` is the worst per-node verdict.

If preconditions are unmet (contract unreadable, sysfs path missing, no nodes discovered), emit a top-level `verdict: PRECONDITION_NOT_MET`, empty `results: []`, and `preconditions.met: false`. The skill exits 0 — the PRECONDITION_NOT_MET verdict is information, not a process error.

### Primitive-specific extensions

Primitives MAY extend the schema with additional keys when the extension carries audit-grade information that downstream consumers (Phase-5 composite #113) need to differentiate severity classes or audit dimensions. Two extension points exist:

- **Per-result extensions** — added on each `results[].*` entry. Example: `kernel-param-auditor` adds `role: "cp|worker|storage|gpu"` so the composite can group findings by node-role.
- **Per-metric extensions** — added on each `results[].metrics.<key>` entry. Example: `kernel-param-auditor` adds `layer: "1|2|3"` (Universal / OS-vendor / cluster-tuning) plus a top-level `summary.by_layer.{1,2,3}.{healthy,warning,critical}` rollup. See `.claude/skills/kernel-param-auditor/references/role-baselines.md` for the layer definitions.

**Forward-compat clause**: downstream consumers MUST tolerate unknown extension keys (do not fail on them). When adding an extension, document it in the primitive's `SKILL.md` §Hard Rules so the contract is discoverable.

## B4. Auto-Discovery + Portability + Baselines

**Auto-Discovery**: Node list via `resources_list(apiVersion="v1", kind="Node")`. Extract internal IPs from `items[].status.addresses[?type=="InternalIP"].address`; map IP → `items[].metadata.name`. Phase-1a primitives target ALL nodes including taint-isolated nodes (e.g. `node-pi-01`) — Talos MCP `talos_read_file` does not require pod-schedulability, so the `homelab.io/pi-reserved=true:NoSchedule` taint is irrelevant.

**Portability** (5 don'ts that apply Phase-1a-wide):
1. No hardware-hardcoded values (interface names, NIC vendor strings) — discover via probe
2. No `talosctl` CLI calls inside the SKILL — Talos MCP only (per `.claude/rules/talos-mcp-first.md`)
3. No LINSTOR/DRBD/Piraeus assumptions
4. No SG3428/SNMP/router-vendor assumptions
5. Baselines git-tracked under `tests/baselines/`; no Node annotation or ConfigMap dependency

**Baselines**: `tests/baselines/<primitive>/<node>-<YYYY-MM-DD>.json`. Per-node, per-day file. Persistent under git for trend analysis across upgrades. Baseline write opt-in via `--save-baseline` flag.

## B5. Per-Primitive Mechanism + allowed-tools

| Primitive | Mechanism | `allowed-tools` (in addition to `Bash`, `Read`, `Write`) |
|---|---|---|
| **#98 nic-health-audit** | `talos_read_file /sys/class/net/<iface>/statistics/{rx_*,tx_*,collisions,carrier_changes}` + `talos_list_files /sys/class/net` | `mcp__talos__talos_read_file`, `mcp__talos__talos_list_files`, `mcp__kubernetes-mcp-server__resources_list` |
| **#108 link-flap-detector** | `talos_dmesg` (filter `link is down\|link is up\|carrier`) + `talos_read_file /sys/class/net/<iface>/carrier_changes` | `mcp__talos__talos_dmesg`, `mcp__talos__talos_read_file`, `mcp__talos__talos_list_files`, `mcp__kubernetes-mcp-server__resources_list` |
| **#110 irq-affinity-auditor** | `talos_read_file /proc/interrupts` + `/proc/irq/<n>/smp_affinity`. SKILL emits `set_irqaffinity` shell snippet per node as a `findings[]` string (Issue-AC: "Generated script written to stdout, never auto-applied") | `mcp__talos__talos_read_file`, `mcp__talos__talos_list_files`, `mcp__kubernetes-mcp-server__resources_list` |
| **#111 kernel-param-auditor** | `talos_read_file /proc/sys/<key>` per parameter from `references/role-baselines.md` | `mcp__talos__talos_read_file`, `mcp__kubernetes-mcp-server__resources_list` |

All listed paths are within `TALOS_MCP_ALLOWED_PATHS` (`/proc,/sys,/var/log,/run,/usr/local/etc,/etc/os-release` — verified per repo memory `feedback_talos_mcp_allowed_paths`).

## Conformance Sweep — Frontmatter Validation

SKILL.md files use `---` front-matter delimiters and a Markdown body. `yq e file.md` does NOT parse the frontmatter directly because the body is not YAML. Use `awk` to extract the frontmatter block first:

```bash
awk '/^---$/{n++; next} n==1' .claude/skills/<name>/SKILL.md \
  | yq e -e '.name and .description and .["disable-model-invocation"] == true' -
```

Layer-1 (frontmatter parses) and Layer-2 (`schema_version` match against this file) validation runs in CI via `.github/workflows/skill-frontmatter-check.yml`. Layer-3 (live dispatch smoke against an idle worker) stays manual — interactive Skill dispatch is not headless.

Smoke-Pass criterion per skill: dispatch against ≥ 1 idle worker yields valid JSON that satisfies all of:
- `jq -e '.primitive,.version,.verdict' >/dev/null`
- `jq -e '.shape == "per_node"' >/dev/null`
- `jq -e '.results | type == "array" and length > 0' >/dev/null`
- `jq -e '.results[] | .node and .verdict' >/dev/null`

## Phase 1b Prerequisites (out of scope here, listed for context)

Issues #100, #102, #105, #107 require ephemeral-pod orchestration. Before they can be implemented:
- New namespace `claude-harness-jobs` with ArgoCD-managed lifecycle
- New PNI capability `host-net-diagnostic`: Kyverno-allowlist update at `kubernetes/base/infrastructure/platform-network-interface/resources/kyverno-clusterpolicy-pni-capability-validation-enforce.yaml` + Cilium-CCNP under PNI provider side
- ServiceAccount `claude-harness-runner` + RoleBinding scoped to namespace (verbs: pods.create/get/list/delete, pods/exec, pods/log)
- Image pinning by sha256 digest: ethtool image (alpine + apk-installed ethtool), iperf3 image (`networkstatic/iperf3` candidate), fio image (maintained alternative — `clusterhq/fio-tools` is dead)
- Cleanup contract: pre-run idempotent label-selector delete, during-run trap-EXIT cleanup, post-run delete, backup janitor CronJob
- ADR documenting the privileged-profile usage rationale for internal diagnostics tooling

These sections will be appended to this document when Phase 1b is planned.
