# Claude Code Guide

This repository ships with built-in Claude Code skills, delegation agents, and context rules. Start a Claude Code session in the repo root and all capabilities load automatically.

> **Note:** `docs/claude-code-stack-audit.md` is the internal audit log for the Claude Code stack, not a user-facing guide.

## Skills (Slash Commands)

### Upgrade Planning and Execution

| Command | Description |
|---------|-------------|
| `/plan-talos-upgrade [from] [to]` | Build a migration plan with release notes, breaking changes, and cluster-specific risks |
| `/execute-talos-upgrade <plan-path>` | Gated node-by-node Talos rollout from an approved plan |
| `/plan-cilium-upgrade [from] [to]` | Build a Cilium migration plan with breaking-change analysis |
| `/execute-cilium-upgrade <plan-path>` | Execute a reviewed Cilium upgrade with health gates and recovery actions |

### Daily Operations

| Command | Description |
|---------|-------------|
| `/gitops-health-triage [app\|all]` | Triage ArgoCD sync/health drift and produce a remediation plan |
| `/talos-apply <node>` | Apply config changes (sysctl, network, patches) to a single node with dry-run and verification |
| `/talos-upgrade <node>` | Upgrade a single node's OS image with drain, DRBD safety, and rollback support |
| `/cilium-policy-debug [namespace/app]` | Diagnose traffic drops, map to CiliumNetworkPolicy manifests, propose least-privilege fixes |

### Hardware and Tuning

| Command | Description |
|---------|-------------|
| `/analyze-node-hardware <node>` | Produce a hardware profile via talosctl and NFD |
| `/update-schematics <node\|all>` | Update Talos Image Factory schematics with recommended extensions |
| `/optimize-node-kernel <node>` | Research and apply kernel parameters for specific hardware (requires hardware analysis first) |

## Delegation Agents

Agents are invoked automatically by Claude Code when a task matches their specialty. You do not call these directly.

| Agent | Specialty |
|-------|-----------|
| `gitops-operator` | ArgoCD reconciliation failures, app-of-apps drift, safe rollout planning |
| `talos-sre` | Node config generation, apply/upgrade safety, control-plane stability |
| `platform-reliability-reviewer` | Pre-merge review (default) or pre-operation risk assessment (prefix with "pre-operation:") |
| `researcher` | Upgrade compatibility research, CVE assessment, component evaluation via web search |

### Platform Reliability Reviewer: Two Modes

The `platform-reliability-reviewer` agent supports two operating modes:

- **Pre-Merge Review (default):** Review diffs for regressions, policy gaps, and unsafe rollouts before merging. Output: BLOCKING/WARNING/INFO findings with severity.
- **Pre-Operation Review:** Invoke with `"pre-operation: <change description>"` for adversarial risk assessment before disruptive operations. Output: Risk Matrix, rollback analysis, recovery gaps, Go/No-Go verdict.

### Researcher Agent

The `researcher` agent performs structured web research for infrastructure decisions. It is automatically spawned by `/plan-talos-upgrade` and `/plan-cilium-upgrade` skills (Step 1.5). It can also be invoked directly for ad-hoc research:

```
@researcher "Evaluate KubeVirt vs Kata Containers for VM workloads on Talos Linux"
```

Output: Sources with URLs, Findings with citations, Cluster-Specific Impact, Confidence levels.

## Auto-Loaded Context Rules

Rules activate automatically based on the files being discussed. No user action needed.

| Rule | Purpose |
|------|---------|
| `talos-config` | Machine config generation, patch ordering, boot-critical configuration |
| `talos-nodes` | Node hardware profiles, IP assignments, node-specific config binding |
| `talos-image-factory` | Image Factory schematic management, extension selection, boot images |
| `talos-mcp-first` | Talos operations, lifecycle, gotchas (MCP-first) — see AGENTS.md §Domain Rules for canonical rule list |
| `argocd-structure` | Kustomize patterns, ArgoCD sync practices, GitOps-first workflow |
| `argocd-troubleshooting` | Safe sync patterns, app-of-apps orchestration, operational gotchas |
| `cilium-gateway-api` | Gateway API ingress, network policy patterns, L2 announcements |
| `manifest-quality` | Manifest validation, labeling standards, resource health checks |

## MCP Servers

Two MCP servers provide live cluster and GitHub access during Claude Code sessions:

| Server | Provides |
|--------|----------|
| `github` | PR, issue, and workflow interaction via `gh mcp-server` |
| `kubernetes` | Structured cluster reads/writes via `kubectl-mcp-server` |

Setup instructions: [`.claude/mcp/SETUP.md`](../.claude/mcp/SETUP.md)

## Typical Workflows

### Upgrade Talos

1. `/plan-talos-upgrade` — automatically researches breaking changes (spawns `researcher` agent), builds plan, and stress-tests it via adversarial risk assessment
2. Review the plan, mark as approved
3. `/execute-talos-upgrade docs/talos-upgrade-plan-<from>-to-<to>-<date>.md`

### Upgrade Cilium

1. `/plan-cilium-upgrade` — automatically researches eBPF/Gateway API changes (spawns `researcher` agent), builds plan, and stress-tests it with Cilium-specific risk assessment
2. Review the plan, mark as approved
3. `/execute-cilium-upgrade docs/cilium-upgrade-plan-<from>-to-<to>-<date>.md`

### Pre-operation risk assessment

Before any disruptive change (upgrade, storage migration, network topology change):
```
@platform-reliability-reviewer "pre-operation: Migrate DRBD volumes from node-04 to node-05"
```

### Diagnose a broken ArgoCD app

1. `/gitops-health-triage monitoring` (or `all` for everything)
2. Follow the remediation steps in the output

### Debug connectivity issues

1. `/cilium-policy-debug <namespace/app>`
2. Apply the proposed CNP changes via GitOps

### Onboard or retune a node

1. `/analyze-node-hardware <node>` — hardware profile
2. `/update-schematics <node>` — match extensions to hardware
3. `/optimize-node-kernel <node>` — kernel parameter tuning
4. `/talos-apply <node>` — apply config changes safely
