# Hardware Analysis: node-02

> **Date:** 2026-02-28
> **Talos:** v1.12.4 | **Kubernetes:** v1.35.0
> **Node IP:** 192.168.2.62 | **Role:** control-plane

---

## 1. System Overview

| Property | Value |
|----------|-------|
| Vendor | Lenovo |
| Product | 10MQS7QB00 (ThinkCentre M910q Tiny) |
| Board | 3111 |
| CPU | Intel Core i5-7400T @ 2.40GHz (Kaby Lake, family 6 model 158 stepping 9) |
| Cores/Threads | 4C/4T (no Hyper-Threading) |
| Microcode | 0xf8 |
| L3 Cache | 6 MB |
| RAM | 32 GB DDR4 (32,735,336 KB) |
| Boot Disk | INTENSO SSD ~128 GB (sda, SATA) |
| Data Disk | Samsung MZVLW256HEHP-000H1 ~256 GB (nvme0n1, NVMe PCIe) |
| Active NIC | enp0s31f6 (Intel I219-LM, 1 Gbps, MAC 6c:4b:90:69:53:e2) |
| NUMA Nodes | 1 (node0) |
| GPU | Intel HD Graphics 630 (integrated, 8086:5912) |

## 2. PCI Device Inventory

| BDF | Vendor:Device | Class | Description |
|-----|---------------|-------|-------------|
| 00:00.0 | 8086:591f | 0600 (Host Bridge) | Intel Kaby Lake Host Bridge/DRAM Registers |
| 00:02.0 | 8086:5912 | 0300 (VGA) | Intel HD Graphics 630 |
| 00:14.0 | 8086:a2af | 0c03 (USB) | Intel 200 Series USB 3.0 xHCI Controller |
| 00:14.2 | 8086:a2b1 | 1180 (Signal Processing) | Intel 200 Series Thermal Subsystem |
| 00:16.0 | 8086:a2ba | 0780 (Communication) | Intel 200 Series ME Interface |
| 00:17.0 | 8086:a282 | 0106 (SATA/AHCI) | Intel 200 Series SATA Controller (AHCI) |
| 00:1b.0 | 8086:a2eb | 0604 (PCI Bridge) | Intel 200 Series PCIe Root Port |
| 00:1f.0 | 8086:a2c8 | 0601 (ISA Bridge) | Intel 200 Series LPC Controller |
| 00:1f.2 | 8086:a2a1 | 0580 (Memory Controller) | Intel 200 Series PMC |
| 00:1f.4 | 8086:a2a3 | 0c05 (SMBus) | Intel 200 Series SMBus Controller |
| 00:1f.6 | 8086:15b8 | 0200 (Ethernet) | Intel I219-LM Ethernet |
| 01:00.0 | 144d:a804 | 0108 (NVMe) | Samsung MZVLW256HEHP NVMe SSD |

All PCI devices have IOMMU enabled (intel-iommu v1:0, DMA domain type).

## 3. USB Device Inventory

| Vendor:Device | Class | Serial | Description |
|---------------|-------|--------|-------------|
| 1d6b:0002 | 09 (Hub) | 0000:00:14.0 | Linux Foundation USB 2.0 Root Hub |
| 1d6b:0003 | 09 (Hub) | 0000:00:14.0 | Linux Foundation USB 3.0 Root Hub |

No external USB devices detected.

## 4. NFD Feature Highlights

### CPU
- **Architecture:** amd64, Intel Kaby Lake (family 6, model 158)
- **Instruction Sets:** SSE, SSE2, SSE4.1, SSE4.2, AVX, AVX2, FMA3, AES-NI, ADX
- **Virtualization:** VMX (VT-x) supported
- **Multithreading:** No HT (4 physical cores only)
- **P-State:** Active, governor = performance, turbo = enabled
- **C-States:** Disabled (intel_idle.max_cstate=0, processor.max_cstate=0)
- **Security:** IBPB, STIBP, SSBD, FLUSH_L1D, MD_CLEAR, SRBDS_CTRL

### Storage
- Non-rotational disk present (SSD/NVMe)

### Kernel
- Version: 6.18.9-talos
- Config: NO_HZ=y, NO_HZ_IDLE=y (tickless idle)
- CPU_FREQ_GOV_PERFORMANCE=y, CPU_FREQ_GOV_SCHEDUTIL=y

### Memory
- Hugepages: disabled (0x 1Gi, 0x 2Mi)
- NUMA: single node (not NUMA)
- Swap: disabled

### PCI Features
- `pci-0300_8086.present: true` -- Intel integrated GPU detected

## 5. CPU Vulnerability Status

