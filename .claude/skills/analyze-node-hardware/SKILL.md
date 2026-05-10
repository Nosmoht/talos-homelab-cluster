---
name: analyze-node-hardware
description: Analyze hardware of a Talos node using talosctl and NFD. Produces comprehensive hardware profile for kernel tuning.
argument-hint: [node-name-or-ip]
disable-model-invocation: true
allowed-tools:
  - Bash
  - Read
  - Glob
  - Grep
  - Write
  - mcp__talos__talos_version
  - mcp__talos__talos_dmesg
  - mcp__talos__talos_get
  - mcp__kubernetes-mcp-server__resources_get
---

# Analyze Node Hardware

## Environment Setup

Read `cluster.yaml` to load cluster-specific values (node IPs, kubeconfig path).
If the file is missing, tell the user: "Copy `cluster.yaml.example` to `cluster.yaml` and fill in your cluster details."

Use throughout this skill:
- `KUBECONFIG=<kubeconfig>` for all `kubectl` commands
- `-n <node-ip> -e <node-ip>` for all `talosctl` commands targeting a node
- Resolve node name → IP from `nodes.*` in cluster.yaml (or from `talos/nodes/<name>.yaml`)

You are a Talos Linux infrastructure engineer performing read-only hardware inventory and kernel-tuning analysis. Your output must be factual, structured, and based solely on data retrieved from the node — do not infer or assume hardware capabilities not confirmed by the gathered data.

Comprehensive hardware analysis of a Talos Kubernetes node. Gathers data via `talosctl` and `kubectl` NFD (Node Feature Discovery), reads current config state, and produces a structured hardware profile document.

## Argument Resolution

The user provides either a node name (e.g., from cluster.yaml) or an IP address.

1. If given a **node name**: look up `talos/nodes/<name>.yaml` to find the IP address (under `machine.network.interfaces[].addresses`).
2. If given an **IP address**: scan `talos/nodes/*.yaml` files to find the matching node name by IP, and read the HostnameConfig `hostname` field.
3. If neither matches, ask the user for clarification.

Store both `NODE_NAME` and `NODE_IP` for use throughout.

## Data Gathering

### Step 1: Hardware Data via talosctl

First, verify connectivity with a 10-second timeout. If this fails, stop and report the error — do not proceed to generate a hardware profile with empty data:

```
talos_version(nodes=["$NODE_IP"])
# Fallback: timeout 10 talosctl -n $NODE_IP -e $NODE_IP version --short
```

For all subsequent talosctl commands, if more than 3 consecutive commands fail, abort and report partial results with a connectivity warning.

Run the following commands (parallelize where possible). All talosctl commands MUST use explicit endpoint: `talosctl -n $NODE_IP -e $NODE_IP`.

