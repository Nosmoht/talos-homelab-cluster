---
name: talos-upgrade
description: Upgrade a single Talos node's OS image (version bump, extension changes, boot args) with drain, DRBD safety, and rollback support.
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
  - mcp__talos__talos_upgrade
  - mcp__talos__talos_rollback
  - mcp__kubernetes-mcp-server__resources_get
  - mcp__kubernetes-mcp-server__resources_list
---

# Talos Upgrade

## Environment Setup

Read `cluster.yaml` to load cluster-specific values (node IPs, kubeconfig path).
If the file is missing, tell the user: "Copy `cluster.yaml.example` to `cluster.yaml` and fill in your cluster details."

Use throughout this skill:
- `KUBECONFIG=<kubeconfig>` for all `kubectl` commands
- `-n <node-ip> -e <node-ip>` for all `talosctl` commands targeting a node

You are a Talos Linux operator upgrading a single node's OS image. Think step-by-step: resolve node, validate, check storage safety, confirm, drain, upgrade, verify, uncordon.

## Reference Files

Read before proceeding:
- `references/upgrade-operations-guide.md` — `--preserve`, drain/uncordon, rollback, etcd backup/quorum
- `.claude/rules/talos-mcp-first.md` — Safety checklist, hard rules, change classes

## Scope Guard

This skill handles **image/version/extension/boot-arg changes** for a single node.

If the user's change is config-only (sysctl, network patches), stop and redirect:
> This is a config-only change. Use `/talos-apply <node>` instead.

For planned multi-node version rollouts with an approved plan, redirect to `/execute-talos-upgrade`.

## Inputs

- Required argument: node name (`node-01`, `node-gpu-01`, etc.)
- Node definitions: `talos/nodes/<node>.yaml`

## Workflow

### 1. Resolve node metadata

Read `talos/Makefile` to map node name → IP, role (control-plane, worker, GPU worker, Pi worker), and install image.

### 2. Preflight (control-plane only)

If node is control-plane, take backups first:
```
# MCP — etcd snapshot to local file:
talos_etcd_snapshot(nodes=["<ip>"], path="/tmp/etcd-backup-YYYYMMDD.snapshot")

# CLI-only — config backup to file (no MCP equivalent):
talosctl get machineconfig -n <ip> -e <ip> -o yaml > /tmp/machineconfig-<node>-$(date +%Y%m%d).yaml
```

Verify etcd quorum:
```
talos_etcd(subcommand="status", nodes=["<ip>"])
# Fallback: talosctl etcd status -n <ip> -e <ip>
```
If quorum is degraded (fewer than (n/2)+1 members healthy), stop and report. Do not operate on a CP node with pre-existing quorum issues.

### 3. Validate schematics, generate, and dry-run

```bash
make -C talos validate-schematics
make -C talos gen-configs
```
If `validate-schematics` fails with MISMATCH, run `make -C talos schematics` first to regenerate IDs.
Where `<role>` is `controlplane` for CP nodes or `worker` for all others.

Then dry-run via MCP:
```
talos_apply_config(config_file="<abs-path>/talos/generated/<role>/<node>.yaml", dry_run=true, nodes=["<ip>"])
# Fallback (MCP unavailable): talosctl -n <ip> -e <ip> apply-config -f talos/generated/<role>/<node>.yaml --dry-run
```

If dry-run fails, stop and report the error with likely root cause.

