# Hardware Analysis: node-gpu-01

> **Date:** 2026-03-24
> **Talos:** v1.12.6 | **Kubernetes:** v1.35.0 | **Kernel:** 6.18.18-talos
> **Node IP:** 192.168.2.67 | **Role:** worker (GPU)

---

## 1. System Overview

| Property | Value |
|----------|-------|
| Board | BTC B250C (mining motherboard) |
| Vendor | OEM |
| CPU | Intel Core i7-7700K @ 4.20GHz (Kaby Lake, stepping 9) |
| Cores/Threads | 4 / 8 |
| RAM | 31.1 GiB (32,626,808 KiB) |
| Boot Disk | sda — Intenso 240GB SSD (SATA, `/dev/disk/by-path/pci-0000:00:17.0-ata-3`) |
| Data Disk | sdb — SanDisk Ultra 3D 500GB SSD (SATA, XFS UserVolume `local-storage`) |
| Active NIC | enp0s20f0u2 — Realtek RTL8153 USB 3.0 GbE (r8152 driver) |
| Inactive NIC | enp4s0 — Realtek RTL8136 PCIe GbE (r8169 driver, link down) |
| GPUs | 3x NVIDIA (1x RTX 3070 Ti + 2x RTX 3060 Ti) |
| iGPU | Intel HD Graphics 630 (i915, Kaby Lake) |

## 2. PCI Device Inventory

| BDF | Vendor:Device | Class | Description |
|-----|---------------|-------|-------------|
| 0000:00:00.0 | 8086:— | Host Bridge | Intel 200 Series Chipset |
| 0000:00:01.0 | 8086:— | PCI Bridge | PCIe Root Port (→ slot 1) |
| 0000:00:02.0 | 8086:5912 | 0x030000 (VGA) | Intel HD Graphics 630 (i915) |
| 0000:00:04.0 | 8086:— | Signal Processing | Thermal controller |
| 0000:00:07.0 | 8086:— | PCI Bridge | PCIe Root Port (→ slot 2) |
| 0000:00:08.0 | 8086:— | System Peripheral | Gaussian Mixture Model |
| 0000:00:14.0 | 8086:— | USB Controller | USB 3.0 xHCI |
| 0000:00:14.2 | 8086:— | Signal Processing | Thermal subsystem |
| 0000:00:16.0 | 8086:— | Communication | HECI/ME |
| 0000:00:17.0 | 8086:a282 | 0x010601 (SATA) | Intel 200 Series AHCI SATA controller |
| 0000:00:1b.0 | 8086:— | PCI Bridge | PCIe Root Port (→ slot 3) |
| 0000:00:1b.7 | 8086:— | PCI Bridge | PCIe Root Port |
| 0000:00:1c.0 | 8086:— | PCI Bridge | PCIe Root Port (→ Realtek NIC) |
| 0000:00:1f.0 | 8086:— | ISA Bridge | LPC controller |
| 0000:00:1f.2 | 8086:— | Memory Controller | PMC |
| 0000:00:1f.4 | 8086:— | SMBus | SMBus controller |
| **0000:01:00.0** | **10de:2484** | **0x030000 (VGA)** | **NVIDIA GeForce RTX 3070 Ti (GA104)** |
| 0000:01:00.1 | 10de:228b | 0x040300 (Audio) | NVIDIA HD Audio (RTX 3070 Ti) |
| **0000:02:00.0** | **10de:2486** | **0x030000 (VGA)** | **NVIDIA GeForce RTX 3060 Ti (GA104)** |
| 0000:02:00.1 | 10de:228b | 0x040300 (Audio) | NVIDIA HD Audio (RTX 3060 Ti) |
| **0000:03:00.0** | **10de:2486** | **0x030000 (VGA)** | **NVIDIA GeForce RTX 3060 Ti (GA104)** |
| 0000:03:00.1 | 10de:228b | 0x040300 (Audio) | NVIDIA HD Audio (RTX 3060 Ti) |
| 0000:04:00.0 | 10ec:8136 | 0x020000 (Ethernet) | Realtek RTL8101/RTL8136 (inactive) |

## 3. USB Device Inventory

| Vendor:Device | Class | Description |
|---------------|-------|-------------|
| 0bda:8153 | ff (vendor-specific) | Realtek RTL8153 USB 3.0 GbE adapter (active NIC) |

## 4. NFD Feature Highlights