| Vulnerability | Status |
|---------------|--------|
| gather_data_sampling | Mitigation: Microcode |
| ghostwrite | Not affected |
| indirect_target_selection | Not affected |
| itlb_multihit | KVM: Mitigation: Split huge pages |
| l1tf | Mitigation: PTE Inversion; VMX: conditional cache flushes, SMT disabled |
| mds | Mitigation: Clear CPU buffers; SMT disabled |
| meltdown | Mitigation: PTI |
| mmio_stale_data | Mitigation: Clear CPU buffers; SMT disabled |
| old_microcode | Not affected |
| reg_file_data_sampling | Not affected |
| retbleed | Mitigation: IBRS |
| spec_rstack_overflow | Not affected |
| spec_store_bypass | Mitigation: Speculative Store Bypass disabled via prctl |
| spectre_v1 | Mitigation: usercopy/swapgs barriers and __user pointer sanitization |
| spectre_v2 | Mitigation: IBRS; IBPB: conditional; STIBP: disabled; RSB filling; PBRSB-eIBRS: Not affected; BHI: Not affected |
| srbds | Mitigation: Microcode |
| tsa | Not affected |
| tsx_async_abort | Not affected |
| vmscape | Mitigation: IBPB before exit to userspace |

All known vulnerabilities are mitigated. Kaby Lake is not affected by newer vulnerabilities (ghostwrite, TSA, spec_rstack_overflow, indirect_target_selection, reg_file_data_sampling).

## 6. Current Kernel Parameters

### 6.1 Boot Parameters (/proc/cmdline)

| Parameter | Value |
|-----------|-------|
| talos.platform | metal |
| console | tty0 |
| init_on_alloc | 1 |
| slab_nomerge | (enabled) |
| pti | on |
| consoleblank | 0 |
| nvme_core.io_timeout | 4294967295 |
| printk.devkmsg | on |
| selinux | 1 |
| module.sig_enforce | 1 |
| cpufreq.default_governor | performance |
| intel_idle.max_cstate | 0 |
| processor.max_cstate | 0 |
| transparent_hugepage | madvise |
| elevator | none |
| mitigations | auto |
| init_on_free | 1 |
| page_alloc.shuffle | 1 |
| randomize_kstack_offset | on |
| vsyscall | none |
| nvme_core.default_ps_max_latency_us | 0 |
| pcie_aspm | off |
| workqueue.power_efficient | 0 |
| intel_iommu | on |
| iommu | force |
| iommu.passthrough | 0 |
| iommu.strict | 1 |

### 6.2 Configured Boot Parameters (from factory schematic)

| Parameter | Purpose |
|-----------|---------|
| cpufreq.default_governor=performance | Force performance CPU governor |
| intel_idle.max_cstate=0 | Disable deep C-states |
| processor.max_cstate=0 | Disable processor C-states |
| transparent_hugepage=madvise | THP only on madvise |
| elevator=none | No I/O scheduler (NVMe native) |
| mitigations=auto | Standard CPU mitigations |
| init_on_free=1 | Zero freed memory |
| page_alloc.shuffle=1 | Randomize page allocation |
| randomize_kstack_offset=on | Randomize kernel stack offset |
| vsyscall=none | Disable vsyscall page |
| nvme_core.default_ps_max_latency_us=0 | Disable NVMe power saving |
| pcie_aspm=off | Disable PCIe ASPM power management |
| workqueue.power_efficient=0 | Disable workqueue power-efficient mode |
| intel_iommu=on | Enable Intel VT-d IOMMU |
| iommu=force | Force IOMMU for all devices |
| iommu.passthrough=0 | No IOMMU bypass |
| iommu.strict=1 | Strict DMA isolation |

### 6.3 Gap Analysis

| Parameter | In Schematic | In /proc/cmdline | Status |
|-----------|:------------:|:----------------:|--------|
| cpufreq.default_governor=performance | Yes | Yes | OK |
| intel_idle.max_cstate=0 | Yes | Yes | OK |
| processor.max_cstate=0 | Yes | Yes | OK |
| transparent_hugepage=madvise | Yes | Yes | OK |
| elevator=none | Yes | Yes | OK |
| mitigations=auto | Yes | Yes | OK |
| init_on_free=1 | Yes | Yes | OK |
| page_alloc.shuffle=1 | Yes | Yes | OK |
| randomize_kstack_offset=on | Yes | Yes | OK |
| vsyscall=none | Yes | Yes | OK |
| nvme_core.default_ps_max_latency_us=0 | Yes | Yes | OK |
| pcie_aspm=off | Yes | Yes | OK |
| workqueue.power_efficient=0 | Yes | Yes | OK |
| intel_iommu=on | Yes | Yes | OK |
| iommu=force | Yes | Yes | OK |
| iommu.passthrough=0 | Yes | Yes | OK |
| iommu.strict=1 | Yes | Yes | OK |
| init_on_alloc=1 | No (Talos default) | Yes | OK |
| slab_nomerge | No (Talos default) | Yes | OK |
| pti=on | No (Talos default) | Yes | OK |
| selinux=1 | No (Talos default) | Yes | OK |
| module.sig_enforce=1 | No (Talos default) | Yes | OK |

