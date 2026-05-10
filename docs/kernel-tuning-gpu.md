# Kernel-Tuning: GPU Worker (node-gpu-01)

> **Scope:** node-gpu-01 (BTC B250C mining board, 3x NVIDIA GA104)
> **Created:** 2026-02-28 | **Updated:** 2026-03-24
> **Talos:** v1.12.6 | **Kubernetes:** v1.35.0 | **Cilium:** v1.19.0 (eBPF kube-proxy replacement)
> **Companion document:** [kernel-tuning.md](kernel-tuning.md) covers node-01 through node-06

---

## Table of Contents

1. [Hardware Profile](#1-hardware-profile)
2. [PCI Device Inventory](#2-pci-device-inventory)
3. [USB Device Inventory](#3-usb-device-inventory)
4. [NFD Feature Summary](#4-nfd-feature-summary)
5. [CPU Vulnerability Matrix (Kaby Lake)](#5-cpu-vulnerability-matrix-kaby-lake)
6. [Current Configuration State](#6-current-configuration-state)
7. [Boot Parameter Gap Analysis](#7-boot-parameter-gap-analysis)
8. [GPU-Specific Considerations](#8-gpu-specific-considerations)
9. [Recommendations](#9-recommendations)
10. [Verification](#10-verification)
11. [Sources](#11-sources)

---

## 1. Hardware Profile

node-gpu-01 is a repurposed cryptocurrency mining rig. The BTC B250C is a mining-specific
motherboard with multiple PCIe x1 slots (typically used with risers). It runs 3x NVIDIA
GA104 GPUs for compute workloads.

### System Overview

| Property | Value |
|----------|-------|
| Board | BTC B250C (mining motherboard) |
| Vendor | OEM |
| CPU | Intel Core i7-7700K @ 4.20GHz (Kaby Lake, Family 6, Model 158, Stepping 9) |
| Cores/Threads | 4C / 8T (Hyper-Threading enabled) |
| Microcode | 0xf8 (updated at boot via intel-ucode extension) |
| RAM | 31.1 GiB DDR4 (non-ECC, single-channel likely) |
| Swap | None |
| NUMA | Not present (single socket) |
| Boot Disk | `/dev/sda` — Intenso 240GB SSD (SATA, rotational=0), mq-deadline scheduler |
| Data Disk | `/dev/sdb` — SanDisk Ultra 3D 500GB SSD (SATA, rotational=0), XFS UserVolume `local-storage` (WWN: naa.5001b444a5673347) |
| NVMe | None |
| Active NIC | enp0s20f0u2 — USB 3.0 Realtek RTL8153 GbE (r8152 driver), MAC 00:e0:3c:68:46:45 |
| Unused NIC | enp4s0 — PCIe Realtek RTL8136 Fast Ethernet (r8169 driver), operstate=down |
| GPUs | 3x NVIDIA GA104 (PCIe slots 01:00.0, 02:00.0, 03:00.0) |
| iGPU | Intel HD Graphics 630 (00:02.0, i915 driver) |
| Kernel | Linux 6.18.18-talos |

### Key Differences vs Standard Nodes (M710q/M920q)

| Attribute | Standard Nodes (node-01..06) | GPU Worker (node-gpu-01) | Impact |
|-----------|------------------------------|--------------------------|--------|
| Motherboard | Lenovo ThinkCentre (OEM quality) | BTC B250C (mining board) | PCIe ASPM unreliable on mining boards |
| CPU | Skylake/Coffee Lake (various) | Kaby Lake i7-7700K | Same vulnerability surface as Skylake |
| Boot Disk | SATA SSD | SATA SSD (Intenso 240GB) | Same type, smaller capacity |
| Data Disk | NVMe (PCIe 3.0 x2/x4) | SATA SSD (SanDisk 500GB) | Lower throughput, no NVMe optimizations |
| NIC | Intel I219-V/LM (e1000e), PCIe | Realtek RTL8153 (r8152), USB 3.0 | USB NIC = higher CPU overhead, no hardware offloads |
| GPUs | None (or iGPU only) | 3x NVIDIA GA104 + iGPU | IOMMU groups, PCIe bandwidth, DMA considerations |
| Factory Schematic | `talos-factory-schematic.yaml` | `talos-factory-schematic-gpu.yaml` | Separate schematic with NVIDIA extensions |
| Role Patch | `controlplane.yaml` (CP) / none (workers) | `worker-gpu.yaml` | NVIDIA modules, bpf_jit_harden override |

### Storage Profile

| Device | Type | Scheduler | Role | Notes |
|--------|------|-----------|------|-------|
| `/dev/sda` | SSD (Intenso 240GB) | mq-deadline | Boot disk (Talos install) | SATA, `pci-0000:00:17.0-ata-3` |
| `/dev/sdb` | SSD (SanDisk Ultra 3D 500GB) | mq-deadline | Data (LINSTOR/DRBD, XFS UserVolume) | WWN: naa.5001b444a5673347 |

**Note on I/O scheduler:** The schematic configures `elevator=none` which targets single-queue
devices. Both SATA SSDs use multi-queue `mq-deadline` by default, which is appropriate. No
action needed — the scheduler selection is correct.

### Network Profile

| Interface | Driver | Type | Speed | Status | Notes |
|-----------|--------|------|-------|--------|-------|
| enp0s20f0u2 | r8152 | USB 3.0 Gigabit Ethernet | 1000 Mbps | UP | Primary NIC, Realtek RTL8153 chipset |
| enp4s0 | r8169 | PCIe Fast Ethernet | — | DOWN | Realtek RTL8136, unused |

**USB NIC considerations:**
- Higher CPU overhead than PCIe NICs (USB protocol stack in kernel)
- No hardware TCP/UDP checksum offload (CPU must compute checksums)
- Latency slightly higher than PCIe NICs (~50-100µs additional)
- Adequate for 1 GbE throughput but not optimal for latency-sensitive workloads
- MAC address `00:e0:3c:68:46:45` pinned in `nodes/node-gpu-01.yaml` via `hardwareAddr`

---

## 2. PCI Device Inventory

| BDF | Vendor:Device | Class | Description |
|-----|---------------|-------|-------------|
| 0000:00:00.0 | 8086:591f | 0600 | Intel Host Bridge (Kaby Lake-H) |
| 0000:00:01.0 | 8086:1901 | 0604 | PCIe Root Port (x16 slot) |
| 0000:00:02.0 | 8086:5912 | 0300 | Intel HD Graphics 630 (iGPU) |
| 0000:00:04.0 | 8086:xxxx | — | Intel DPTF Thermal Management |
| 0000:00:14.0 | 8086:xxxx | — | Intel USB 3.0 xHCI Host Controller |
| 0000:00:16.0 | 8086:xxxx | — | Intel Management Engine Interface |
| 0000:00:17.0 | 8086:xxxx | — | Intel AHCI SATA Controller |
| 0000:00:1b.0 | 8086:xxxx | 0604 | PCIe Root Port (GPU slot 2) |
| 0000:00:1b.7 | 8086:xxxx | 0604 | PCIe Root Port (GPU slot 3) |
| 0000:00:1c.0 | 8086:xxxx | 0604 | PCIe Root Port (Ethernet) |
| 0000:00:1f.0 | 8086:xxxx | — | Intel LPC/ISA Bridge |
| 0000:00:1f.2 | 8086:xxxx | — | Intel PMC (Power Management Controller) |
| 0000:00:1f.4 | 8086:xxxx | — | Intel SMBus Controller |
| **0000:01:00.0** | **10de:2484** | **0300** | **NVIDIA GA104** (RTX 3070-class), subsystem 10de:146b |
| 0000:01:00.1 | 10de:228b | 0403 | NVIDIA GA104 HD Audio |
| **0000:02:00.0** | **10de:2486** | **0300** | **NVIDIA GA104** (RTX 3060Ti/3070-class), subsystem 10de:147a |
| 0000:02:00.1 | 10de:228b | 0403 | NVIDIA GA104 HD Audio |
| **0000:03:00.0** | **10de:2486** | **0300** | **NVIDIA GA104** (RTX 3060Ti/3070-class), subsystem 10de:147a |
| 0000:03:00.1 | 10de:228b | 0403 | NVIDIA GA104 HD Audio |
| 0000:04:00.0 | 10ec:8136 | 0200 | Realtek RTL8136 PCIe Fast Ethernet (unused) |

### IOMMU Groups

| Group | Devices | Notes |
|-------|---------|-------|
| 0 | 0000:00:02.0 (Intel iGPU) | Isolated |
| 1 | 0000:00:00.0 (Host Bridge) | — |
| 2 | 0000:00:01.0 + 0000:01:00.0 + 0000:01:00.1 | PCIe bridge + GPU 0 + Audio |
| 13–15 | GPUs 1, 2, additional slots | One GPU per group |

---

## 3. USB Device Inventory

| Vendor:Device | Class | Serial | Description |
|---------------|-------|--------|-------------|
| 0bda:8153 | ff | D01300E03C684645 | Realtek RTL8153 USB GbE (active NIC) |
| 0930:6545 | 08 (storage) | 001D92AD6BA9B950D32B0531 | Kingston USB storage |
| 1a86:e2e3 | 03 (HID) | — | QinHeng HID device |
| 046a:0011 | 03 (HID) | — | Cherry keyboard/HID |
| 1d6b:0002 | 09 (hub) | — | Linux Foundation USB 2.0 Hub |
| 1d6b:0003 | 09 (hub) | — | Linux Foundation USB 3.0 Hub |

---

## 4. NFD Feature Summary

Key NFD labels and features discovered on node-gpu-01:

### CPU Features

| Feature | Value | Notes |
|---------|-------|-------|
| cpu-model.vendor_id | Intel | — |
| cpu-model.family | 6 | — |
| cpu-model.id | 158 | Kaby Lake |
| cpu-hardware_multithreading | true | HT active (4C/8T) |
| cpu-pstate.scaling_governor | performance | Schematic boot params applied (governor=performance) |
| cpu-pstate.status | active | Intel P-State driver active |
| cpu-pstate.turbo | false | **Turbo Boost disabled in BIOS** (BIOS change recommended) |
| cpu-security.sgx.enabled | true | SGX active, EPC=98041856 bytes (~93MB) |
| cpu-security.sev.* | true | Incorrect — AMD SEV not available on Intel, NFD false positive |

### Relevant CPUID Flags

`ADX`, `AESNI`, `AVX`, `AVX2`, `FLUSH_L1D`, `FMA3`, `IA32_ARCH_CAP`, `IBPB`,
`MD_CLEAR`, `MPX`, `RTM_ALWAYS_ABORT`, `SPEC_CTRL_SSBD`, `SRBDS_CTRL`, `STIBP`, `VMX`

### Storage & Memory

| Feature | Value | Notes |
|---------|-------|-------|
| storage-nonrotationaldisk | present | At least one SSD detected |
| memory.numa.is_numa | false | Single socket |
| memory.swap.enabled | false | No swap |
| memory.hugepages.enabled | false | No hugepages allocated |

### PCI & USB Signatures

| Feature | Meaning |
|---------|---------|
| pci-0300_10de.present | NVIDIA GPU (class 0300, vendor 10de) |
| pci-0300_8086.present | Intel iGPU (class 0300, vendor 8086) |
| usb-ff_0bda_8153.present | Realtek USB Ethernet adapter |

---

## 5. CPU Vulnerability Matrix (Kaby Lake)

The i7-7700K (Kaby Lake, Stepping 9) shares the same Skylake microarchitecture as
the standard nodes. It has the same vulnerability surface.

| Vulnerability | CVE(s) | Status on node-gpu-01 | Notes |
|--------------|--------|------------------------|-------|
| **Meltdown** | CVE-2017-5754 | Mitigation: PTI | Page Table Isolation active |
| **Spectre v1** | CVE-2017-5753 | Mitigation: usercopy/swapgs barriers | Always active |
| **Spectre v2** | CVE-2017-5715 | Mitigation: IBRS; IBPB: conditional; STIBP: conditional; RSB filling | — |
| **Spec Store Bypass (v4)** | CVE-2018-3639 | Mitigation: SSBD via prctl | — |
| **L1TF (Foreshadow)** | CVE-2018-3615/20/46 | Mitigation: PTE Inversion; VMX: conditional cache flushes, **SMT vulnerable** | HT active |
| **MDS (Zombieload)** | CVE-2018-12126/7/30, CVE-2019-11091 | Mitigation: Clear CPU buffers; **SMT vulnerable** | HT active |
| **TAA** | CVE-2019-11135 | Mitigation: TSX disabled | TSX completely disabled |
| **SRBDS (CrossTalk)** | CVE-2020-0543 | Mitigation: Microcode | Via intel-ucode extension |
| **MMIO Stale Data** | CVE-2022-21123/5/6 | Mitigation: Clear CPU buffers; **SMT vulnerable** | HT active |
| **Retbleed** | — | Mitigation: IBRS | — |
| **Downfall (GDS)** | CVE-2022-40982 | Mitigation: Microcode | Microcode-based fix |
| **ITLB Multihit** | — | KVM: Mitigation: Split huge pages | — |
| **vmscape** | — | Mitigation: IBPB before exit to userspace | — |
| Ghostwrite | — | Not affected | — |
| Indirect Target Selection | — | Not affected | — |
| Old Microcode | — | Not affected | Microcode 0xf8 is current |
| Reg File Data Sampling | — | Not affected | — |
| Spec RStack Overflow | — | Not affected | — |
| TSA | — | Not affected | — |

**"SMT vulnerable" entries** indicate that L1TF, MDS, and MMIO Stale Data cross-thread
attack vectors remain open because Hyper-Threading is active. `nosmt` would eliminate these
but costs 20-30% throughput on a 4C CPU. Acceptable risk in an isolated homelab network
(same decision as standard nodes — see kernel-tuning.md Section 5.5).

---

## 6. Current Configuration State

### Patch Chain

```
patches/common.yaml → patches/worker-gpu.yaml → nodes/node-gpu-01.yaml
```

### Sysctls (from worker-gpu.yaml)

| Sysctl | Value | Talos Default | Purpose |
|--------|-------|---------------|---------|
| `net.core.netdev_budget` | `600` | `300` | USB NIC NAPI budget — process more packets per poll cycle to reduce RX drops on r8152 |
| `net.core.netdev_budget_usecs` | `8000` | `2000` | USB NIC NAPI time budget — allow 4x more time per poll for USB protocol overhead |

The `bpf_jit_harden` override (previously `1`) was removed — Talos default (`2`) now applies.
All other sysctls are inherited from `patches/common.yaml` (see kernel-tuning.md Sections 4-5).

### Kernel Modules (from worker-gpu.yaml)

| Module | Parameters | Purpose |
|--------|------------|---------|
| nvidia | `NVreg_UsePageAttributeTable=1`, `NVreg_DynamicPowerManagement=0` | NVIDIA GPU kernel driver with PAT and no dynamic PM |
| nvidia_uvm | — | Unified Virtual Memory (CUDA) |
| nvidia_modeset | — | Mode-setting support |
| nvidia_drm | — | DRM integration |

DRBD modules (`drbd`, `drbd_transport_tcp`) are loaded via `patches/common.yaml`.

### Installed Extensions

| Extension | Version | Purpose |
|-----------|---------|---------|
| drbd | 9.2.16-v1.12.6 | DRBD kernel module for LINSTOR |
| gvisor | 20260202.0 | gVisor sandbox runtime |
| i915 | 20260309-v1.12.6 | Intel iGPU driver firmware |
| intel-ucode | 20260227 | Intel CPU microcode updates |
| nvidia-open-gpu-kernel-modules-lts | 580.126.20-v1.12.6 | NVIDIA open kernel modules |
| nvidia-container-toolkit-lts | 580.126.20-v1.18.2 | NVIDIA container runtime |
| realtek-firmware | 20260309 | Realtek USB NIC firmware (RTL8153) |

### NVIDIA Driver Status

- Driver version: 580.126.20 (Open Kernel Module)
- All 3 GPUs registered as DRM devices (minor 1, 2, 3)
- nvidia-persistenced running
- Kubernetes resource: `nvidia.com/gpu: 3` (allocatable and capacity)
- Node taint: `nvidia.com/gpu=present:NoSchedule`

### Verified Sysctl Values (2026-03-24)

Key values read from the live node — all match configuration:

| Category | Sysctl | Configured | Live Value | Match |
|----------|--------|------------|------------|-------|
| Storage I/O | vm.dirty_ratio | 10 | 10 | Yes |
| Storage I/O | vm.dirty_background_ratio | 5 | 5 | Yes |
| Memory | vm.overcommit_memory | 1 | 1 | Yes |
| Memory | vm.max_map_count | 524288 | 524288 | Yes |
| Memory | vm.min_free_kbytes | 65536 | 65536 | Yes |
| TCP Buffer | net.core.rmem_max | 16777216 | 16777216 | Yes |
| TCP Buffer | net.core.wmem_max | 16777216 | 16777216 | Yes |
| TCP | net.ipv4.tcp_slow_start_after_idle | 0 | 0 | Yes |
| Backlog | net.core.somaxconn | 32768 | 32768 | Yes |
| Backlog | net.core.netdev_max_backlog | 16384 | 16384 | Yes |
| Conntrack | net.netfilter.nf_conntrack_max | 131072 | 131072 | Yes |
| Security | net.ipv4.conf.all.rp_filter | 0 | 0 | Yes |
| Security | kernel.kexec_load_disabled | 1 | 1 | Yes |
| BPF | net.core.bpf_jit_harden | — | 2 | Talos default (override removed) |
| Limits | kernel.pid_max | 4194304 | 4194304 | Yes |
| Limits | fs.inotify.max_user_watches | 524288 | 524288 | Yes |
| NAPI | net.core.netdev_budget | 600 | 600 | Yes |
| NAPI | net.core.netdev_budget_usecs | 8000 | 8000 | Yes |

---

## 7. Boot Parameter Gap Analysis

The GPU factory schematic (`talos-factory-schematic-gpu.yaml`) defines 20 extraKernelArgs.
As of 2026-03-25, the node has been upgraded with the full schematic and **all parameters
are applied**.

### Configured vs Applied (2026-03-24)

| Boot Parameter | In Schematic | In /proc/cmdline | Status |
|----------------|:------------:|:----------------:|--------|
| `cpufreq.default_governor=performance` | Yes | Yes | Applied |
| `intel_idle.max_cstate=0` | Yes | Yes | Applied |
| `processor.max_cstate=0` | Yes | Yes | Applied |
| `transparent_hugepage=madvise` | Yes | Yes | Applied |
| `elevator=none` | Yes | Yes | Applied |
| `mitigations=auto` | Yes | Yes | Applied |
| `init_on_free=1` | Yes | Yes | Applied |
| `page_alloc.shuffle=1` | Yes | Yes | Applied |
| `randomize_kstack_offset=on` | Yes | Yes | Applied |
| `vsyscall=none` | Yes | Yes | Applied |
| `nvme_core.default_ps_max_latency_us=0` | Yes | Yes | Applied |
| `pcie_aspm=off` | Yes | Yes | Applied |
| `workqueue.power_efficient=0` | Yes | Yes | Applied |
| `usbcore.autosuspend=-1` | Yes | Yes | Applied |
| `intel_iommu=on` | Yes | Yes | Applied |
| `iommu=force` | Yes | Yes | Applied |
| `iommu.passthrough=0` | Yes | Yes | Applied |
| `iommu.strict=0` | Yes | Yes | Applied (lazy/DMA-FQ mode) |
| `pci=noaer` | Yes | Yes | Applied (2026-03-25) |
| `rcutree.rcu_idle_gp_delay=1` | Yes | Yes | Applied (2026-03-25) |

All boot parameters are now applied. No action required.

### 7.1 USB NIC RX Drop Root Cause Analysis (2026-03-25)

The `rx_dropped` counter on `enp0s20f0u2` shows a steady ~2 drops/sec. Investigation
confirmed these are **benign L2 broadcast frames with no registered kernel protocol handler**,
not actual packet loss.

**Evidence:**
- `softnet_stat`: 0 drops and 0 time_squeeze on all 8 CPUs — NAPI budget is not exhausted
- `rx_missed_errors`, `rx_fifo_errors`, `rx_over_errors`: all 0 — no hardware-level drops
- `rx_nohandler`: 0 (these are counted in `rx_dropped` instead)
- Hubble `--verdict DROPPED`: no BPF policy drops on the GPU node
- IP-layer `InDiscards`: 0 — no protocol-stack drops

**Root cause — unhandled L2 broadcast protocols from network devices:**

| EtherType | Protocol | Source MAC | Rate | Device |
|-----------|----------|------------|------|--------|
| `0x88e1` | HomePlug AV (Powerline) | `48:5d:35:24:5d:a8` | ~1/s | Powerline adapter |
| `0x8912` | LLDP (Link Layer Discovery) | `48:5d:35:24:5d:a8`, `c2:39:6f:8b:e5:c9` | ~2/s | Switch/adapter |
| `0x8899` | RRCP (Realtek Remote Control) | `54:07:7d:20:b0:53` | ~0.5/s | Realtek switch |

These are broadcast frames from switches and powerline adapters on the same L2 segment.
Linux has no protocol handler for these EtherTypes, so the kernel increments `rx_dropped`
when delivering them to the network stack. This is expected behavior and not indicative of
NIC or driver performance issues.

**Conclusion:** The NAPI budget tuning (`netdev_budget=600`, `netdev_budget_usecs=8000`) is
not needed for drop mitigation but is kept as a reasonable default for a USB NIC with higher
per-packet overhead. The `rx_dropped` counter on this node can be safely ignored — it tracks
benign L2 broadcast noise, not real packet loss.

**Optional mitigation (not recommended):** The drops could be eliminated by filtering these
EtherTypes at the switch level (if the switch supports ACLs) or by adding a TC ingress filter
to silently drop them before they reach the kernel stack. However, since they cause no harm
and are ~3.5 frames/sec total, filtering adds unnecessary complexity.

---

## 8. GPU-Specific Considerations

### 8.1 IOMMU: Strict vs Lazy Mode

The standard factory schematic uses `iommu.strict=1` (strict TLB invalidation). The GPU
schematic uses `iommu.strict=0` (lazy/DMA-FQ mode) — **implemented**.

**Rationale for lazy mode on GPU node:**
- Strict mode: every DMA unmap triggers immediate IOTLB invalidation — measurable overhead
  with 3 GPUs doing heavy DMA operations (CUDA memory transfers)
- Lazy mode: batches IOTLB invalidations using a flush queue — significantly lower overhead
- Acceptable security trade-off: the GPUs are trusted devices, not hotplugged
- Confirmed active via dmesg: `iommu: DMA domain TLB invalidation policy: lazy mode`

### 8.2 PCIe ASPM (Active State Power Management)

The BTC B250C is a mining motherboard. Mining boards are known for:
- Unreliable ASPM implementation (power management not a priority in mining)
- Multiple PCIe slots running at x1 via risers (ASPM can cause link instability)
- Non-standard PCIe power delivery

**Status:** `pcie_aspm=off` is in the GPU schematic and applied — **implemented**.

### 8.3 NVIDIA Kernel Module Parameters

The NVIDIA open kernel module parameters are configured in `worker-gpu.yaml` under
`machine.kernel.modules` — **implemented**.

| Parameter | Value | Purpose |
|-----------|-------|---------|
| `NVreg_UsePageAttributeTable=1` | Enable PAT | Improved GPU memory caching via x86 Page Attribute Table. NVIDIA-recommended for Linux. Better write-combining for framebuffer access. |
| `NVreg_DynamicPowerManagement=0` | Disable dynamic PM | Keep GPUs at full power. Appropriate for always-on server — avoids wake latency on inference requests. |

The module parameter approach (vs boot parameters) is preferred — it's specific to the GPU
role patch and doesn't pollute the schematic.

### 8.4 Turbo Boost (BIOS)

NFD reports `cpu-pstate.turbo=false`. The i7-7700K supports Turbo Boost to 4.5 GHz (base
4.2 GHz). Turbo Boost is disabled in the BTC B250C BIOS.

**Recommendation:** Enable Turbo Boost in BIOS. Free 7% single-core performance increase
with no configuration changes needed. The `performance` governor (now applied) keeps the CPU
at max frequency, and Turbo Boost would allow it to reach 4.5 GHz. Requires physical access.

### 8.5 bpf_jit_harden Override — Removed

The `bpf_jit_harden` override (previously `1` in `worker-gpu.yaml`) has been **removed**.
The Talos default (`2`) now applies — constant blinding for ALL users including root.

This is the correct security posture. The performance impact of value `2` on BPF JIT
compilation is negligible (nanoseconds per BPF program load). See kernel-tuning.md Section 7.

### 8.6 USB NIC NAPI Budget Tuning

node-gpu-01 uses a USB Realtek RTL8153 as its primary NIC. USB NICs have fundamentally
higher per-packet processing overhead than PCIe NICs due to the USB protocol stack:
- Each packet traverses the USB host controller, URB allocation, and USB completion handlers
- No hardware interrupt coalescing or checksum offload
- ~3-5x more CPU cycles per packet than Intel e1000e

The default NAPI budget (`netdev_budget=300`, `netdev_budget_usecs=2000`) can exhaust before
all queued RX frames are processed, causing kernel-level drops. The hardware analysis
(2026-03-24) measured **7.9% RX drop rate** (34,819 / 439,221 packets).

**Mitigation:** `worker-gpu.yaml` sets:
- `net.core.netdev_budget: "600"` — process 2x more packets per NAPI poll cycle
- `net.core.netdev_budget_usecs: "8000"` — allow 4x more time per poll (8ms vs 2ms)

These are GPU-node-specific because only node-gpu-01 has a USB NIC. Standard nodes use
Intel e1000e (PCIe) which handles the default budget efficiently.

**Note:** Persistent ethtool tuning (rx-copybreak, ring buffers, flow control) is not
possible in Talos without udev rules. Sysctls are the only persistent tuning path.

---

## 9. Recommendations

### 9.1 Completed

| Change | Status | Date |
|--------|--------|------|
| `iommu.strict=0` in GPU schematic | Implemented | 2026-02 |
| `pcie_aspm=off` in GPU schematic | Implemented | 2026-02 |
| `NVreg_UsePageAttributeTable=1` module param | Implemented | 2026-02 |
| `NVreg_DynamicPowerManagement=0` module param | Implemented | 2026-02 |
| Remove `bpf_jit_harden` override | Implemented | 2026-03 |
| Schematic upgrade (boot params applied) | Implemented | 2026-03 |
| USB NIC NAPI budget tuning (`netdev_budget`, `netdev_budget_usecs`) | Implemented | 2026-03-24 |
| PCIe riser stability boot params (`pci=noaer`, `rcutree.rcu_idle_gp_delay=1`) | Implemented | 2026-03-25 |
| RX drop root cause analysis — benign L2 broadcasts, not NIC issue | Documented | 2026-03-25 |

### 9.2 BIOS Changes (manual, requires physical access)

| Setting | Current | Recommended | Rationale |
|---------|---------|-------------|-----------|
| Intel Turbo Boost | Disabled | **Enable** | Free 7% performance (4.2 -> 4.5 GHz) |
| PCIe ASPM | Unknown | **Disable** (if option exists) | Belt-and-suspenders with `pcie_aspm=off` boot param |
| VT-d | Enabled | Keep enabled | IOMMU already active and working |

### 9.4 Not Recommended for GPU Node

| Parameter | Why Not |
|-----------|---------|
| `nosmt` | 4C -> 4T on i7-7700K = 50% thread loss. Cross-thread attacks require local privilege. |
| `mitigations=off` | All mitigations active and appropriate. 5-15% gain not worth security exposure. |
| `iommu.strict=1` | Too much DMA overhead with 3 GPUs. See Section 8.1. |
| `lockdown=integrity` | Would block NVIDIA out-of-tree modules. |
| `kernel.modules_disabled=1` | NVIDIA and DRBD modules loaded dynamically. |
| `NVreg_EnableResizableBar=1` | GPUs on PCIe x1 risers — no effect without adequate lane width. |
| `NVreg_PreserveVideoMemoryAllocations=1` | Server never suspends. No benefit. |
| `net.ipv4.tcp_congestion_control=bbr` | LAN-only DRBD replication; cubic is better at <1ms RTT. |
| r8152 ethtool tuning | Cannot persist ethtool settings in Talos without udev rules. |

---

## 10. Verification

After applying config changes and upgrade:

```bash
# Verify NAPI budget sysctls (after talosctl apply-config)
talosctl -n 192.168.2.67 -e 192.168.2.67 read /proc/sys/net/core/netdev_budget
# Should be 600
talosctl -n 192.168.2.67 -e 192.168.2.67 read /proc/sys/net/core/netdev_budget_usecs
# Should be 8000

# Verify missing boot parameters (after talosctl upgrade)
talosctl -n 192.168.2.67 -e 192.168.2.67 read /proc/cmdline | tr ' ' '\n' | grep -E 'pci=|rcutree'
# Should show: pci=noaer and rcutree.rcu_idle_gp_delay=1

# USB NIC RX drop counter (see Section 7.1 — these are benign L2 broadcast frames)
talosctl -n 192.168.2.67 -e 192.168.2.67 read /proc/net/dev | grep enp0s20f0u2

# BPF JIT harden (should be 2 — Talos default)
talosctl -n 192.168.2.67 -e 192.168.2.67 read /proc/sys/net/core/bpf_jit_harden

# Turbo Boost (after BIOS change, if applied)
talosctl -n 192.168.2.67 -e 192.168.2.67 read /sys/devices/system/cpu/intel_pstate/no_turbo
# Should be 0 (turbo enabled)
```

---

## 11. Sources

### Hardware
- [BTC B250C specifications](https://www.biostar.com.tw/app/en/mb/introduction.php?S_ID=895) — Mining motherboard datasheet
- [Intel i7-7700K specifications](https://ark.intel.com/content/www/us/en/ark/products/97129/intel-core-i7-7700k-processor-8m-cache-up-to-4-50-ghz.html) — Kaby Lake, 4C/8T, 4.2-4.5 GHz
- [Intel B250 Chipset](https://ark.intel.com/content/www/us/en/ark/products/98420/intel-b250-chipset.html) — PCIe 3.0, VT-d support

### NVIDIA / GPU
- [NVIDIA Open GPU Kernel Modules](https://github.com/NVIDIA/open-gpu-kernel-modules) — Open-source kernel driver
- [NVIDIA Linux Driver README — Module Parameters](https://download.nvidia.com/XFree86/Linux-x86_64/580.126.16/README/openrmkernel.html) — NVreg_UsePageAttributeTable documentation
- [NVIDIA GA104 (Ampere)](https://www.techpowerup.com/gpu-specs/nvidia-ga104.g906) — GPU die specifications

### IOMMU / PCIe
- [Linux IOMMU Documentation](https://docs.kernel.org/driver-api/iommu.html) — strict vs lazy mode
- [PCIe ASPM on multi-GPU systems](https://wiki.archlinux.org/title/Power_management#PCI_Runtime_Power_Management) — ASPM disable rationale
- [VFIO / IOMMU Groups](https://docs.kernel.org/driver-api/vfio.html) — PCI device grouping

### Talos / Kernel (shared with kernel-tuning.md)
- [Talos KSPP Source Code (kspp.go)](https://github.com/siderolabs/talos/blob/main/pkg/kernel/kspp/kspp.go)
- [Talos Kernel Reference](https://docs.siderolabs.com/talos/v1.12/reference/kernel)
- [Linux Kernel VM Documentation](https://docs.kernel.org/admin-guide/sysctl/vm.html)
- [Linux Spectre Documentation](https://docs.kernel.org/admin-guide/hw-vuln/spectre.html)