### CPU
- **Model:** Intel family 6 model 158 (Kaby Lake)
- **Hyper-Threading:** enabled (4C/8T)
- **P-State:** active, governor=performance, turbo=**false** (disabled)
- **SGX:** enabled (EPC: 93.5 MiB)
- **Security extensions:** SEV, SEV-ES, SEV-SNP reported enabled (likely NFD false-positive on Intel — these are AMD features)
- **Instruction sets:** AVX, AVX2, AES-NI, FMA3, ADX, BMI2, MPX

### Storage
- **Non-rotational disk:** detected (SSD)
- No NVMe present

### PCI
- **NVIDIA GPU (10de):** present (0x0300 class)
- **Intel iGPU (8086):** present (0x0300 class)

### Kernel
- **Version:** 6.18.18-talos
- **NO_HZ / NO_HZ_IDLE:** enabled (tickless idle)
- **OS:** Talos v1.12.6

## 5. CPU Vulnerability Status

| Vulnerability | Status |
|---------------|--------|
| gather_data_sampling (GDS) | Mitigation: Microcode |
| ghostwrite | Not affected |
| indirect_target_selection | Not affected |
| itlb_multihit | KVM: Mitigation: Split huge pages |
| l1tf | Mitigation: PTE Inversion; VMX: conditional cache flushes, **SMT vulnerable** |
| mds | Mitigation: Clear CPU buffers; **SMT vulnerable** |
| meltdown | Mitigation: PTI |
| mmio_stale_data | Mitigation: Clear CPU buffers; **SMT vulnerable** |
| old_microcode | Not affected |
| reg_file_data_sampling | Not affected |
| retbleed | Mitigation: IBRS |
| spec_rstack_overflow | Not affected |
| spec_store_bypass | Mitigation: Speculative Store Bypass disabled via prctl |
| spectre_v1 | Mitigation: usercopy/swapgs barriers and __user pointer sanitization |
| spectre_v2 | Mitigation: IBRS; IBPB: conditional; STIBP: conditional; RSB filling |
| srbds | Mitigation: Microcode |
| tsa | Not affected |
| tsx_async_abort | Mitigation: TSX disabled |
| vmscape | Mitigation: IBPB before exit to userspace |

**Note:** Three vulnerabilities (l1tf, mds, mmio_stale_data) report "SMT vulnerable" — HT is enabled on this node. Disabling HT would mitigate but reduce thread count from 8 to 4.

## 6. Current Kernel Parameters

### 6.1 Boot Parameters (/proc/cmdline)

| Parameter | Value |
|-----------|-------|
| talos.platform | metal |
| console | tty0 |
| init_on_alloc | 1 |
| slab_nomerge | (flag) |
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
| usbcore.autosuspend | -1 |
| intel_iommu | on |
| iommu | force |
| iommu.passthrough | 0 |
| iommu.strict | 0 |

### 6.2 Configured Boot Parameters (from GPU schematic)

Source: `talos/talos-factory-schematic-gpu.yaml`

| Parameter | Value | Purpose |
|-----------|-------|---------|
| cpufreq.default_governor | performance | Max CPU frequency |
| intel_idle.max_cstate | 0 | Disable C-states (latency) |
| processor.max_cstate | 0 | Disable C-states (ACPI) |
| transparent_hugepage | madvise | THP opt-in only |
| elevator | none | No I/O scheduler (SSD) |
| mitigations | auto | CPU mitigations on |
| init_on_free | 1 | Zero freed pages (security) |
| page_alloc.shuffle | 1 | ASLR for page allocator |
| randomize_kstack_offset | on | Stack ASLR |
| vsyscall | none | Disable vsyscall page |
| nvme_core.default_ps_max_latency_us | 0 | NVMe no power saving |
| pcie_aspm | off | PCIe no power saving |
| workqueue.power_efficient | 0 | No power-efficient WQ |
| usbcore.autosuspend | -1 | USB no autosuspend |
| **pci=noaer** | **(flag)** | **Suppress PCIe AER (riser stability)** |
| **rcutree.rcu_idle_gp_delay** | **1** | **RCU grace period for riser stability** |
| intel_iommu | on | Enable VT-d IOMMU |
| iommu | force | Force IOMMU even if unnecessary |
| iommu.passthrough | 0 | No passthrough mode |
| iommu.strict | 0 | Lazy TLB invalidation |

### 6.3 Gap Analysis