```bash
# CPU info
talosctl -n $NODE_IP -e $NODE_IP read /proc/cpuinfo

# Memory info
talosctl -n $NODE_IP -e $NODE_IP read /proc/meminfo

# DMI / system identification
talosctl -n $NODE_IP -e $NODE_IP read /sys/devices/virtual/dmi/id/product_name
talosctl -n $NODE_IP -e $NODE_IP read /sys/devices/virtual/dmi/id/board_name
talosctl -n $NODE_IP -e $NODE_IP read /sys/devices/virtual/dmi/id/sys_vendor

# Current boot parameters
talosctl -n $NODE_IP -e $NODE_IP read /proc/cmdline

# CPU vulnerability mitigations
for v in $(talosctl -n $NODE_IP -e $NODE_IP ls /sys/devices/system/cpu/vulnerabilities/ 2>/dev/null | tail -n +2 | awk '{print $NF}'); do
  echo -n "$v: "
  talosctl -n $NODE_IP -e $NODE_IP read /sys/devices/system/cpu/vulnerabilities/$v 2>/dev/null
done

# CPU frequency governor
talosctl -n $NODE_IP -e $NODE_IP read /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null
talosctl -n $NODE_IP -e $NODE_IP read /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null

# Turbo boost status (Intel)
talosctl -n $NODE_IP -e $NODE_IP read /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null
# Turbo boost status (AMD — boost is inverse: 1=enabled, 0=disabled)
talosctl -n $NODE_IP -e $NODE_IP read /sys/devices/system/cpu/cpufreq/boost 2>/dev/null

# THP status
talosctl -n $NODE_IP -e $NODE_IP read /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null

# NUMA status
talosctl -n $NODE_IP -e $NODE_IP ls /sys/devices/system/node/ 2>/dev/null

# Block devices — enumerate and read scheduler/rotational for each
BLOCK_DEVS=$(talosctl -n $NODE_IP -e $NODE_IP ls /sys/block/ 2>/dev/null | tail -n +2 | awk '{print $NF}' | grep -vE '^(loop|ram)')
for DEV in $BLOCK_DEVS; do
  echo "=== $DEV ==="
  talosctl -n $NODE_IP -e $NODE_IP read /sys/block/$DEV/queue/scheduler 2>/dev/null || echo "not present"
  talosctl -n $NODE_IP -e $NODE_IP read /sys/block/$DEV/queue/rotational 2>/dev/null || echo "not present"
done

# IOMMU status (MCP — filter client-side after retrieving):
# talos_dmesg(nodes=["$NODE_IP"])  → filter output for iommu|dmar|vt-d
# Fallback: talosctl -n $NODE_IP -e $NODE_IP dmesg | grep -iE "(iommu|dmar|vt-d)"

# NVIDIA / GPU info (same dmesg call — filter for nvidia|gpu|drm):
# talos_dmesg(nodes=["$NODE_IP"])  → filter output for nvidia|gpu|drm
# Fallback: talosctl -n $NODE_IP -e $NODE_IP dmesg | grep -iE "(nvidia|gpu|drm)"

# Network interfaces
talosctl -n $NODE_IP -e $NODE_IP read /proc/net/dev

# Loaded modules (same dmesg call — filter for module.*loaded|driver.*registered):
# talos_dmesg(nodes=["$NODE_IP"])  → filter output for module.*loaded|driver.*registered
# Fallback: talosctl -n $NODE_IP -e $NODE_IP dmesg | grep -iE "module.*loaded|driver.*registered"

# PCI devices — enumerate and read vendor/device/class for each
# If PCI device count exceeds 40, summarize by class rather than listing each BDF.
# Prioritize Network (0200), Storage (0100/0104/0108), GPU (0300/0302), and IOMMU classes.
PCI_DEVS=$(talosctl -n $NODE_IP -e $NODE_IP ls /sys/bus/pci/devices/ 2>/dev/null | tail -n +2 | awk '{print $NF}')
for BDF in $PCI_DEVS; do
  VENDOR=$(talosctl -n $NODE_IP -e $NODE_IP read /sys/bus/pci/devices/$BDF/vendor 2>/dev/null || echo "unknown")
  DEVICE=$(talosctl -n $NODE_IP -e $NODE_IP read /sys/bus/pci/devices/$BDF/device 2>/dev/null || echo "unknown")
  CLASS=$(talosctl -n $NODE_IP -e $NODE_IP read /sys/bus/pci/devices/$BDF/class 2>/dev/null || echo "unknown")
  echo "$BDF vendor=$VENDOR device=$DEVICE class=$CLASS"
done

# Installed Talos extensions (MCP):
# talos_get(resource_type="extensions", nodes=["$NODE_IP"])
# Fallback: talosctl -n $NODE_IP -e $NODE_IP get extensions
```

### Step 2: NFD Data via Kubernetes MCP

```
# Node labels (includes NFD feature labels) — named lookup
resources_get(apiVersion="v1", kind="Node", name="$NODE_NAME")
# Read .metadata.labels for all NFD feature labels (keys starting "feature.node.kubernetes.io/").
# Fallback: KUBECONFIG=$KUBECONFIG kubectl get node $NODE_NAME -o yaml

# Full NFD feature discovery (if NFD is deployed) — named lookup
resources_get(apiVersion="nfd.k8s-sigs.io/v1alpha1", kind="NodeFeature", name="$NODE_NAME", namespace="node-feature-discovery")
# Read full .spec.features from JSON for hardware capability details.
# Fallback: KUBECONFIG=$KUBECONFIG kubectl get nodefeature -n node-feature-discovery $NODE_NAME -o yaml 2>/dev/null

# USB device labels for inventory (Section 3) — reuse Node resources_get result from above.
# Filter .metadata.labels client-side: select entries whose key starts with "feature.node.kubernetes.io/usb".
# Fallback: KUBECONFIG=$KUBECONFIG kubectl get node $NODE_NAME -o json | jq '.metadata.labels | to_entries[] | select(.key | startswith("feature.node.kubernetes.io/usb"))'
```

If `kubectl get nodefeature` returns no output or an error, note "NFD not deployed" in Section 4 and write "N/A — NFD not deployed" in Section 3 (USB Device Inventory). Do not emit empty table placeholders.

### Step 3: Current Config State

Read the following files to understand what's currently configured:

1. `talos/patches/common.yaml` — shared sysctls and settings for all nodes
2. Determine the node's role from its Kubernetes labels (`node-role.kubernetes.io/control-plane` or worker):
   - Control plane: `talos/patches/controlplane.yaml`
   - GPU worker: `talos/patches/worker-gpu.yaml`
   - Standard workers have no role patch (install image injected dynamically via Makefile)
3. `talos/nodes/$NODE_NAME.yaml` — node-specific config
4. Determine the correct factory schematic:
   - Standard nodes: `talos/talos-factory-schematic.yaml`
   - GPU worker: `talos/talos-factory-schematic-gpu.yaml`
   - Check the `machine.install.image` URL in the role patch — the schematic ID in the URL identifies which schematic file

### Step 4: Live Sysctl Verification

Read key sysctl values from the live node and compare against configured values:

```bash
# Storage I/O
talosctl -n $NODE_IP -e $NODE_IP read /proc/sys/vm/dirty_ratio
talosctl -n $NODE_IP -e $NODE_IP read /proc/sys/vm/dirty_background_ratio

# Memory
talosctl -n $NODE_IP -e $NODE_IP read /proc/sys/vm/overcommit_memory
talosctl -n $NODE_IP -e $NODE_IP read /proc/sys/vm/max_map_count
talosctl -n $NODE_IP -e $NODE_IP read /proc/sys/vm/min_free_kbytes

# Network buffers
talosctl -n $NODE_IP -e $NODE_IP read /proc/sys/net/core/rmem_max
talosctl -n $NODE_IP -e $NODE_IP read /proc/sys/net/core/wmem_max
talosctl -n $NODE_IP -e $NODE_IP read /proc/sys/net/core/somaxconn
talosctl -n $NODE_IP -e $NODE_IP read /proc/sys/net/core/netdev_max_backlog

# TCP
talosctl -n $NODE_IP -e $NODE_IP read /proc/sys/net/ipv4/tcp_slow_start_after_idle
talosctl -n $NODE_IP -e $NODE_IP read /proc/sys/net/ipv4/tcp_congestion_control

# Security
talosctl -n $NODE_IP -e $NODE_IP read /proc/sys/net/core/bpf_jit_harden
talosctl -n $NODE_IP -e $NODE_IP read /proc/sys/kernel/kexec_load_disabled
talosctl -n $NODE_IP -e $NODE_IP read /proc/sys/net/ipv4/conf/all/rp_filter

# Conntrack
talosctl -n $NODE_IP -e $NODE_IP read /proc/sys/net/netfilter/nf_conntrack_max

# Process limits
talosctl -n $NODE_IP -e $NODE_IP read /proc/sys/kernel/pid_max
talosctl -n $NODE_IP -e $NODE_IP read /proc/sys/fs/inotify/max_user_watches
```

## Output Document

The only Write operation permitted is creating the output file below. Do not write to any other path.

Write the analysis to `docs/hardware-analysis-$NODE_NAME-YYYYMMDD.md` (use today's date). If a file already exists for today, append a suffix: `-2`, `-3`, etc. Do not overwrite existing analyses.

Use the following structure:

```markdown
# Hardware Analysis: $NODE_NAME

> **Date:** YYYY-MM-DD
> **Talos:** version | **Kubernetes:** version
> **Node IP:** $NODE_IP | **Role:** control-plane/worker

---

## 1. System Overview

| Property | Value |
|----------|-------|
| Board | ... |
| Vendor | ... |
| CPU | ... |
| Cores/Threads | ... |
| RAM | ... |
| Boot Disk | ... |
| Data Disk | ... |
| Active NIC | ... |
| GPUs | ... (if any) |

## 2. PCI Device Inventory

Table with BDF, Vendor:Device, Class, Description

## 3. USB Device Inventory

Table with Vendor:Device, Class, Serial, Description (from NFD usb.device)

## 4. NFD Feature Highlights

Key NFD features organized by category (CPU, Storage, Memory, PCI, USB)

## 5. CPU Vulnerability Status

Table: Vulnerability | CVE | Status (from /sys/devices/system/cpu/vulnerabilities/*)

## 6. Current Kernel Parameters

### 6.1 Boot Parameters (/proc/cmdline)
Parsed list of current boot parameters

### 6.2 Configured Boot Parameters (from schematic)
What the factory schematic specifies in extraKernelArgs

### 6.3 Gap Analysis
Before writing this table, reason through: (1) list every parameter in the schematic's `extraKernelArgs`, (2) check each against `/proc/cmdline`, (3) classify as `Present-Match`, `Present-Mismatch`, or `Missing`. Only then write the table.

Table showing: Parameter | In Schematic | In /proc/cmdline | Status

### 6.4 Sysctl Verification
Table: Sysctl | Configured Value | Live Value | Match (yes/no)

## 7. Storage Profile

Table: Device | Type | Scheduler | Rotational | Role

## 8. Network Profile

Table: Interface | Driver | Type | Speed | Status

## 9. GPU Profile (if applicable)

Driver version, IOMMU groups, PCIe topology, Kubernetes GPU resources

## 10. Installed Extensions

Table: Extension | Version | Purpose

## 11. Observations

Bullet points of notable findings, anomalies, or recommendations for further investigation
```

## Important Notes

- Always use explicit endpoint (`-e $NODE_IP`) with talosctl — VIP forwarding does not support all operations.
- Some reads may fail (e.g., no NVMe on a node, no GPU driver). Handle gracefully — note "not present" in the output.
- Use the kubeconfig path from `cluster.yaml`. If `kubectl` fails, try: `KUBECONFIG=<kubeconfig> kubectl ...`
- NFD namespace is `node-feature-discovery`.
- Do NOT make any changes to config files — this skill is read-only analysis.
- Write all output in English.
