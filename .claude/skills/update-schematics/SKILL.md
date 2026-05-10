---
name: update-schematics
description: Analyze node hardware and update Talos Image Factory schematics with recommended extensions
argument-hint: [node-name|all]
disable-model-invocation: true
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, WebFetch
---

# Update Talos Image Factory Schematics

## Environment Setup

Read `cluster.yaml` to load cluster-specific values (node names and roles).
If the file is missing, tell the user: "Copy `cluster.yaml.example` to `cluster.yaml` and fill in your cluster details."

Use node inventory from `nodes.control_plane`, `nodes.workers`, `nodes.gpu_workers` to resolve node names and roles.

You are a Talos Linux infrastructure engineer. Your task is to determine the minimal correct set of system extensions for each node's Image Factory schematic. Think step-by-step and show your reasoning before conclusions.

Analyze hardware analysis documents, cross-reference the Talos extension catalog, and update the factory schematic YAML files with the correct set of system extensions. This skill sits between `/analyze-node-hardware` (input) and `/optimize-node-kernel` (which handles boot parameters — no overlap).

## Step 1: Argument Resolution

The user provides a node name (e.g., `node-01`, `node-gpu-01`) or `all`.

1. If `all`: target every node that has a hardware analysis doc.
2. If a specific node: target only that node.

**Validate prerequisites:**
- For each target node, verify `docs/hardware-analysis-<node>.md` exists. If missing, stop and tell the user:
  > Hardware analysis for `<node>` not found. Please run `/analyze-node-hardware <node>` first.

**Classify nodes into schematic groups** using the Makefile variables:
- Read `CP_NODES` and `WORKER_NODES` from `talos/Makefile` — these use `talos/talos-factory-schematic.yaml` (standard schematic)
- Read `GPU_NODES` from `talos/Makefile` — these use `talos/talos-factory-schematic-gpu.yaml` (GPU schematic)

Store the mapping of which target nodes belong to which schematic group.

## Step 2: Read Context

Read ALL of the following files:

1. **Hardware analysis docs** for each target node: `docs/hardware-analysis-<node>.md`
2. **Both schematic YAML files:**
   - `talos/talos-factory-schematic.yaml` — standard nodes
   - `talos/talos-factory-schematic-gpu.yaml` — GPU nodes
3. **Role patches** (for kernel module declarations):
   - `talos/patches/controlplane.yaml` — control plane config (no install image)
   - `talos/patches/worker-gpu.yaml` — look for `machine.kernel.modules`
   - Install images are NOT in patch files — they're built dynamically from `.schematic-ids.mk` + `TALOS_VERSION`
4. **TALOS_VERSION** from `talos/Makefile` (line starting with `TALOS_VERSION :=`)

## Step 3: Query Extension Catalog

Fetch the official extension catalog from the Talos Image Factory API:

```bash
# Strip leading 'v' if present — the API accepts both but be explicit
TALOS_VERSION_CLEAN="${TALOS_VERSION#v}"
curl -sS "https://factory.talos.dev/version/${TALOS_VERSION_CLEAN}/extensions/official" | jq '.'
```

This returns ~78 extensions, each with `name`, `ref`, `digest`, and `description`.

**Fallback:** If the API call fails (network error, timeout), use the extensions currently listed in the schematic files as the known-good baseline and note that the catalog could not be verified.

## Step 4: Extract Hardware Signals

For each target node, reason through the hardware data explicitly before populating the mapping table in Step 5:
1. State the CPU vendor found and which ucode extension this implies.
2. List every PCI device at class 0300/0302, note its vendor ID, and state the GPU extension conclusion.
3. Note whether any PCI device has class 0108 and your NVMe conclusion.
4. State the NIC driver found and whether it matches the Intel E800/ice-driver condition.
5. List any extensions already noted as missing/unnecessary in Section 11 of the analysis doc.

Only after this explicit reasoning, extract from each target node's hardware analysis document:

1. **CPU vendor** — from Section 1 "System Overview", CPU field. Look for "Intel" or "AMD".
2. **GPU devices** — from Section 2 "PCI Device Inventory", look for:
   - PCI class `0300` (VGA controller) or `0302` (3D controller)
   - Vendor `8086` = Intel iGPU, Vendor `10de` = NVIDIA
