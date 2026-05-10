---
name: optimize-node-kernel
description: Research and apply optimized kernel parameters for a Talos node based on its hardware analysis. Reads hardware profile, researches best settings, patches config files.
argument-hint: [node-name]
disable-model-invocation: true
allowed-tools: Bash, Read, Write, Edit, WebSearch, WebFetch
---

# Optimize Node Kernel Parameters

## Environment Setup

Read `cluster.yaml` to load cluster-specific values (node IPs, kubeconfig path).
If the file is missing, tell the user: "Copy `cluster.yaml.example` to `cluster.yaml` and fill in your cluster details."

Use throughout this skill:
- `KUBECONFIG=<kubeconfig>` for all `kubectl` commands
- `-n <node-ip> -e <node-ip>` for all `talosctl` commands targeting a node

You are a Linux kernel and Talos infrastructure specialist optimizing node performance and security.

Research and apply optimized kernel parameters for a Talos Kubernetes node. Uses the hardware analysis document as input, researches best settings for the specific hardware, and modifies the appropriate config files.

## Prerequisites

This skill requires a hardware analysis document at `docs/hardware-analysis-<node-name>.md`. If it doesn't exist, instruct the user:

> The hardware analysis for `<node-name>` doesn't exist yet. Please run `/analyze-node-hardware <node-name>` first to generate it.

## Step 1: Read Context

Read these files in order. Skip files marked conditional if they don't apply to this node.

