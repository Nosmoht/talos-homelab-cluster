# Talos Scope — Codex CLI Context
# Root scope: @../AGENTS.md (inherits §Hard Constraints, §Session Ritual, §MCP servers)

This file is loaded by Codex CLI when editing files under `talos/`. It provides
path-scoped context approximating Claude Code's `paths:` auto-loading. Read the
linked rule files before editing in the listed contexts.

## Directory Map

| Path | Purpose |
|------|---------|
| `talos/patches/` | Talos machine config patches (common, controlplane, worker, per-node) |
| `talos/nodes/` | Node-specific config inputs |
| `talos/generated/` | **Generated output** — never hand-edit; regenerate with `make -C talos gen-configs` |
| `talos/versions.mk` | Pinned versions (Talos, Kubernetes, Cilium, extensions) |
| `talos/*.schematic-ids.mk` | Image Factory schematic IDs per node class |
| `talos/Makefile` | Lifecycle targets: gen-configs, apply-*, dry-run-*, upgrade-k8s, schematics |

## Domain Rules by Edit Context

Before editing, read the applicable rule file:

| Context | Rule file |
|---------|-----------|
| Machine config patches, `talconfig.yaml` | `.claude/rules/talos-config.md` |
| Image Factory schematics, system extensions | `.claude/rules/talos-image-factory.md` |
| `talosctl` operations, lifecycle, gotchas (MCP-first) | `.claude/rules/talos-mcp-first.md` |
| Node IPs, endpoint flags, inventory | `.claude/rules/talos-nodes.md` |

## Patch Ordering

Patches apply in this order: `common` → `controlplane|worker` → `<node-name>`. More-specific patches override less-specific. Never edit files in `talos/generated/` — regenerate them.

## Pre-Drain Safety Checklist (inline — full gate in `.claude/hooks/pre-drain-check.sh`)

Before `talosctl` drain or `kubectl drain` on any node:
1. Confirm DRBD primary for all volumes is NOT on the node being drained
2. `kubectl get pdb -A` — verify no PodDisruptionBudget blocks eviction
3. `kubectl get pods -A --field-selector=status.phase!=Running` — no stuck pods
4. Check cluster health: `talosctl -n <cp-ip> -e <cp-ip> health`
5. For GPU node: confirm no active GPU workloads (check `nvidia.com/gpu` resource allocations)

## Hard Constraints (inline summary — canonical in `../AGENTS.md §Hard Constraints`)

- **No `metal-installer-secureboot`** — use `metal-installer` (SecureBoot causes boot loops)
- **No `debugfs=off`** kernel boot param — causes "failed to create root filesystem"
- **Talos MCP-first**: use MCP tools (`talos_health`, `talos_get`, etc.) over raw `talosctl` for supported operations. CLI-only exceptions: `upgrade-k8s`, `config backup to file`, `client version`.
- **Always use explicit endpoint flags**: `talosctl -n <node-ip> -e <node-ip>` (never implicit)
- **Apply configs BEFORE `upgrade-k8s`**: `upgrade-k8s` reads extraManifests URLs from the LIVE node config

## Makefile Targets

```
make -C talos gen-configs       # Regenerate all node configs
make -C talos apply-<node>      # Apply config to a single node
make -C talos dry-run-all       # Validate config without applying
make -C talos upgrade-k8s       # Upgrade Kubernetes (reconciles extraManifests)
make -C talos schematics        # Create/update Image Factory schematic IDs
```
