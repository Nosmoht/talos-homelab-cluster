# Day 0 — Cluster Setup & Initial Installation

This document covers the initial build-out of the homelab cluster from scratch.

## Prerequisites

### Hardware

| Node | Hardware | CPU | Role |
|------|----------|-----|------|
| node-01 | ThinkCentre M910q | Kaby Lake 4C/8T | control-plane |
| node-02 | ThinkCentre M910q | Kaby Lake 4C/8T | control-plane |
| node-03 | ThinkCentre M910q | Kaby Lake 4C/8T | control-plane |
| node-04 | ThinkCentre M910q | Kaby Lake 4C/8T | worker |
| node-05 | ThinkCentre M910q | Kaby Lake 4C/8T | worker |
| node-06 | ThinkCentre M920q | Kaby Lake i7-7700T 4C/8T | worker |
| node-gpu-01 | Custom | — | worker (GPU, NVIDIA) |

Install disks use stable `/dev/disk/by-path/` paths in per-node configs.

### BIOS Configuration

On all M910q and M920q nodes **before** installation:

1. Press **F1** during boot (BIOS Setup)
2. Navigate to **Security → Virtualization**
3. Set **Intel VT-d** to **Enabled**
4. **F10** — Save and restart

If the option is not visible (some M910q BIOS versions):
- Update BIOS to the latest version (Lenovo Support page)
- Alternative paths: **Advanced → Intel (R) VT for Directed I/O (VT-d)**

VT-d is required for the boot parameters `intel_iommu=on` and `iommu=force` to take effect.

### Workstation Tools

| Tool | Purpose |
|------|---------|
| `talosctl` | Talos node management |
| `kubectl` | Kubernetes cluster management |
| `kubectl linstor` | LINSTOR plugin for storage |
| `yq` | YAML post-processing (HostnameConfig) |
| `make` | Build automation |
| `sops` | Secrets decryption (AGE backend) |
| `curl`, `jq` | Image Factory API |

### Network

| Resource | Address |
|----------|---------|
| Subnet | 192.168.2.0/24 |
| Gateway / DNS / NTP | 192.168.2.1 |
| Cluster VIP (kube-apiserver) | 192.168.2.60 |
| Node IPs | 192.168.2.61–67 |

## Project Structure

```
repo-root/
├── Makefile                           # Build automation
├── secrets.yaml                       # Cluster secrets (SOPS-encrypted, gitignored)
├── patches/
│   ├── common.yaml                    # All nodes: sysctls, DRBD, kubelet, NTP
│   ├── controlplane.yaml              # Control plane: Cilium manifests (~1700 lines)
│   └── worker-gpu.yaml               # GPU worker: NVIDIA modules, bpf_jit
│   └── worker-pi.yaml                # Pi worker: edge labels
├── nodes/
│   ├── node-{01..06}.yaml             # Per node: hostname, static IP, VIP (CP only)
│   └── node-gpu-01.yaml
│   └── node-pi-01.yaml
├── talos-factory-schematic.yaml       # Standard schematic (boot params + extensions)
├── talos-factory-schematic-gpu.yaml   # GPU schematic (+ NVIDIA drivers)
├── talos-factory-schematic-pi.yaml    # Pi schematic (ARM-safe kernel args)
├── generated/                         # Generated configs (gitignored)
│   ├── controlplane/
│   └── worker/
└── docs/
```

### Patch Order

Configs are assembled in this order — later patches override scalar values,
arrays are **appended** (not merged):

```
patches/common.yaml → patches/<role>.yaml → nodes/<node>.yaml
```

**Important:** Never duplicate array entries (e.g. kernel modules) in both `common.yaml`
and a role patch — `--config-patch` appends arrays.

## Procedure: Fresh Cluster

### 1. Generate Secrets

Only for a **brand new** cluster.

```bash
make -C talos gen-secrets
```

Creates `secrets.yaml` containing cluster CA, etcd certificates, ServiceAccount keys, etc.

Then encrypt with SOPS:

```bash
sops -e -i secrets.yaml
```

### 2. Create Factory Schematics

Schematics define the Talos extensions (DRBD, Intel firmware, NVMe CLI, etc.)
and boot kernel parameters (CPU governor, C-states, IOMMU, security hardening).

```bash
make -C talos schematics
```

This target:
1. Posts `talos-factory-schematic.yaml`, `talos-factory-schematic-gpu.yaml`,
   and `talos-factory-schematic-pi.yaml`
   to the Image Factory API (`factory.talos.dev`)
2. Extracts schematic IDs from the JSON response
3. Writes IDs (`SCHEMATIC_ID`, `GPU_SCHEMATIC_ID`, `PI_SCHEMATIC_ID`) to `.schematic-ids.mk`
(committed, used by `make -C talos gen-configs`)

Install image URLs are constructed at Make time from the schematic IDs + `TALOS_VERSION` (from `talos/versions.mk`):
```
factory.talos.dev/metal-installer/<schematic-id>:$(TALOS_VERSION)
```

### 3. Generate Configs

```bash
make -C talos gen-configs
```

