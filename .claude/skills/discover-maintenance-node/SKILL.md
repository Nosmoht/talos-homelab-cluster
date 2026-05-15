---
name: discover-maintenance-node
description: Probe a fresh Talos node in maintenance mode and render the per-node talos/nodes/<name>.yaml from the shared template. CLI-only because talos-mcp requires talosconfig+TLS and a fresh node has none.
argument-hint: <node-name>
disable-model-invocation: true
allowed-tools:
  - Bash
  - Read
  - Write
  - Grep
---

# Discover Maintenance Node

You probe a freshly-booted Talos node in maintenance mode (no PKI yet) and render its `talos/nodes/<name>.yaml` from the shared template `talos/nodes/_template.yaml.tmpl`. The node-name argument must already exist in `cluster.yaml` with `name`, `ip`, and `nic` set (Phase 1 of the onboarding workflow — see `/onboard-worker-node`).

## Scope guard

This skill renders the **standard-worker** template only (single primary NIC + DRBD VLAN 110 + KubeVirt sub-interface inherited via Makefile pattern-rule). Reject and stop if the requested node-name is:

- `node-gpu-*` — different schematic, no DRBD, custom NIC (e.g. USB realtek)
- `node-pi-*` — ARM, USB boot, firewall patch
- under `cluster.yaml.nodes.control_plane[]` — CP nodes carry the API VIP

For those roles, redirect the user to a role-specific skill or manual template.

## MCP-vs-CLI decision

Talos-MCP requires `talosconfig` + TLS and cannot reach a fresh node in maintenance mode. **CLI-only** for every probe in this skill (see `.claude/rules/talos-mcp-first.md` CLI-Only-Tabelle and `.claude/rules/talos-config.md §API Behaviour`):

- Version probe: `talosctl version --nodes <ip> --insecure` (top-level `--insecure`)
- Resource probes: `talosctl get -i <type> --nodes <ip> -o yaml` (subcommand-level `-i`; verified types: `disks`, `links`)

## Workflow

### 1. Resolve node from cluster.yaml

```bash
NODE="$1"   # e.g. node-08
yq -e ".nodes.workers[] | select(.name == \"$NODE\")" cluster.yaml >/dev/null \
  || { echo "FAIL: $NODE not under cluster.yaml.nodes.workers[] — add it first"; exit 1; }
NODE_IP=$(yq -r ".nodes.workers[] | select(.name == \"$NODE\") | .ip" cluster.yaml)
NODE_NIC=$(yq -r ".nodes.workers[] | select(.name == \"$NODE\") | .nic" cluster.yaml)
GATEWAY=$(yq -r ".cluster.gateway" cluster.yaml)
```

If the node is already under `cluster.yaml.nodes.{control_plane,gpu_workers,pi_nodes}[]`, abort with the scope-guard message.

### 2. Probe maintenance API

**Pre-probe fail-safe (CRITICAL — protects already-operational nodes):**

```bash
# If `talosctl version` SUCCEEDS without --insecure, the node is already
# configured for THIS cluster. Aborting prevents the operator from
# accidentally `talos_reset`ing an operational node — the runbook's
# old "TLS error → reset" suggestion would have been destructive here.
if talosctl version --nodes "$NODE_IP" >/dev/null 2>&1; then
  echo "ABORT: node $NODE_IP is already operational (talosctl version without --insecure succeeded)."
  echo "If you intended to onboard this node, the source-of-truth is already in the cluster."
  echo "Use /onboard-worker-node $NODE which has P-1 resume detection; do NOT run discover directly."
  echo "If you intended to RE-onboard (destructive reset), do so explicitly via:"
  echo "  mcp__talos__talos_reset confirm=true nodes=[$NODE_IP] system_labels_to_wipe=[\"EPHEMERAL\"]"
  echo "then re-run this skill once the node is back in maintenance mode."
  exit 1
fi

# Probe 1: confirm Talos boot in maintenance mode
talosctl version --nodes "$NODE_IP" --insecure

# Probe 2: list disks (find the right install target)
talosctl get -i disks --nodes "$NODE_IP" -o yaml

# Probe 3: list links (find the primary NIC's MAC + driver)
talosctl get -i links --nodes "$NODE_IP" -o yaml
```