| Parameter | In Schematic | In /proc/cmdline | Status |
|-----------|:---:|:---:|--------|
| cpufreq.default_governor=performance | Yes | Yes | Present-Match |
| intel_idle.max_cstate=0 | Yes | Yes | Present-Match |
| processor.max_cstate=0 | Yes | Yes | Present-Match |
| transparent_hugepage=madvise | Yes | Yes | Present-Match |
| elevator=none | Yes | Yes | Present-Match |
| mitigations=auto | Yes | Yes | Present-Match |
| init_on_free=1 | Yes | Yes | Present-Match |
| page_alloc.shuffle=1 | Yes | Yes | Present-Match |
| randomize_kstack_offset=on | Yes | Yes | Present-Match |
| vsyscall=none | Yes | Yes | Present-Match |
| nvme_core.default_ps_max_latency_us=0 | Yes | Yes | Present-Match |
| pcie_aspm=off | Yes | Yes | Present-Match |
| workqueue.power_efficient=0 | Yes | Yes | Present-Match |
| usbcore.autosuspend=-1 | Yes | Yes | Present-Match |
| **pci=noaer** | **Yes** | **No** | **Missing** |
| **rcutree.rcu_idle_gp_delay=1** | **Yes** | **No** | **Missing** |
| intel_iommu=on | Yes | Yes | Present-Match |
| iommu=force | Yes | Yes | Present-Match |
| iommu.passthrough=0 | Yes | Yes | Present-Match |
| iommu.strict=0 | Yes | Yes | Present-Match |

**FINDING:** Two PCIe riser stability parameters (`pci=noaer`, `rcutree.rcu_idle_gp_delay=1`) are defined in the schematic but **missing from the live boot cmdline**. This suggests the running image was built from a schematic that did not yet include these parameters. A rebuild + upgrade would apply them.

### 6.4 Sysctl Verification

| Sysctl | Configured Value | Live Value | Match |
|--------|:---:|:---:|:---:|
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
| net.ipv4.tcp_congestion_control | — | cubic | N/A (default) |
| net.core.bpf_jit_harden | — | 2 | N/A (kernel default, hardened) |
| kernel.kexec_load_disabled | 1 | 1 | Yes |
| net.ipv4.conf.all.rp_filter | 0 | 0 | Yes |
| net.netfilter.nf_conntrack_max | 131072 | 131072 | Yes |
| kernel.pid_max | 4194304 | 4194304 | Yes |
| fs.inotify.max_user_watches | 524288 | 524288 | Yes |

All explicitly configured sysctls match their live values.

## 7. Storage Profile

| Device | Model | Type | Size | Scheduler | Rotational | Role |
|--------|-------|------|------|-----------|:---:|------|
| sda | Intenso | SATA SSD | ~224 GB | mq-deadline (active) | 0 (SSD) | Boot/OS disk |
| sdb | SanDisk Ultra 3D 500G | SATA SSD | ~466 GB | mq-deadline (active) | 0 (SSD) | Data disk (XFS UserVolume `local-storage`) |

**Note:** The schematic configures `elevator=none` but both disks show `[mq-deadline]` as the active scheduler. The `elevator=none` kernel parameter sets the default for single-queue devices; SATA SSDs use multi-queue `mq-deadline` by default which is appropriate.

## 8. Network Profile

| Interface | Driver | Type | Speed | Status | Notes |
|-----------|--------|------|-------|--------|-------|
| enp0s20f0u2 | r8152 v1.12.13 | USB 3.0 GbE | 1 Gbps | **Active** | Realtek RTL8153; 34,819 RX drops / 439,221 packets (**7.9% drop rate**) |
| enp4s0 | r8169 | PCIe GbE | 1 Gbps | Link Down | Realtek RTL8136 onboard; unused |
| cilium_vxlan | — | VXLAN | — | Active | Cilium overlay tunnel |
| cilium_host/net | — | Virtual | — | Active | Cilium host-side interfaces |

## 9. GPU Profile

### Hardware

| Slot | BDF | Device ID | Model | Audio |
|------|-----|-----------|-------|-------|
| PCIe x1 riser 1 | 0000:01:00.0 | 10de:2484 | **NVIDIA GeForce RTX 3070 Ti** (GA104) | 0000:01:00.1 |
| PCIe x1 riser 2 | 0000:02:00.0 | 10de:2486 | **NVIDIA GeForce RTX 3060 Ti** (GA104) | 0000:02:00.1 |
| PCIe x1 riser 3 | 0000:03:00.0 | 10de:2486 | **NVIDIA GeForce RTX 3060 Ti** (GA104) | 0000:03:00.1 |

### Driver & Runtime