**All 17 schematic `extraKernelArgs` are present in `/proc/cmdline`.** The node has been successfully upgraded to the factory image with the current schematic. Live state:
- **CPU governor:** performance (matches schematic)
- **THP:** `always [madvise] never` -- madvise is active (matches schematic)
- **C-states:** Disabled (intel_idle.max_cstate=0, processor.max_cstate=0)
- **IOMMU:** Active (intel_iommu=on, strict mode, confirmed by dmesg)
- **Turbo boost:** Enabled (no_turbo = 0)
- **CPU frequency range:** 800 MHz - 3000 MHz (Turbo Boost up to 3.0 GHz)

### 6.4 Sysctl Verification

| Sysctl | Configured | Live | Match |
|--------|-----------|------|:-----:|
| vm.dirty_ratio | 10 | 10 | Yes |
| vm.dirty_background_ratio | 5 | 5 | Yes |
| vm.overcommit_memory | 1 | 1 | Yes |
| vm.max_map_count | 524288 | 524288 | Yes |
| vm.min_free_kbytes | 65536 | 65536 | Yes |
| net.core.rmem_max | 16777216 | 16777216 | Yes |
| net.core.wmem_max | 16777216 | 16777216 | Yes |
| net.core.somaxconn | 32768 | 32768 | Yes |
| net.core.netdev_max_backlog | 16384 | 16384 | Yes |
| net.ipv4.tcp_slow_start_after_idle | 0 | 0 | Yes |
| net.ipv4.tcp_rmem | 4096 1048576 16777216 | 4096 1048576 16777216 | Yes |
| net.ipv4.tcp_wmem | 4096 1048576 16777216 | 4096 1048576 16777216 | Yes |
| net.ipv4.tcp_congestion_control | -- | cubic | N/A (default) |
| net.core.bpf_jit_harden | -- | 2 | N/A (Talos KSPP) |
| kernel.kexec_load_disabled | 1 | 1 | Yes |
| net.ipv4.conf.all.rp_filter | 0 | 0 | Yes |
| net.netfilter.nf_conntrack_max | 131072 | 131072 | Yes |
| kernel.pid_max | 4194304 | 4194304 | Yes |
| fs.inotify.max_user_watches | 524288 | 524288 | Yes |

**All configured sysctls match their live values.** The config from `patches/common.yaml` has been successfully applied.

## 7. Storage Profile

| Device | Model | Type | Size | Scheduler | Queue Depth | Rotational | Role |
|--------|-------|------|------|-----------|-------------|:----------:|------|
| sda | INTENSO SSD | SATA SSD | ~128 GB | mq-deadline | 64 | No | Boot/OS (Talos install disk) |
| nvme0n1 | Samsung MZVLW256HEHP-000H1 | NVMe | ~256 GB | none | 1023 | No | LINSTOR/DRBD storage pool |

Active DRBD resources on this node: drbd1002, drbd1005, drbd1016, drbd1018 (4 volumes).
Additional dm (device-mapper) devices: dm-0, dm-1.

Install disk path: `/dev/disk/by-path/pci-0000:00:17.0-ata-1`
NVMe WWID: `eui.002538b771b9154f` | Serial: `S340NX0J788435`
SATA WWID: `t10.ATA INTENSO SSD 1642312010002091`

## 8. Network Profile

| Interface | Type | Speed | MTU | Status | Role |
|-----------|------|-------|-----|--------|------|
| enp0s31f6 | Intel I219-LM (8086:15b8, e1000e) | 1 Gbps | 1500 | Up | Primary NIC (node + DRBD traffic) |
| cilium_vxlan | VXLAN tunnel | -- | 1500 | Up | Cilium overlay networking |
| cilium_host/cilium_net | Virtual | -- | 1500 | Up | Cilium host networking |
| lo | Loopback | -- | 65536 | Up | Loopback |

Traffic statistics (since last boot):
- **enp0s31f6 RX:** ~2.13 GB (2,517,468 packets, 11,963 drops, 0 errors)
- **enp0s31f6 TX:** ~970 MB (1,946,274 packets, 3 drops, 0 errors)
- **cilium_vxlan RX:** ~1.55 GB (457,754 packets) | **TX:** ~228 MB (411,837 packets)
- **lo RX/TX:** ~746 MB (1,448,643 packets each direction)

