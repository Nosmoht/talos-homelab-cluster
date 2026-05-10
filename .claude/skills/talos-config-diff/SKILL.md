---
name: talos-config-diff
description: Diff live Talos node configs against repo-rendered configs before applying. Classifies each change as reboot-required, reload-only, or no-op.
argument-hint: "[node-name|all]"
disable-model-invocation: true
allowed-tools:
  - Bash
  - Read
  - Glob
  - mcp__talos__talos_get
---

# Talos Config Diff

## Environment Setup

Read `cluster.yaml` to load cluster-specific values (node IPs, kubeconfig path).
If the file is missing, tell the user: "Copy `cluster.yaml.example` to `cluster.yaml` and fill in your cluster details."

Use `-n <node-ip> -e <node-ip>` for all `talosctl` commands.

## Purpose

This skill answers "what would actually change?" before running `/talos-apply` or `make -C talos apply-*`.
It surfaces per-node diffs and classifies each change so you can confirm risk before committing.

Use this skill:
- Before any planned config rollout
- When verifying that generated configs match current cluster state
- After editing `talos/patches/` or `talos/nodes/` to understand impact

## Reference Files

Read before proceeding:
- `.claude/rules/talos-mcp-first.md` — change classes (reboot/reload/none), Apply-Config Gotchas
- `talos/versions.mk` — current Talos/Kubernetes version pins

## Inputs

- Argument: node name (`node-01`, `node-gpu-01`, etc.) or `all` (default: `all`)
- Node inventory: `talos/nodes/*.yaml`
- Role mapping: read `talos/Makefile` to map node → role (`controlplane` or `worker`)

## Workflow

### 1. Resolve target nodes

If argument is a specific node name, process only that node.
If argument is `all` or omitted, process all nodes from `talos/nodes/*.yaml`:

```bash
ls talos/nodes/*.yaml
```

For each node file, read it to extract:
- Node name (filename without `.yaml`)
- IP address (look for `machine.network.interfaces` or similar)

Use `talos/Makefile` to confirm per-node role and IP:
```bash
grep -A2 'node-01\|NODE_01\|IP' talos/Makefile | head -30
```

### 2. Render new configs

Regenerate configs from current patches:
```bash
make -C talos gen-configs
```

Generated outputs land at:
- `talos/generated/controlplane/<node>.yaml` for CP nodes
- `talos/generated/worker/<node>.yaml` for worker nodes

If `gen-configs` fails (SOPS decryption required, etc.), stop and report the error.

### 3. Fetch live config per node

For each target node, fetch the current live MachineConfig:

```
talos_get(resource_type="MachineConfig", nodes=["<ip>"])
# Fallback: talosctl get machineconfig -n <ip> -e <ip> -o yaml
```

Extract the `spec` section from the response (the actual config body). The COSI resource envelope
(metadata, typeMeta) must be stripped before diffing — only the `spec` body matches the format of
`talos/generated/<role>/<node>.yaml`.

```bash
# Via CLI fallback — pipe through yq to extract spec body only:
talosctl get machineconfig -n <ip> -e <ip> -o yaml | yq '.spec' > /tmp/live-<node>.yaml
```

Note: The live config returned by Talos is the *merged* running config (base + patches applied),
not the raw input patches. The diff is against the would-be-applied rendered config.

### 4. Diff per node

```bash
diff -u /tmp/live-<node>.yaml talos/generated/<role>/<node>.yaml
```

For multiple nodes, iterate:
```bash
for node in <node-list>; do
  echo "=== $node ==="
  diff -u /tmp/live-$node.yaml talos/generated/<role>/$node.yaml || true
done
```

If diff is empty for a node → **no-op** (configs are in sync).

### 5. Classify each change

For each non-empty diff, analyze the changed fields against the change classes from
`.claude/rules/talos-mcp-first.md`:

| Changed section | Change class | Notes |
|----------------|--------------|-------|
| `machine.sysctls` | reload-only | Sysctl apply without reboot |
| `machine.network.*` (existing interface edit) | reload-only | Standard network reconfig |
| `machine.network.interfaces[]` **(NEW interface)** | **dry-run-skip** ⚠️ | `dry_run=true` panics — see §7 |
| `machine.files` | reload-only | File content changes |
| `machine.env` | reload-only | Environment variables |
| `machine.kubelet.*` | reload-only | Kubelet config |
| `machine.install.image` (installer URL change) | **reboot required** | OS image/schematic upgrade |
| `machine.kernel.modules` | **reboot required** | Kernel module change |
| `cluster.*` | context-dependent | Check field specifics |
| Version field (`talosVersion`) | **reboot required** | OS upgrade path |

**Apply-Config Gotcha:** If the diff adds a new `interfaces:` entry (not present in live config),
`dry_run=true` will panic. Flag this explicitly in the report (see `talos-mcp-first.md §Apply-Config Gotchas`).

Note on installer extensions: On this cluster, extensions are embedded via Talos Image Factory
schematic IDs (`talos/.schematic-ids.mk`), not inline in machine configs. A diff showing inline
`machine.install.extensions` would indicate config drift — investigate before applying.

### 6. Present diff report

Output a structured report per node:

```
## Talos Config Diff Report — <date>

### node-01 (192.168.2.61, control-plane)
Change class: reload-only
Fields changed:
  + machine.sysctls["net.ipv4.ip_forward"]: "1"
  - machine.network.interfaces[0].mtu: 1450

### node-04 (192.168.2.64, worker)
Change class: IN SYNC (no diff)

### node-gpu-01 (192.168.2.67, worker-gpu)
Change class: reboot-required ⚠️
Fields changed:
  ~ machine.install.image: factory.talos.dev/metal-installer/<new-schematic>:<new-version>

### Summary
| Node       | Change Class      | Dry-run Safe | Action |
|------------|-------------------|--------------|--------|
| node-01    | reload-only       | Yes          | /talos-apply node-01 |
| node-02    | IN SYNC           | N/A          | Skip   |
| node-gpu-01| reboot-required   | Yes          | /talos-apply node-gpu-01 (reboot expected) |
```

### 7. Flag dry-run gotchas

For any node where the diff shows a new interface entry (field path `machine.network.interfaces[]`
or `machine.network.devices[].vlans[]` where the interface name is new):

```
⚠️  node-XX: New interface detected in diff. Skip dry_run=true — use talos-apply directly.
    (talos_apply_config dry_run=true panics on fresh interface additions — see talos-mcp-first.md)
```

## Hard Rules

- This skill is read-only. It does not apply configs.
- Never edit `talos/generated/**` — these are build outputs from `make -C talos gen-configs`.
- If `gen-configs` requires SOPS decryption and fails, stop and ask the user to ensure `SOPS_AGE_KEY_FILE` or `~/.config/sops/age/keys.txt` is set.
- The diff is informational only. Apply decisions are made with `/talos-apply` or `make -C talos apply-<node>`.