Automatically decrypts `secrets.yaml` via SOPS to `.secrets.dec.yaml` and
generates a complete Talos MachineConfig per node under `generated/`.

Output:
```
generated/controlplane/node-01.yaml   # Control plane nodes
generated/controlplane/node-02.yaml
generated/controlplane/node-03.yaml
generated/worker/node-04.yaml         # Worker nodes
generated/worker/node-05.yaml
generated/worker/node-06.yaml
generated/worker/node-gpu-01.yaml     # GPU worker
generated/worker/node-pi-01.yaml      # Pi worker
```

Post-processing automatically removes the `auto: stable` field from HostnameConfig
(`yq eval-all 'del(select(.kind == "HostnameConfig").auto)'`).

### 4. Validate Configs

```bash
talosctl validate -m metal -c generated/controlplane/node-01.yaml
talosctl validate -m metal -c generated/worker/node-04.yaml
talosctl validate -m metal -c generated/worker/node-gpu-01.yaml
```

### 5. Install Talos on Nodes

Boot nodes with the Talos installer ISO (USB or PXE). Then apply configs
using `make -C talos install-<node>` (applies config with `--insecure` since nodes
have no TLS certificates yet):

```bash
# First control plane node
make -C talos install-node-01
make -C talos bootstrap            # bootstraps etcd on node-01

# Remaining control plane nodes
make -C talos install-node-02
make -C talos install-node-03

# Worker nodes
make -C talos install-node-04
make -C talos install-node-05
make -C talos install-node-06
make -C talos install-node-gpu-01
```

### 6. Retrieve Kubeconfig

```bash
talosctl -n 192.168.2.61 -e 192.168.2.61 kubeconfig --force /tmp/homelab-kubeconfig
export KUBECONFIG=/tmp/homelab-kubeconfig
```

### 7. Verify Cluster Health

```bash
talosctl -n 192.168.2.61 -e 192.168.2.61 health \
    --control-plane-nodes 192.168.2.61,192.168.2.62,192.168.2.63

talosctl -n 192.168.2.61 -e 192.168.2.61 etcd members
kubectl get nodes -o wide
```

## Configuration Overview

### Patch Files in Detail

| File | Contents |
|------|----------|
| `patches/common.yaml` | CNI: none (Cilium), kube-proxy: disabled, KubePrism:7445, DRBD modules, kubelet cert rotation, search domain disabled, **all sysctls** (performance + security), NTP config |
| `patches/controlplane.yaml` | `allowSchedulingOnControlPlanes`, Gateway API experimental CRDs + Cilium bootstrap as `extraManifests`, etcd metrics endpoint args |
| `patches/worker-gpu.yaml` | NVIDIA kernel modules (nvidia, nvidia_uvm, nvidia_modeset, nvidia_drm), `bpf_jit_harden: 1` (override of Talos default 2) |
| `.schematic-ids.mk` | Schematic IDs for standard and GPU images — install image URLs constructed dynamically from IDs + `TALOS_VERSION` |

### Node Files

| File | Contents |
|------|----------|
| `nodes/node-{01..03}.yaml` | Install disk (by-path), static IP, default route, **VIP 192.168.2.60**, DNS, hostname |
| `nodes/node-{04..06}.yaml` | Install disk (by-path), static IP, default route, DNS, hostname (no VIP) |
| `nodes/node-gpu-01.yaml` | Install disk (by-path), static IP, default route, DNS, hostname (no VIP), UserVolumeConfig (NVMe) |
| `nodes/node-pi-01.yaml` | Install disk (by-id USB), static IP `192.168.2.68`, default route, DNS, hostname (edge worker) |

VIP is only configured on control plane nodes (kube-apiserver HA).

### Factory Schematics

| File | Extensions | Notes |
|------|-----------|-------|
| `talos-factory-schematic.yaml` | drbd, gvisor, i915, intel-ucode, nvme-cli | Boot params: performance + security + NVMe/PCIe + IOMMU |
| `talos-factory-schematic-gpu.yaml` | drbd, gvisor, i915, intel-ucode, nvidia-open-gpu-kernel-modules-lts, nvidia-container-toolkit-lts, realtek-firmware | Same boot params + `usbcore.autosuspend=-1`, `iommu.strict=0` (lazy for GPU DMA) |
| `talos-factory-schematic-pi.yaml` | none | Separate ARM profile for Pi edge worker |

Boot kernel parameters (shared by both schematics unless noted):
- **Performance:** `cpufreq.default_governor=performance`, `intel_idle.max_cstate=0`, `processor.max_cstate=0`, `transparent_hugepage=madvise`, `elevator=none`
- **Security:** `mitigations=auto`, `init_on_free=1`, `page_alloc.shuffle=1`, `randomize_kstack_offset=on`, `vsyscall=none`
- **NVMe / PCIe:** `nvme_core.default_ps_max_latency_us=0`, `pcie_aspm=off`, `workqueue.power_efficient=0`
- **IOMMU:** `intel_iommu=on`, `iommu=force`, `iommu.passthrough=0`, `iommu.strict=1`
- **GPU only:** `usbcore.autosuspend=-1` (USB NIC), `iommu.strict=0` (lazy DMA for GPU performance)