3. **NVMe devices** — from Section 2, look for PCI class `0108` (NVMe controller)
4. **NIC type/driver** — from Section 1 "Active NIC" field and Section 8 "Network Profile"
   - Intel E800 series NICs (Ice driver) need `intel-ice-firmware`
   - Identify by device IDs or driver name "ice" in the network profile
5. **Installed extensions** — from Section 10 "Installed Extensions"
6. **Observations** — from Section 11, look for any notes about missing or unnecessary extensions

## Step 5: Map Hardware to Extensions

Apply this curated mapping table. An extension is recommended if ANY target node in that schematic group meets the condition:

| Extension | Condition | Schematic |
|-----------|-----------|-----------|
| `siderolabs/drbd` | Always — LINSTOR/Piraeus requirement | Both |
| `siderolabs/intel-ucode` | Any node has Intel CPU | Standard and/or GPU |
| `siderolabs/amd-ucode` | Any node has AMD CPU | Standard and/or GPU |
| `siderolabs/i915` | Any node has Intel iGPU (vendor 8086, class 0300) | Standard and/or GPU |
| `siderolabs/nvidia-open-gpu-kernel-modules-lts` | Any node has NVIDIA GPU (vendor 10de) | GPU |
| `siderolabs/nvidia-container-toolkit-lts` | Any node has NVIDIA GPU (vendor 10de) | GPU |
| `siderolabs/nvme-cli` | Any node has NVMe device (class 0108) | Standard and/or GPU |
| `siderolabs/intel-ice-firmware` | Any node has Intel E800 series NIC (Ice driver) | Standard and/or GPU |

**LTS vs. non-LTS:** Use the `-lts` extension variants when `TALOS_VERSION` tracks an LTS Talos release (e.g., v1.8.x, v1.10.x). Use the non-LTS variants (without `-lts`) for stable/latest releases. When in doubt, cross-reference the catalog output from Step 3 — only one variant will be present for the given version.

**Union rule:** For shared schematics (standard schematic covers CP + worker nodes), take the **union** of all nodes' extension needs. If even one standard node needs an extension, it goes into the standard schematic. Unused extensions on other nodes are harmless.

Cross-reference against the extension catalog from Step 3 to verify that all recommended extensions actually exist for this Talos version. Warn if an extension is needed but not available.

## Step 6: Compute Changes Per Schematic

For each schematic file, compare the current `systemExtensions.officialExtensions` list against the recommended set:

- **OK** — extension is currently listed and still recommended
- **ADD** — extension is recommended but not currently listed
- **REMOVE** — extension is currently listed but no hardware justification found (flag for review, don't auto-remove — the user may have a reason)

## Step 7: Present Recommendations

Present a structured summary. **Stop and wait for user approval before making changes.**

```markdown
## Schematic Extension Recommendations

### Standard Schematic (`talos/talos-factory-schematic.yaml`)

**Current Extensions:**
| Extension | Status | Rationale |
|-----------|--------|-----------|
| siderolabs/drbd | OK | LINSTOR requirement |
| ... | ... | ... |

**Recommended Changes:**
| Action | Extension | Rationale |
|--------|-----------|-----------|
| ADD | siderolabs/foo | Detected on node-XX (PCI ...) |
| REMOVE? | siderolabs/bar | No hardware match found — verify manually |

**Node Coverage:**
| Node | CPU | GPU | NVMe | NIC | Extensions Covered |
|------|-----|-----|------|-----|--------------------|
| node-01 | Intel | Intel iGPU | Yes | I219-LM | drbd, intel-ucode, i915, nvme-cli |
| ... | ... | ... | ... | ... | ... |

### GPU Schematic (`talos/talos-factory-schematic-gpu.yaml`)

(Same format as above)

### Post-Apply Steps
1. Run `make schematics` to generate new schematic IDs and update install image URLs
2. Run `make gen-configs` to regenerate node configs
3. For each affected node, upgrade using the `/talos-upgrade` skill (extension changes require image upgrade):
   ```
   # Apply config via MCP:
   talos_apply_config(config_file="<abs-path>/talos/generated/<role>/<node>.yaml", dry_run=false, confirm=true, nodes=["<ip>"], mode="auto")
   # Upgrade via MCP (fires and returns — poll talos_health until node rejoins):
   talos_upgrade(nodes=["<ip>"], image="<install-image>", preserve=true, confirm=true)
   talos_health(nodes=["<ip>"])
   # Fallback: talosctl -n <ip> -e <ip> apply-config -f talos/generated/<role>/<node>.yaml
   # Fallback: talosctl upgrade -n <ip> -e <ip> --image <install-image> --preserve
   ```
   Resolve `<install-image>` from `talos/.schematic-ids.mk` + `talos/versions.mk`.
   - **IMPORTANT:** Drain DRBD volumes before upgrading to avoid stuck shutdown
```

## Step 8: Apply Approved Changes

After user approval:

1. **Edit schematic YAML files** — update the `systemExtensions.officialExtensions` list:
   - Keep extensions sorted alphabetically (by full name including `siderolabs/` prefix)
   - Preserve the rest of the file (bootloader, extraKernelArgs) unchanged
2. **Validate YAML** after editing:
   ```bash
   python3 -c "import yaml; yaml.safe_load(open('talos/talos-factory-schematic.yaml'))" && echo "OK"
   python3 -c "import yaml; yaml.safe_load(open('talos/talos-factory-schematic-gpu.yaml'))" && echo "OK"
   ```
3. **Cross-check kernel modules** — verify that kernel module declarations in role patches (`machine.kernel.modules` in `talos/patches/worker-gpu.yaml`, `talos/patches/controlplane.yaml`) are consistent with the schematic extensions:
   - NVIDIA extensions require `nvidia`, `nvidia_uvm`, `nvidia_drm` modules in the role patch
   - DRBD extension requires `drbd` module (should be in `talos/patches/common.yaml`)
   - If mismatch found, **warn** the user but do NOT edit role patches (out of scope for this skill)

## Step 9: Run Make Targets

Run the following commands sequentially:

```bash
# Generate new schematic IDs and update install image URLs in patch files
make schematics

# Regenerate node configs with updated install images
make gen-configs
```

If either command fails, stop and report the error.

## Step 10: Report

Present a final summary:

```markdown
## Update Complete

### Schematic Changes
| Schematic | Old ID | New ID |
|-----------|--------|--------|
| Standard | abc123... | def456... |
| GPU | 789abc... | 012def... |

### Updated Schematic IDs
Install images are built dynamically from `.schematic-ids.mk` + `TALOS_VERSION`. After running `make schematics`, the IDs are written to `.schematic-ids.mk` automatically.

### Next Steps
To apply the new schematics to nodes, upgrade each affected node with direct talosctl:
- **IMPORTANT:** Drain DRBD volumes before upgrading: `kubectl linstor resource list` to check placements
- Resolve install image from `talos/.schematic-ids.mk` + `talos/versions.mk`
- For each node, use `/talos-upgrade` skill or MCP directly:
  ```
  talos_apply_config(config_file="<abs-path>/talos/generated/<role>/<node>.yaml", dry_run=false, confirm=true, nodes=["<ip>"], mode="auto")
  talos_upgrade(nodes=["<ip>"], image="<install-image>", preserve=true, confirm=true)
  talos_health(nodes=["<ip>"])
  # Fallback: talosctl -n <ip> -e <ip> apply-config -f talos/generated/<role>/<node>.yaml
  # Fallback: talosctl upgrade -n <ip> -e <ip> --image <install-image> --preserve
  ```
- Boot parameter changes (in `extraKernelArgs`) also require upgrade — they are baked into the UKI image
```

## Important Notes

- **Extensions only, not boot params** — this skill manages `systemExtensions.officialExtensions`. Boot parameters (`extraKernelArgs`) are owned by `/optimize-node-kernel`.
- **Union-based extension sets** — shared schematics include the union of all covered nodes' needs. Unused extensions on individual nodes are harmless (they just add unused kernel modules).
- **User approval gate** — always present the diff and wait for explicit approval before editing files.
- **No role patch edits** — this skill warns about kernel module mismatches but does not edit role patches. That's the user's or `/optimize-node-kernel`'s responsibility.
- Always write output in English.