1. **Hardware analysis:** `docs/hardware-analysis-<node-name>.md` — the primary input. Read first to determine node role and hardware.
2. **Existing kernel tuning docs:**
   - `docs/kernel-tuning.md` — standard node tuning (understand what's already decided)
   - `docs/kernel-tuning-gpu.md` — **only if hardware analysis contains a GPU section**
3. **Current config files (determine which ones apply to this node):**
   - `talos/patches/common.yaml` — shared sysctls for ALL nodes
   - Role patch (determine from node labels or hardware analysis):
     - `talos/patches/controlplane.yaml` for control plane nodes
     - `talos/patches/worker-gpu.yaml` — **only for GPU workers**
     - Standard workers have no role patch (install image injected dynamically via Makefile)
   - `talos/nodes/<node-name>.yaml` — node-specific config
   - Factory schematic:
     - `talos/talos-factory-schematic.yaml` for standard nodes
     - `talos/talos-factory-schematic-gpu.yaml` — **only for GPU workers**
4. **Talos KSPP defaults** (documented in kernel-tuning.md Section 3) — to avoid duplicating parameters Talos already enforces

## Step 2: Identify Tuning Opportunities

Based on the hardware analysis, identify optimization opportunities in these categories:

### CPU-Specific
- Governor: `performance` vs `schedutil` vs `powersave`
- C-States: `intel_idle.max_cstate` / `processor.max_cstate` settings
- Mitigations: `mitigations=auto` vs specific overrides based on vulnerability matrix. **WARNING:** Never recommend `mitigations=off` unless the user explicitly requests it and acknowledges the security risk (5-20% performance gain but significant vulnerability exposure). Prefer selective overrides for specific CVEs over blanket disabling.
- Hyper-Threading: `nosmt` consideration (only if security requires it)
- Turbo Boost: BIOS recommendation if disabled

### GPU-Specific (if applicable)
- IOMMU mode: `iommu.strict=1` vs `iommu.strict=0` based on GPU workload
- PCIe ASPM: `pcie_aspm=off` for multi-GPU or mining boards
- NVIDIA module params: `NVreg_UsePageAttributeTable`, `NVreg_EnableResizableBar`, etc.
- BPF JIT hardening: whether to keep or remove the GPU override

### Storage-Specific
- I/O scheduler: `elevator=none` for SSD/NVMe, `mq-deadline` for HDD
- Dirty page tuning: `vm.dirty_ratio`, `vm.dirty_background_ratio` based on disk speed
- If node has mixed HDD+SSD, note that `elevator=none` as boot param affects ALL devices

### Memory-Specific
- THP: `transparent_hugepage=madvise` (standard for Kubernetes)
- Hugepages: whether to pre-allocate based on workload
- `vm.min_free_kbytes`: scale based on RAM size (64MB for 32GB, 128MB for 64GB+)
- Dirty page settings: adjust based on RAM amount

### Network-Specific
- TCP buffer sizes: based on NIC speed and capabilities
- Congestion control: `cubic` vs `bbr` based on network conditions
- USB NIC considerations: higher CPU overhead, adjust interrupt coalescing

### Security
- CPU vulnerability mitigations: verify all relevant ones are active
- IOMMU/VT-d: verify enabled and appropriate mode
- Memory protection: ASLR entropy, init_on_free

## Step 3: Research

Use WebSearch and WebFetch to research hardware-specific recommendations. Construct queries using exact hardware identifiers from the hardware analysis — do not use the example strings verbatim:

- Search for kernel tuning guides specific to the CPU model found in the hardware analysis
- Search for hardware-specific issues using the exact board vendor/model from the analysis
- Search for workload-specific tuning relevant to detected GPU/storage hardware
- Check NVIDIA documentation for recommended module parameters
- Check LINBIT/DRBD documentation for storage tuning relevant to the disk type
- Check Talos documentation for any version-specific kernel parameter notes

## Step 4: Categorize and Place Parameters

Before categorizing any parameter, reason through: (1) what hardware characteristic drives this change, (2) what the Talos KSPP baseline already covers, (3) which patch file owns the change per the decision rules below.

### Decision Rules for Patch Placement

| Parameter Type | Condition | Placement |
|---------------|-----------|-----------|
| **Sysctls** | Applies to ALL nodes (network, memory, security) | `talos/patches/common.yaml` |
| **Sysctls** | Specific to GPU workloads | `talos/patches/worker-gpu.yaml` |
| **Sysctls** | Specific to control plane (etcd tuning) | `talos/patches/controlplane.yaml` |
| **Sysctls** | Unique to one node's hardware | `talos/nodes/<node>.yaml` |
| **Boot parameters** | Applies to standard nodes | `talos/talos-factory-schematic.yaml` |
| **Boot parameters** | Applies to GPU worker | `talos/talos-factory-schematic-gpu.yaml` |
| **Kernel module params** | Role-specific module | Role patch (e.g., `worker-gpu.yaml`) |
| **BIOS settings** | Cannot be set via config | Document in recommendations only |

### Critical Rules

- **NEVER duplicate Talos KSPP defaults** (listed in kernel-tuning.md Section 3). These are already enforced by Talos and setting them again can cause conflicts.
- **NEVER duplicate parameters already in `common.yaml`** in role or node patches, unless intentionally overriding with a different value.
- **`--config-patch` APPENDS arrays** — if adding kernel modules, check that the module isn't already listed in a lower-precedence patch (common.yaml). Don't add the same module in both common and role patches.
- **Boot parameters require `talosctl upgrade`** — they are burned into the UKI image at install/upgrade time. Changing the schematic alone does nothing until upgrade is run.

## Step 5: Present Recommendations

Before making any changes, present a structured summary to the user:

```markdown
## Kernel Optimization Recommendations for <node-name>

### Changes to `talos/patches/common.yaml` (affects ALL nodes)
| Sysctl | Current | Proposed | Rationale |
|--------|---------|----------|-----------|
| ... | ... | ... | ... |

#### Example (do not copy verbatim — derive values from hardware analysis):
| Sysctl | Current | Proposed | Rationale |
|--------|---------|----------|-----------|
| net.core.somaxconn | 128 | 65535 | 10GbE NIC supports high connection rate; default 128 causes SYN drops under load |

### Changes to `talos/patches/<role>.yaml`
| Parameter | Current | Proposed | Rationale |
|-----------|---------|----------|-----------|
| ... | ... | ... | ... |

### Changes to `talos/nodes/<node>.yaml`
| Parameter | Current | Proposed | Rationale |
|-----------|---------|----------|-----------|
| ... | ... | ... | ... |

### Changes to `talos/talos-factory-schematic*.yaml`
| Boot Parameter | Current | Proposed | Rationale |
|----------------|---------|----------|-----------|
| ... | ... | ... | ... |

### BIOS Recommendations (manual)
| Setting | Current | Recommended | Rationale |
|---------|---------|-------------|-----------|
| ... | ... | ... | ... |

### Not Recommended
| Parameter | Why Not |
|-----------|---------|
| ... | ... |
```

Wait for user approval before proceeding to Step 6.

## Step 6: Apply Approved Changes

For each approved change:

1. **Edit the appropriate YAML file** using the Edit tool
2. **Verify YAML validity** after each edit:
   ```bash
   # For Talos config patches, validate if possible:
   python3 -c "import yaml; yaml.safe_load(open('talos/patches/common.yaml'))" 2>&1 || echo "YAML INVALID"
   ```
   If YAML validation fails for any file, halt all further edits and report the specific parse error to the user. Do not proceed to the next file or to `make gen-configs`.
3. **Semantic validation** — after `make gen-configs`, diff the rendered config against a pre-edit snapshot to confirm expected keys are present and no unexpected overrides occurred. If a previously-present sysctl key was silently dropped or duplicated, halt and report.
4. **Regenerate configs** (suggest but don't run without approval):
   ```bash
   make gen-configs
   ```
5. **Rollback** — if `talosctl apply-config` returns a non-zero exit code, instruct the user to run `git diff talos/` to identify changes, and `git restore` the affected files before retrying.

## Step 7: Update Documentation

After applying changes, update or create the kernel tuning documentation:

- If changes affect the GPU node, update `docs/kernel-tuning-gpu.md`
- If changes affect standard nodes, update `docs/kernel-tuning.md`
- Add new parameters with full rationale following the existing table format:
  `| Parameter | Value | Default | Rationale |`

## Step 8: Verification Commands

Provide verification commands for each change:

```bash
# After config apply or upgrade:

# Verify sysctls
talosctl -n $NODE_IP -e $NODE_IP read /proc/sys/<sysctl-path>

# Verify boot parameters (only after upgrade)
talosctl -n $NODE_IP -e $NODE_IP read /proc/cmdline
```
```
# Verify module parameters via MCP (filter output for <module-name>):
talos_dmesg(nodes=["$NODE_IP"])
# Fallback: talosctl -n $NODE_IP -e $NODE_IP dmesg | grep -i <module-name>
```

## Important Notes

- Always use explicit endpoint (`-e $NODE_IP`) with talosctl.
- Use the kubeconfig path from `cluster.yaml`.
- Boot parameter changes require `talosctl upgrade` (not just `talosctl apply-config`).
- Some changes require a node reboot to take effect.
- DRBD volumes should be drained before rebooting to avoid stuck shutdown (D-state processes).
- Write all output and documentation in English.
- Follow the style conventions of existing docs (table-driven, rationale-heavy).