The 11,963 RX drops on the physical NIC represent ~0.48% of total packets. This is slightly elevated but within acceptable bounds for a 1 Gbps NIC under DRBD replication and control-plane traffic.

Network config: Static IP 192.168.2.62/24, gateway 192.168.2.1, VIP 192.168.2.60, DNS 192.168.2.1.

## 9. GPU Profile

| Property | Value |
|----------|-------|
| GPU | Intel HD Graphics 630 (integrated) |
| PCI BDF | 00:02.0 |
| Vendor:Device | 8086:5912 |
| Class | 0300 (VGA compatible controller) |
| i915 Extension | Loaded (v20260110-v1.12.4) |
| DRM | Initialized i915 1.6.0 for 0000:00:02.0 |
| DMC Firmware | i915/kbl_dmc_ver1_04.bin (v1.4) |
| VT-d | Active for gfx access |
| Display | No display connected (eDP disabled, no CRTC found) |

The i915 extension is installed for Intel GPU support. No discrete GPU present. No GPU workloads on this control-plane node.

## 10. Installed Extensions

| Extension | Version | Purpose |
|-----------|---------|---------|
| drbd | 9.2.16-v1.12.4 | DRBD kernel module for LINSTOR/Piraeus storage replication |
| gvisor | 20260202.0 | gVisor userspace container runtime (runsc handler) |
| i915 | 20260110-v1.12.4 | Intel integrated GPU driver |
| intel-ucode | 20260210 | Intel CPU microcode updates |
| nvme-cli | v2.14 | NVMe management utilities |

**Schematic ID:** `24f8c9280e59a44d8d9bc457cb80d5b4182313730710e6e41b413c9ededcb18a`

Runtime handlers available: runc (default), runsc (gVisor), runsc-kvm (gVisor KVM).

## 11. Observations

- **Boot parameters fully applied:** All 17 schematic `extraKernelArgs` are present in `/proc/cmdline`. This node has been successfully upgraded to the factory image with the current schematic, unlike node-01 which still has all schematic parameters missing.
- **CPU governor correct:** Running `performance` as intended by the schematic. C-states are disabled (max_cstate=0) for consistent low-latency operation. CPU frequency range is 800 MHz - 3.0 GHz with Turbo Boost active.
- **Sysctls fully applied:** All configured sysctls from `patches/common.yaml` match the live values.
- **IOMMU fully active:** Intel VT-d IOMMU is functional with strict DMA isolation, confirmed both by `/proc/cmdline` parameters and dmesg output. Two DMAR hardware units detected (dmar0 at fed90000, dmar1 at fed91000). All PCI devices assigned to IOMMU groups 0-8. IRQ remapping enabled in x2apic mode.
- **Samsung NVMe 256 GB (PM961/SM961):** This node has a Samsung MZVLW256HEHP-000H1 (~256 GB, device ID 144d:a804), which is a PM961/SM961 OEM drive. This is smaller than node-01's Samsung 970 PRO (~512 GB, device ID 144d:a808). LINSTOR storage pool capacity is correspondingly smaller.
- **SATA boot disk is 128 GB:** The INTENSO SSD on this node is ~128 GB (250,069,680 sectors), while node-01's INTENSO SSD is ~120 GB. Both use the mq-deadline scheduler (acceptable for SATA).
- **Fewer DRBD volumes:** Only 4 DRBD volumes active (drbd1002, drbd1005, drbd1016, drbd1018), consistent with the smaller NVMe capacity compared to node-01.
- **RX drops on physical NIC:** 11,963 drops (~0.48% of RX packets) -- slightly elevated compared to typical levels. This may be caused by burst traffic during DRBD resync or periods of heavy control-plane API traffic. Worth monitoring but not actionable at this level.
- **gVisor runtime available:** The gvisor extension provides runsc and runsc-kvm runtime handlers, enabling sandboxed container execution for security-sensitive workloads.
- **No intel-ice-firmware extension:** Correctly absent -- this node uses an Intel I219-LM (e1000e driver), not an Intel E800 series (ICE) NIC. The extension was present on node-01 (harmless but unnecessary).
- **Memory utilization:** 32 GB total, ~25.0 GB free, ~27.6 GB available (~21% used). Slightly higher than node-01, consistent with control-plane workload variation.
- **Kernel modules loaded:** drbd, drbd_transport_tcp, i915, e1000e, nvme, iTCO_wdt (watchdog), ahci -- all expected for this hardware profile.
- **DRBD healthy:** DRBD connections to peers (including node-gpu-01) are established and operational. Handshake to node-gpu-01 completed successfully with protocol version 123.
