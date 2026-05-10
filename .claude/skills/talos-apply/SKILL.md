---
name: talos-apply
description: Apply Talos config changes (sysctl, network, patches) to a single node with dry-run validation and health verification.
argument-hint: <node-name>
disable-model-invocation: true
allowed-tools:
  - Bash
  - Read
  - Grep
  - Glob
  - Write
  - mcp__talos__talos_apply_config
  - mcp__talos__talos_version
  - mcp__talos__talos_health
  - mcp__talos__talos_etcd
  - mcp__talos__talos_etcd_snapshot
  - mcp__kubernetes-mcp-server__resources_get
---

# Talos Apply

## Environment Setup

Read `cluster.yaml` to load cluster-specific values (node IPs, kubeconfig path).
If the file is missing, tell the user: "Copy `cluster.yaml.example` to `cluster.yaml` and fill in your cluster details."

Use throughout this skill:
- `KUBECONFIG=<kubeconfig>` for all `kubectl` commands
- `-n <node-ip> -e <node-ip>` for all `talosctl` commands targeting a node

You are a Talos Linux operator applying configuration changes to a single node. Think step-by-step: resolve node, validate, confirm, apply, verify.

## Reference Files

Read before proceeding:
- `references/apply-operations-guide.md` — Apply modes, etcd backup, quorum checks
- `.claude/rules/talos-mcp-first.md` — Safety checklist, hard rules, change classes

## Scope Guard

This skill handles **config-only changes**: sysctl, network patches, machine config fields.

If the user's change involves image version, boot args, or extensions, stop and redirect:
> This change requires an OS image upgrade. Use `/talos-upgrade <node>` instead.

For planned multi-node rollouts, redirect to `/execute-talos-upgrade`.

## Inputs

- Required argument: node name (`node-01`, `node-gpu-01`, etc.)
- Node definitions: `talos/nodes/<node>.yaml`

## Workflow

### 1. Resolve node metadata

Read `talos/Makefile` to map node name → IP and role (control-plane, worker, GPU worker, Pi worker).

### 2. Preflight (control-plane only)

If node is control-plane, take backups first:
```
# MCP — etcd snapshot to local file:
talos_etcd_snapshot(nodes=[<ip>], path="/tmp/etcd-backup-YYYYMMDD.snapshot")

# CLI-only — config backup to file (no MCP equivalent):
talosctl get machineconfig -n <ip> -e <ip> -o yaml > /tmp/machineconfig-<node>-YYYYMMDD.yaml
```

Verify etcd quorum:
```
talos_etcd(subcommand="status", nodes=[<ip>])
# Fallback: talosctl etcd status -n <ip> -e <ip>
```
If quorum is degraded (fewer than (n/2)+1 members healthy), stop and report. Do not operate on a CP node with pre-existing quorum issues.

### 3. Generate and dry-run

```bash
make -C talos gen-configs
```
Where `<role>` is `controlplane` for CP nodes or `worker` for all others.

Then dry-run via MCP:
```
talos_apply_config(config_file="<abs-path>/talos/generated/<role>/<node>.yaml", dry_run=true, nodes=["<ip>"])
# Fallback (MCP unavailable): talosctl -n <ip> -e <ip> apply-config -f talos/generated/<role>/<node>.yaml --dry-run
```

If dry-run fails, stop and report the error with likely root cause.

### 4. Show config diff

The dry-run output from step 3 shows the diff.

Present the diff to the user.

### 5. User confirmation gate

Present the planned operation and wait for explicit approval:

```
## Apply Plan: <node>
- **Node:** <node> (<role>, <ip>)
- **Operation:** apply (config change)
- **Mode:** auto (default) | staged | no-reboot
- **What changed:** <summary from diff>
- **Risk:** <reboot possible if mode=auto and config requires it>
- **Rollback:** re-apply previous config

Proceed? (yes/no)
```

### 6. Apply

After user confirms, apply via MCP (note: `dry_run` defaults to `true` — must be explicitly `false`):
```
talos_apply_config(config_file="<abs-path>/talos/generated/<role>/<node>.yaml", dry_run=false, confirm=true, nodes=["<ip>"], mode="auto")
# Fallback (MCP unavailable): talosctl -n <ip> -e <ip> apply-config -f talos/generated/<role>/<node>.yaml
```

For other modes pass `mode` parameter:
- CP under load: `mode="staged"`
- Safe probe: `mode="no_reboot"`

### 7. Verify health

```
talos_version(nodes=["<ip>"])
talos_health(nodes=["<ip>"])
# Fallback: talosctl -n <ip> -e <ip> version && talosctl -n <ip> -e <ip> health
```

For control-plane nodes, also verify etcd:
```
talos_etcd(subcommand="members", nodes=["<ip>"])
talos_etcd(subcommand="status", nodes=["<ip>"])
# Fallback: talosctl etcd members -n <ip> -e <ip> && talosctl etcd status -n <ip> -e <ip>
```
Confirm all members show `started` before declaring success.

Then confirm node readiness:
```
resources_get(apiVersion="v1", kind="Node", name="<node>")
# Check .status.conditions[] — find type=="Ready", verify status=="True".
# Fallback: KUBECONFIG=<kubeconfig> kubectl get node <node>
```

### 8. Write maintenance report

Present the completed report to the user for review. After user confirmation, write `docs/talos-maintenance-<node>-<yyyy-mm-dd>.md`:

```markdown
# Talos Maintenance: <node> (<yyyy-mm-dd>)

## Change Summary
- **Node:** <node> (<role>, <ip>)
- **Operation:** apply
- **Mode:** auto | staged | no-reboot
- **Rationale:** <what changed and why>

## Commands Executed
1. `<command>` — <result>

## Verification Results
- talosctl version: <version confirmed>
- talosctl health: <healthy|issues>
- etcd status: <quorum intact|N/A for workers>
- kubectl get node: <Ready|NotReady>

## Recovery Notes
<any issues encountered, or "None — operation completed successfully">
```

## Hard Rules

- Never edit `talos/generated/**` directly.
- Never use VIP for direct operations — always use explicit `-n <ip> -e <ip>`.
- Never operate on a CP node with degraded etcd quorum.
- This skill does NOT do upgrades — redirect to `/talos-upgrade`.