| Property | Value |
|----------|-------|
| Driver | NVIDIA UNIX Open Kernel Module 580.126.20 |
| Kernel modules | nvidia, nvidia_uvm, nvidia_modeset, nvidia_drm |
| Module params | NVreg_UsePageAttributeTable=1, NVreg_DynamicPowerManagement=0 |
| Persistenced | Running (PID 3049) |
| Container toolkit | nvidia-container-toolkit-lts 580.126.20-v1.18.2 |
| Kubernetes resources | `nvidia.com/gpu: 3` (allocatable) |
| Node taint | `nvidia.com/gpu=present:NoSchedule` |

### IOMMU

| Property | Value |
|----------|-------|
| VT-d | Enabled (DMAR present, 2 DRHD units) |
| IOMMU mode | Translated (forced via kernel cmdline) |
| TLB invalidation | Lazy mode (iommu.strict=0) |
| IRQ remapping | Enabled (x2apic mode) |
| i915 VT-d | Active for gfx access |

### PCIe Topology Note

All 3 NVIDIA GPUs connect through PCIe x1 risers on the BTC B250C mining board. This limits each GPU to PCIe 3.0 x1 bandwidth (~985 MB/s) — suitable for inference workloads (where model weights fit in VRAM) but a bottleneck for large data transfers.

## 10. Installed Extensions

| Extension | Version | Purpose |
|-----------|---------|---------|
| drbd | 9.2.16-v1.12.6 | DRBD kernel module for LINSTOR CSI replication |
| gvisor | 20260202.0 | gVisor sandbox runtime |
| i915 | 20260309-v1.12.6 | Intel iGPU driver (Kaby Lake HD 630) |
| intel-ucode | 20260227 | Intel CPU microcode updates |
| nvidia-container-toolkit-lts | 580.126.20-v1.18.2 | NVIDIA container runtime integration |
| nvidia-open-gpu-kernel-modules-lts | 580.126.20-v1.12.6 | NVIDIA open kernel driver |
| realtek-firmware | 20260309 | Realtek USB NIC firmware (RTL8153) |

**Schematic ID:** `8d15133f30cf22e82a0c5405f76c4b511ca026a40bfbbb3be06f209c3ac8ec84`

## 11. Observations

- **CRITICAL — Missing boot parameters:** `pci=noaer` and `rcutree.rcu_idle_gp_delay=1` are in the factory schematic but missing from the live cmdline. These are PCIe riser stability parameters for the BTC B250C mining board. The node is running on an older image that predates these additions. A `talosctl upgrade` with the current schematic image would apply them.

- **HIGH — USB NIC RX drop rate of 7.9%:** The active NIC `enp0s20f0u2` (Realtek RTL8153) shows 34,819 RX drops out of 439,221 packets. This exceeds the documented 5% threshold. Possible causes: USB bandwidth contention with other USB devices, interrupt coalescing, or driver buffer sizing. The `realtek-firmware` extension is installed which should help, but the drop rate remains elevated.

- **INFO — Turbo Boost disabled:** Intel P-State reports `no_turbo=1`. The i7-7700K supports turbo up to 4.5 GHz but runs locked at 4.2 GHz base. This may be intentional for thermal stability given the mining board form factor, or a BIOS setting. NFD confirms `turbo=false`.

- **INFO — SMT vulnerability exposure:** Three CPU vulnerabilities (L1TF, MDS, MMIO Stale Data) report "SMT vulnerable" because Hyper-Threading is enabled. For a GPU inference worker with limited tenant exposure, this is acceptable risk.

- **INFO — NFD false-positive AMD security features:** NFD reports `sev.enabled`, `sev.es.enabled`, `sev.snp.enabled` as true — these are AMD-only features (SEV/SEV-ES/SEV-SNP) and cannot be present on an Intel Kaby Lake CPU. This is a known NFD bug.

- **INFO — I/O scheduler mismatch (benign):** Boot parameter `elevator=none` targets single-queue block devices, but both SATA SSDs use multi-queue `mq-deadline` which is appropriate. No action needed.

- **INFO — Onboard Realtek PCIe NIC unused:** `enp4s0` (r8169) is link-down. The node uses the USB RTL8153 adapter instead. If the onboard NIC is functional, migrating to it would eliminate USB bandwidth contention and potentially reduce the RX drop rate.

- **INFO — All sysctls verified:** Every explicitly configured sysctl in `common.yaml` matches its live value. No configuration drift detected.

- **INFO — IOMMU fully operational:** VT-d is enabled with lazy TLB invalidation. All three NVIDIA GPUs are in translated IOMMU domains, providing DMA isolation.
