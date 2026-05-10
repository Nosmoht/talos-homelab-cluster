---
paths:
  - "talos/**"
  - "docs/day0-setup.md"
  - "docs/day2-operations.md"
---

# Talos MCP-vs-CLI Tool Policy

This file is scoped narrowly to **MCP-vs-CLI tool selection and parameter defaults for the Talos MCP server** — token-efficient operations guidance for the agent. For Talos config generation, lifecycle gotchas, node recovery, and Talos API behaviour, see the cross-references at the bottom of this file.

## Policy Statement

Use Talos MCP tools for all supported operations. Fall back to `talosctl` CLI only for operations with no MCP equivalent (see CLI-Only table below).

When a MCP tool fails: retry once, then fall back to CLI for the remainder of the session and log the fallback.

**Skill CLI-only exceptions:** Skills may use `talosctl get machineconfig -o yaml > <file>` for config backup to file, `talosctl upgrade-k8s` (no MCP equivalent), and bulk `/proc`/`/sys` reads in `analyze-node-hardware`. Planning skills (`plan-*`) may use `talosctl apply-config --dry-run` for validation only (B2: planning skills must not have mutating MCP tools). All other Talos operations must use MCP tools.

## MCP Tool Mapping

### MCP-First (always prefer these)

| Operation | MCP Tool | Notes |
|---|---|---|
| Version info | `talos_version` | |
| Cluster health | `talos_health` | `control_plane_nodes`/`worker_nodes` params for override |
| Get resources | `talos_get` | Use `resource_type` param |
| List services | `talos_services` | |
| Etcd members/status | `talos_etcd` | |
| Service logs | `talos_logs` | |
| Kernel dmesg | `talos_dmesg` | |
| Containers | `talos_containers` | |
| Processes | `talos_processes` | |
| List filesystem | `talos_list_files` | |
| Read file | `talos_read_file` | |
| Events | `talos_events` | |
| Resource definitions | `talos_resource_definitions` | |
| Validate config (offline) | `talos_validate` | mode=metal (default), strict=false |
| Patch config | `talos_patch_config` | dry_run=true by default |
| Apply full config | `talos_apply_config` | dry_run=true by default; **always set dry_run explicitly** |
| Service action | `talos_service_action` | `talos_service_action(etcd, restart)` NOT supported (Talos API restriction) |
| OS Upgrade | `talos_upgrade` | **Always set `preserve=true` explicitly** — never rely on default |
| Rollback | `talos_rollback` | |
| Reboot | `talos_reboot` | **Always set `wait=true` and `timeout` explicitly** — never rely on defaults |
| Etcd snapshot | `talos_etcd_snapshot` | Requires exactly one CP node |
| Factory reset | `talos_reset` | IRREVERSIBLE — requires `confirm=true` + explicit `nodes`; never use in autonomous agents |

### CLI-Only (no safe MCP equivalent)

| Operation | CLI Command | Reason |
|---|---|---|
| Upgrade Kubernetes | `talosctl upgrade-k8s --to <ver> -n <ip> -e <ip>` | No MCP equivalent — FR #30 open |
| Config backup to file | `talosctl get mc -o yaml > /tmp/file` | MCP returns data in conversation context, not to file |
| Client version | `talosctl version --client` | MCP queries remote nodes only |

## Decision Flow

```
Need a Talos operation?
  → Is there a MCP tool for it? (see table above)
      YES → Use MCP tool
      NO  → Use talosctl CLI (CLI-Only list)
  → MCP tool fails?
      Retry once → still fails → CLI fallback for session, log it
```

## Critical Parameter Rules

These parameters must **always** be specified explicitly — never rely on defaults:

- `talos_upgrade`: set `preserve=true` (protects DRBD/LINSTOR EPHEMERAL partition from wipe)
- `talos_reboot`: set `wait=true` and `timeout` (ensures agent blocks until node is back)
- `talos_apply_config`: set `dry_run` explicitly (default is true, but always be explicit)
- `talos_reset`: requires `confirm=true` and explicit `nodes` array

## Apply-Config Gotchas

- **Patches that add new `interfaces:` entries: apply with `dry_run=false` directly.** Before applying, read the live `MachineConfig` via `talos_get type=MachineConfig`. If the target `interface:` name is absent from the live config, skip dry-run — `talos_apply_config dry_run=true` panics with `panic: runtime error: index out of range [N] with length N` when the patch introduces an interface entry that the diff engine has no existing object to diff against. The panic is a Talos diff-engine bug, not a config error; the real apply (`dry_run=false`) succeeds cleanly. If the target interface already exists in the live config, `dry_run=true` is safe and preferred.
- **Do not target the API VIP for `dry_run` / `apply` operations on degraded clusters.** VIP forwarding is unreliable for these operations when the cluster is degraded. Use the explicit per-node endpoint pattern (`-n <node-ip> -e <node-ip>` for CLI fallback, or the `nodes` parameter for MCP tools). The endpoint syntax itself is documented in `.claude/rules/talos-nodes.md` §Node Endpoint Usage.

## Known Restrictions

- `talos_service_action(service=etcd, action=restart)` — NOT supported via Talos API. `talosctl service etcd restart` is also unsupported; etcd restarts require node reboot.
- `talos_reset` — excluded from autonomous agent `allowed-tools` due to irreversibility.

## Cross-References

This file is intentionally narrow. Related operational content lives in domain-specific rule files:

- Talos config generation, patches, Makefile, change classes, safety checklist, node recovery, API behaviour → `.claude/rules/talos-config.md`
- Talos node inventory, endpoint syntax, per-node patches → `.claude/rules/talos-nodes.md`
- Talos Image Factory schematics, schematic ID drift → `.claude/rules/talos-image-factory.md`
- DRBD D-state recovery, LINSTOR-specific node-recovery — `.claude/rules/linstor-storage-guardrails.md`
- Cilium bootstrap via Talos `extraManifests` (Hubble cert-gen Job blocker, ConfigMap update gotcha) → `.claude/rules/cilium-bootstrap.md`
- Cluster-wide hard constraints (no SecureBoot, no `debugfs=off`, etc.) → `AGENTS.md` §Hard Constraints (single source of truth)