Note: `talos_upgrade` has no dry-run mode ([siderolabs/talos#10804](https://github.com/siderolabs/talos/issues/10804)). The dry-run above validates config generation only.

### 4. DRBD/LINSTOR safety check

Check storage replica placement before draining:
```bash
KUBECONFIG=<kubeconfig> kubectl linstor volume list --nodes <node>
```

Verify all volumes on this node have at least one healthy replica on another node. If any volume has only one replica and it lives on this node, stop and report:
> Volume <name> has no replica on other nodes. Upgrading this node risks data unavailability. Resolve replica placement before proceeding.

### 5. User confirmation gate

Present the planned operation and wait for explicit approval:

```
## Upgrade Plan: <node>
- **Node:** <node> (<role>, <ip>)
- **Operation:** upgrade (OS image change)
- **Current image:** <from talosctl version output or Makefile>
- **Target image:** <from Makefile IMAGE variable>
- **Risk:** node will reboot
- **Rollback:** talosctl rollback -n <ip> -e <ip>

Proceed? (yes/no)
```

### 6. Drain

```bash
KUBECONFIG=<kubeconfig> kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --timeout=120s
```

The 120s timeout is critical — DRBD CSI volumes in D-state during `unmountPodMounts` can deadlock the upgrade with no API recovery if drain is skipped.

### 7. Upgrade

Resolve the install image from `talos/.schematic-ids.mk` + `talos/versions.mk`:
- Standard/CP nodes: `factory.talos.dev/metal-installer/<SCHEMATIC_ID>:<TALOS_VERSION>`
- GPU nodes: `factory.talos.dev/metal-installer/<GPU_SCHEMATIC_ID>:<TALOS_VERSION>`
- Pi nodes: `factory.talos.dev/metal-installer/<PI_SCHEMATIC_ID>:<TALOS_VERSION>`

```
# Apply config via MCP (dry_run must be false):
talos_apply_config(config_file="<abs-path>/talos/generated/<role>/<node>.yaml", dry_run=false, confirm=true, nodes=["<ip>"], mode="auto")
# Fallback: talosctl -n <ip> -e <ip> apply-config -f talos/generated/<role>/<node>.yaml

# Upgrade via MCP (fires and returns — no wait parameter):
talos_upgrade(nodes=["<ip>"], image="<install-image>", preserve=true, confirm=true)
# Fallback: talosctl upgrade -n <ip> -e <ip> --image <install-image> --preserve

# Then poll until node rejoins:
talos_health(nodes=["<ip>"])  # repeat until healthy
```

The `preserve=true` flag prevents EPHEMERAL partition wipe. `talos_upgrade` returns immediately — poll `talos_health` until the node is back.

### 8. Verify health

Wait for the node to come back, then verify:
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

If the node remains NotReady, check for pending CSR approval:
```
resources_list(apiVersion="certificates.k8s.io/v1", kind="CertificateSigningRequest")
# Check items[].status.conditions[].type == "Approved" and items[].status.conditions[].status == "True".
# Pending CSRs show no conditions or conditions with type=="Pending".
# Fallback: KUBECONFIG=<kubeconfig> kubectl get csr
```

### 9. Uncordon

Only after health verification passes:
```bash
KUBECONFIG=<kubeconfig> kubectl uncordon <node>
```

### 10. Post-upgrade DRBD verification

Confirm storage reconnection:
```bash
KUBECONFIG=<kubeconfig> kubectl linstor volume list --nodes <node>
```

All volumes should show `UpToDate` status.

### 11. Write maintenance report

Present the completed report to the user for review. After user confirmation, write `docs/talos-maintenance-<node>-<yyyy-mm-dd>.md`:

```markdown
# Talos Maintenance: <node> (<yyyy-mm-dd>)

## Change Summary
- **Node:** <node> (<role>, <ip>)
- **Operation:** upgrade
- **Previous image:** <previous>
- **New image:** <new>
- **Rationale:** <what changed and why>

## Commands Executed
1. `<command>` — <result>

## Verification Results
- talosctl version: <version confirmed>
- talosctl health: <healthy|issues>
- etcd status: <quorum intact|N/A for workers>
- kubectl get node: <Ready|NotReady>
- DRBD volumes: <UpToDate|issues>

## Recovery Notes
<any rollback actions taken, or "None — operation completed successfully">
```

## Hard Rules

- On Kubernetes MCP tool failure: retry once, then run the `# Fallback:` kubectl command from the same step. Applies to all `mcp__kubernetes-mcp-server__*` calls in this skill.
- Never edit `talos/generated/**` directly.
- Never use VIP for direct operations — always use explicit `-n <ip> -e <ip>`.
- Never operate on a CP node with degraded etcd quorum.
- Never skip drain on DRBD nodes — D-state deadlock requires physical power cycle.
- Ensure the Makefile `upgrade-<node>` target passes `--preserve`.
- Never conflate OS upgrade with `talosctl upgrade-k8s` (Kubernetes version upgrade).
- This skill does NOT do config-only applies — redirect to `/talos-apply`.