**Why the pre-probe fail-safe matters (2026-05-14 session learning):** when a session is interrupted between onboard skill P5 (apply) and P9 (commit), the node is **operational** but the source-of-truth `talos/nodes/<node>.yaml` may not have been written to git. Re-running this skill without the fail-safe would (a) fail Probe 1 with TLS error, (b) misroute to the runbook's `talos_reset` suggestion, (c) wipe the operational node. The parent `/onboard-worker-node` skill's P-1 resume detection is the correct path in that case; this fail-safe redirects the operator there.

From Probe 2 output, select an install-disk by-path (`/dev/disk/by-path/...`) — prefer SATA over USB unless the node is USB-boot. From Probe 3 output, find the link matching `$NODE_NIC` and extract `hardwareAddr` and `driver`.

Present the candidate values to the user:
```
## Probe results for <NODE>
- Maintenance API: reachable (Talos vX.Y.Z)
- Install disk: <by-path>
- Primary NIC <NODE_NIC>: MAC <mac>, driver <driver>

Proceed to render talos/nodes/<NODE>.yaml? (yes/no)
```

### 3. Compute DRBD IP per `.claude/rules/talos-config.md §DRBD Replication VLAN`

DRBD host-octet = LAN host-octet − 60. The DRBD subnet is the standard-worker DRBD VLAN (third octet 110, ID 110, parent = `$NODE_NIC`).

```bash
LAN_OCTET=$(echo "$NODE_IP" | awk -F. '{print $4}')
DRBD_OCTET=$((LAN_OCTET - 60))
[ "$DRBD_OCTET" -gt 0 ] && [ "$DRBD_OCTET" -lt 255 ] \
  || { echo "FAIL: LAN host-octet $LAN_OCTET out of supported range for DRBD scheme"; exit 1; }
DRBD_IP_PREFIX="$(echo "$NODE_IP" | awk -F. '{print $1"."$2"."}')110.${DRBD_OCTET}"
```

Verify the computed DRBD IP doesn't collide with another worker (grep all `talos/nodes/node-0*.yaml` for the same address).

### 4. Render via the shared template

```bash
NODE_NAME="$NODE" \
NODE_MAC="<probed-mac>" \
NODE_INSTALL_DISK="<probed-by-path>" \
NODE_LAN_IP_CIDR="${NODE_IP}/24" \
NODE_DRBD_IP_CIDR="${DRBD_IP_PREFIX}/24" \
NODE_NIC_DRIVER="<probed-driver>" \
NODE_GATEWAY="${GATEWAY}" \
NODE_VLAN_INTERFACE="${NODE_NIC}.110" \
NODE_VLAN_PARENT="${NODE_NIC}" \
  envsubst < talos/nodes/_template.yaml.tmpl > "talos/nodes/${NODE}.yaml"
```

### 5. Sanity-check the rendered file

```bash
# YAML syntax
yq eval-all '.' "talos/nodes/${NODE}.yaml" >/dev/null

# Document count (3 expected: machine + HostnameConfig + VLANConfig)
test "$(yq eval-all '. | documentIndex' "talos/nodes/${NODE}.yaml" | wc -l)" -eq 3

# Structural diff vs an existing standard-worker (e.g. node-05)
diff <(grep -E "^(machine|  install|    disk|  network|    interfaces|---|apiVersion|kind|hostname|name:|vlanID|parent|up:)" talos/nodes/node-05.yaml) \
     <(grep -E "^(machine|  install|    disk|  network|    interfaces|---|apiVersion|kind|hostname|name:|vlanID|parent|up:)" "talos/nodes/${NODE}.yaml")
```

A clean structural diff means only `hostname:`, `name:` (VLAN interface name), and `parent:` differ — those carry the new node-name and (if the NIC name differs) the new VLAN parent. Anything else means template drift; stop and investigate.

### 6. Show user the diff and the file

```bash
git diff --no-index /dev/null "talos/nodes/${NODE}.yaml"
```

Wait for explicit user confirmation before considering the file committable. This skill does NOT run `git add` or `git commit` — those happen in the parent `/onboard-worker-node` workflow at Phase P9.

## Hard Rules

- Never write `cluster.yaml` from this skill. cluster.yaml is the cluster-identity SoT and stays free of per-node Talos detail (per `.claude/rules/talos-config.md` and the A1 rollen-trennung).
- Never probe a node that is NOT in maintenance mode — `--insecure` against a configured node returns the same TLS-required errors as the MCP path.
- Never proceed if Probe 2/3 fail or return unexpected schemas — abort and report; do not render with guessed values.
- Never apply the rendered file directly. Apply happens in `/onboard-worker-node` Phase P5 via `make install-<node>`.
