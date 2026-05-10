# Hardware Analysis: node-gpu-01

> **Date:** 2026-02-28
> **Talos:** v1.12.4 | **Kubernetes:** v1.35.0
> **Node IP:** 192.168.2.67 | **Role:** worker (GPU)

---

## 1. System Overview

| Property | Value |
|----------|-------|
| Vendor | OEM |
| Product | BTC B250C (crypto mining motherboard) |
| Board | BTC B250C |
| BIOS | American Megatrends Inc. v5.12 |
| CPU | Intel Core i7-7700K @ 4.20GHz (Kaby Lake, family 6 model 158 stepping 9) |
| Cores/Threads | 4C/8T (Hyper-Threading enabled) |
| Microcode | 0xf8 |
| L3 Cache | 8 MB |
| RAM | 32 GB DDR4 (32,626,880 KB total, ~31.1 GB) |
| NUMA | 1 node (node0) |
| Boot Mode | UEFI (64-bit), Secure Boot disabled |
| Boot Disk | INTENSO SSD ~240 GB (sda, SATA) |
| Data Disk | SanDisk Ultra 3D 500G ~500 GB (sdb, SATA) |
| Active NIC | enp0s20f0u2 (Realtek RTL8153 USB 3.0 Gigabit Ethernet, MAC 00:e0:3c:68:46:45) |
| GPU (integrated) | Intel HD Graphics 630 (8086:5912) |
| GPU 1 (discrete) | NVIDIA GeForce RTX 3070 (10de:2484, GA104) |
| GPU 2 (discrete) | NVIDIA GeForce RTX 3060 Ti (10de:2486, GA104) |
| GPU 3 (discrete) | NVIDIA GeForce RTX 3060 Ti (10de:2486, GA104) |

## 2. PCI Device Inventory

| BDF | Vendor:Device | Class | Description |
|-----|---------------|-------|-------------|
| 00:00.0 | 8086:591f | 0600 (Host Bridge) | Intel Kaby Lake Host Bridge/DRAM Registers |
| 00:01.0 | 8086:1901 | 0604 (PCI Bridge) | Intel Kaby Lake PCIe Root Port (PEG, x16 slot for GPU 1) |
| 00:02.0 | 8086:5912 | 0300 (VGA) | Intel HD Graphics 630 (integrated) |
| 00:04.0 | 8086:1903 | 1180 (Signal Processing) | Intel Kaby Lake DPTF Thermal Controller |
| 00:07.0 | 8086:1907 | 1101 (Performance Counters) | Intel Kaby Lake Performance Counters |
| 00:08.0 | 8086:1911 | 0880 (System Peripheral) | Intel Kaby Lake Gaussian Mixture Model |
| 00:14.0 | 8086:a2af | 0c03 (USB) | Intel 200 Series USB 3.0 xHCI Controller |
| 00:14.2 | 8086:a2b1 | 1180 (Signal Processing) | Intel 200 Series Thermal Subsystem |
| 00:16.0 | 8086:a2ba | 0780 (Communication) | Intel 200 Series ME Interface |
| 00:17.0 | 8086:a282 | 0106 (SATA/AHCI) | Intel 200 Series SATA Controller (AHCI) |
| 00:1b.0 | 8086:a2eb | 0604 (PCI Bridge) | Intel 200 Series PCIe Root Port (GPU 2) |
| 00:1b.7 | 8086:a2ee | 0604 (PCI Bridge) | Intel 200 Series PCIe Root Port (GPU 3) |
| 00:1c.0 | 8086:a294 | 0604 (PCI Bridge) | Intel 200 Series PCIe Root Port (onboard NIC) |
| 00:1f.0 | 8086:a2c8 | 0601 (ISA Bridge) | Intel 200 Series LPC Controller |
| 00:1f.2 | 8086:a2a1 | 0580 (Memory Controller) | Intel 200 Series PMC |
| 00:1f.4 | 8086:a2a3 | 0c05 (SMBus) | Intel 200 Series SMBus Controller |
| **01:00.0** | **10de:2484** | **0300 (VGA)** | **NVIDIA GeForce RTX 3070 (GA104)** |
| 01:00.1 | 10de:228b | 0403 (Audio) | NVIDIA GA104 HD Audio Controller |
| **02:00.0** | **10de:2486** | **0300 (VGA)** | **NVIDIA GeForce RTX 3060 Ti (GA104)** |
| 02:00.1 | 10de:228b | 0403 (Audio) | NVIDIA GA104 HD Audio Controller |
| **03:00.0** | **10de:2486** | **0300 (VGA)** | **NVIDIA GeForce RTX 3060 Ti (GA104)** |
| 03:00.1 | 10de:228b | 0403 (Audio) | NVIDIA GA104 HD Audio Controller |
| 04:00.0 | 10ec:8136 | 0200 (Ethernet) | Realtek RTL8105e Fast Ethernet (100 Mbps, unused) |

All PCI devices have IOMMU enabled (intel-iommu v1:0, DMA-FQ mode).

### IOMMU Group Assignments

| IOMMU Group | Devices | Notes |
|:-----------:|---------|-------|
| 0 | 00:02.0 (iGPU) | Intel HD Graphics 630 (isolated) |
| 1 | 00:00.0 | Host Bridge |
| 2 | 00:01.0, **01:00.0**, 01:00.1 | PEG root port + **RTX 3070** + audio (shared group) |
| 3 | 00:04.0 | DPTF Thermal |
| 4 | 00:07.0 | Performance Counters |
| 5 | 00:08.0 | Gaussian Mixture Model |
| 6 | 00:14.0, 00:14.2 | USB + Thermal |
| 7 | 00:16.0 | ME Interface |
| 8 | 00:17.0 | SATA Controller |
| 9 | 00:1b.0 | PCIe Root Port (GPU 2 parent) |
| 10 | 00:1b.7 | PCIe Root Port (GPU 3 parent) |
| 11 | 00:1c.0 | PCIe Root Port (onboard NIC parent) |
| 12 | 00:1f.0, 00:1f.2, 00:1f.4 | LPC + PMC + SMBus |
| 13 | **02:00.0**, 02:00.1 | **RTX 3060 Ti #1** + audio |
| 14 | **03:00.0**, 03:00.1 | **RTX 3060 Ti #2** + audio |
| 15 | 04:00.0 | Realtek RTL8105e onboard NIC |

Each GPU shares its IOMMU group only with its associated HDMI audio controller -- suitable for VFIO passthrough if needed.

### PCIe Link Status

| GPU | BDF | Current Speed | Current Width | Max Speed | Max Width | Status |
|-----|-----|:-------------:|:-------------:|:---------:|:---------:|--------|
| RTX 3070 | 01:00.0 | 2.5 GT/s (Gen1) | x1 | 16.0 GT/s (Gen4) | x16 | **DEGRADED** |
| RTX 3060 Ti #1 | 02:00.0 | 2.5 GT/s (Gen1) | x1 | 16.0 GT/s (Gen4) | x16 | **DEGRADED** |
| RTX 3060 Ti #2 | 03:00.0 | 2.5 GT/s (Gen1) | x1 | 16.0 GT/s (Gen4) | x16 | **DEGRADED** |

**All three GPUs are running at PCIe Gen1 x1 (250 MB/s) instead of their maximum Gen4 x16 (~32 GB/s).** This is a 128x bandwidth reduction. Typical cause on BTC B250C mining boards: the board uses PCIe x1 risers on the secondary slots (00:1b.0, 00:1b.7) and the primary PEG x16 slot may be running downclocked. This is by design on mining motherboards -- GPU compute workloads (crypto mining, inference) are less sensitive to PCIe bandwidth than training or large data transfer workloads. For CUDA compute and inference, this is usually acceptable since the working set fits in GPU VRAM.

## 3. USB Device Inventory

| Vendor:Device | Class | Serial | Description |
|---------------|-------|--------|-------------|
| 1d6b:0002 | 09 (Hub) | 0000:00:14.0 | Linux Foundation USB 2.0 Root Hub |
| 1d6b:0003 | 09 (Hub) | 0000:00:14.0 | Linux Foundation USB 3.0 Root Hub |
| 0bda:8153 | ff (Vendor Specific) | D01300E03C684645 | Realtek RTL8153 USB 3.0 Gigabit Ethernet (primary NIC) |
| 1a86:e2e3 | 03 (HID) | -- | QinHeng Electronics CH9329 UART-to-HID adapter |

## 4. NFD Feature Highlights

### CPU
- **Architecture:** amd64, Intel Kaby Lake (family 6, model 158)
- **Instruction Sets:** SSE, SSE2, SSE4.1, SSE4.2, AVX, AVX2, FMA3, AES-NI, ADX, SGX
- **Virtualization:** VMX (VT-x) supported
- **Multithreading:** HT enabled (4 physical cores, 8 threads)
- **P-State:** Active, governor = powersave, **turbo = false** (disabled)
- **C-States:** Enabled
- **Security:** IBPB, STIBP, SSBD, FLUSH_L1D, MD_CLEAR, SGX enabled (EPC: 93 MB)
- **Frequency Range:** 800 MHz -- 4200 MHz (currently running at ~4000 MHz)

### Storage
- Non-rotational disk present (SSD)
- 3 DRBD volumes: drbd1003, drbd1004, drbd1005

### Kernel
- Version: 6.18.9-talos
- Config: NO_HZ=y, NO_HZ_IDLE=y (tickless idle)

### PCI Features
- `pci-0300_8086.present: true` -- Intel integrated GPU detected
- `pci-0300_10de.present: true` -- NVIDIA discrete GPU detected

### USB Features
- `usb-ff_0bda_8153.present: true` -- Realtek RTL8153 USB Ethernet detected

### Runtime Handlers
- `""` (default), `nvidia`, `runc`

## 5. CPU Vulnerability Status

| Vulnerability | Status |
|---------------|--------|
| gather_data_sampling | Mitigation: Microcode |
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
| spectre_v2 | Mitigation: IBRS; IBPB: conditional; STIBP: conditional; RSB filling; PBRSB-eIBRS: Not affected; BHI: Not affected |
| srbds | Mitigation: Microcode |
| tsa | Not affected |
| tsx_async_abort | Mitigation: TSX disabled |
| vmscape | Mitigation: IBPB before exit to userspace |

GDS is mitigated via microcode. Several mitigations show **"SMT vulnerable"** due to Hyper-Threading. TSX is disabled via microcode. Same vulnerability profile as node-06 (i7-7700T, Kaby Lake).

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

### 6.2 Configured Boot Parameters (from GPU factory schematic)

| Parameter | Purpose |
|-----------|---------|
| cpufreq.default_governor=performance | Force performance CPU governor |
| intel_idle.max_cstate=0 | Disable deep C-states |
| processor.max_cstate=0 | Disable processor C-states |
| transparent_hugepage=madvise | THP only on madvise |
| elevator=none | No I/O scheduler (direct dispatch) |
| mitigations=auto | Standard CPU mitigations |
| init_on_free=1 | Zero freed memory |
| page_alloc.shuffle=1 | Randomize page allocation |
| randomize_kstack_offset=on | Randomize kernel stack offset |
| vsyscall=none | Disable vsyscall page |
| debugfs=off | Disable debugfs |
| nvme_core.default_ps_max_latency_us=0 | Disable NVMe power saving |
| pcie_aspm=off | Disable PCIe Active State Power Management |
| workqueue.power_efficient=0 | Disable power-efficient workqueues |
| intel_iommu=on | Enable Intel VT-d IOMMU |
| iommu=force | Force IOMMU for all devices |
| iommu.passthrough=0 | No IOMMU bypass |
| iommu.strict=1 | Strict DMA isolation |

### 6.3 Gap Analysis

| Parameter | In Schematic | In /proc/cmdline | Status |
|-----------|:------------:|:----------------:|--------|
| cpufreq.default_governor=performance | Yes | No | **MISSING** |
| intel_idle.max_cstate=0 | Yes | No | **MISSING** |
| processor.max_cstate=0 | Yes | No | **MISSING** |
| transparent_hugepage=madvise | Yes | No | **MISSING** |
| elevator=none | Yes | No | **MISSING** |
| mitigations=auto | Yes | No | **MISSING** |
| init_on_free=1 | Yes | No | **MISSING** |
| page_alloc.shuffle=1 | Yes | No | **MISSING** |
| randomize_kstack_offset=on | Yes | No | **MISSING** |
| vsyscall=none | Yes | No | **MISSING** |
| debugfs=off | Yes | No | **MISSING** |
| nvme_core.default_ps_max_latency_us=0 | Yes | No | **MISSING** |
| pcie_aspm=off | Yes | No | **MISSING** |
| workqueue.power_efficient=0 | Yes | No | **MISSING** |
| intel_iommu=on | Yes | No | **MISSING** |
| iommu=force | Yes | No | **MISSING** |
| iommu.passthrough=0 | Yes | No | **MISSING** |
| iommu.strict=1 | Yes | No | **MISSING** |
| init_on_alloc=1 | No (Talos default) | Yes | OK |
| slab_nomerge | No (Talos default) | Yes | OK |
| pti=on | No (Talos default) | Yes | OK |
| selinux=1 | No (Talos default) | Yes | OK |
| module.sig_enforce=1 | No (Talos default) | Yes | OK |

**Note:** All 18 schematic `extraKernelArgs` are missing from `/proc/cmdline`. The node has not been upgraded to the factory image with the current schematic yet. Boot parameters are baked into the UKI image and require `make -C talos upgrade-node-gpu-01` to take effect. Live state:
- **CPU governor:** powersave (schematic wants `performance`)
- **THP:** `always [madvise] never` -- madvise is active (matches schematic intent, likely Talos default)
- **THP defrag:** `always defer defer+madvise [madvise] never` -- madvise mode
- **IOMMU:** Active (confirmed by NFD `DMA-FQ` on all PCI devices -- enabled via BIOS/UEFI, not via boot param)
- **Turbo Boost:** **Disabled** (no_turbo = 1) -- the i7-7700K supports Turbo up to 4.50GHz but it is explicitly disabled. This may be a BIOS setting or a stability measure for the mining board under multi-GPU load.
- **WARNING: `debugfs=off` is in the schematic.** Per CLAUDE.md: "Do NOT use `debugfs=off` -- Talos needs debugfs to create root filesystem; causes 'failed to create root filesystem' boot loop." This parameter must be removed from `talos-factory-schematic-gpu.yaml` before running `make -C talos upgrade-node-gpu-01`.

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
| net.core.bpf_jit_harden | 1 (GPU override) | 1 | Yes |
| net.ipv4.tcp_slow_start_after_idle | 0 | 0 | Yes |
| net.ipv4.tcp_congestion_control | -- | cubic | N/A (default) |
| net.ipv4.conf.all.rp_filter | 0 | 0 | Yes |
| kernel.kexec_load_disabled | 1 | 1 | Yes |
| kernel.pid_max | 4194304 | 4194304 | Yes |
| fs.inotify.max_user_watches | 524288 | 524288 | Yes |
| net.netfilter.nf_conntrack_max | 131072 | 131072 | Yes |

**All configured sysctls match their live values.** Note: `bpf_jit_harden` is set to `1` on this node (via `patches/worker-gpu.yaml`) vs the Talos KSPP default of `2`. This is intentional -- BPF JIT hardening level 2 can interfere with NVIDIA driver eBPF usage.

## 7. Storage Profile

| Device | Model | Type | Size | Transport | Scheduler | Rotational | WWID | Role |
|--------|-------|------|------|-----------|-----------|:----------:|------|------|
| sda | INTENSO | SATA SSD | 240 GB (468,862,128 sectors) | SATA | mq-deadline | No | t10.ATA INTENSO AA000000000000007558 | Talos install disk (system) |
| sdb | SanDisk Ultra 3D 500G | SATA SSD | 500 GB (976,773,168 sectors) | SATA | mq-deadline | No | naa.5001b444a5673347 | Local storage (UserVolumeConfig) |

Install disk path: `/dev/disk/by-path/pci-0000:00:17.0-ata-3`

Active DRBD resources on this node: drbd1003, drbd1004, drbd1005 (3 volumes).

**UserVolumeConfig:** `sdb` is provisioned via `nodes/node-gpu-01.yaml` as `local-storage` (matching `disk.wwid == 'naa.5001b444a5673347'`, 450 GiB XFS). This provides local persistent storage for GPU workloads that don't need DRBD replication.

**No NVMe device** -- this is the only node in the cluster without NVMe storage. All storage is SATA-attached.

## 8. Network Profile

| Interface | Type | Driver | Speed | Status | Role |
|-----------|------|--------|-------|--------|------|
| enp0s20f0u2 | Realtek RTL8153 USB 3.0 Gigabit | r8152 | 1 Gbps | Up | Primary NIC (node traffic) |
| enp4s0 | Realtek RTL8105e PCI (10ec:8136) | r8169 | 100 Mbps | Down | Unused (onboard Fast Ethernet) |
| cilium_vxlan | VXLAN tunnel | -- | -- | Up | Cilium overlay networking |
| cilium_host/cilium_net | Virtual | -- | -- | Up | Cilium host networking |
| lo | Loopback | -- | -- | Up | Loopback |

Traffic statistics (since last boot, 2026-02-28T13:56):
- **enp0s20f0u2 RX:** 2.75 GB (2,627,897 packets, **19,766 drops = 0.75%**)
- **enp0s20f0u2 TX:** 3.07 GB (2,824,957 packets, 1 drop)
- **cilium_vxlan RX:** 1.73 GB (662K packets) | **TX:** 2.61 GB (532K packets)

The 19,766 RX drops represent 0.75% of total RX packets. While improved from earlier snapshots, this is still significantly higher than other nodes (~0.1%). The USB Ethernet adapter has limited buffer capacity and the RTL8153 firmware is missing.

**Firmware warnings:**
- `r8152`: "Direct firmware load for rtl_nic/rtl8153b-2.fw failed with error -2" -- the USB NIC firmware is not available. The adapter works but lacks hardware offload features (checksum offload, segmentation offload). The `siderolabs/realtek-firmware` extension is listed in the GPU schematic but is **not installed** -- this will be resolved when `make -C talos upgrade-node-gpu-01` is run.
- `r8169`: "Unable to load firmware rtl_nic/rtl8105e-1.fw" -- firmware missing for the onboard PCI NIC (unused, link down).

## 9. GPU Profile

### NVIDIA GPUs

| Property | GPU 1 (01:00.0) | GPU 2 (02:00.0) | GPU 3 (03:00.0) |
|----------|-----------------|-----------------|-----------------|
| Model | GeForce RTX 3070 | GeForce RTX 3060 Ti | GeForce RTX 3060 Ti |
| Vendor:Device | 10de:2484 | 10de:2486 | 10de:2486 |
| Subsystem | 10de:146b | 10de:147a | 10de:147a |
| Architecture | Ampere (GA104) | Ampere (GA104) | Ampere (GA104) |
| PCI Class | 0300 (VGA) | 0300 (VGA) | 0300 (VGA) |
| Audio Controller | 10de:228b (01:00.1) | 10de:228b (02:00.1) | 10de:228b (03:00.1) |
| IOMMU Group | 2 | 13 | 14 |
| IOMMU Mode | DMA-FQ | DMA-FQ | DMA-FQ |
| VGA Arbitration | Decodes: none | Decodes: none | Decodes: none |
| PCIe Current | Gen1 x1 (2.5 GT/s) | Gen1 x1 (2.5 GT/s) | Gen1 x1 (2.5 GT/s) |
| PCIe Maximum | Gen4 x16 (16.0 GT/s) | Gen4 x16 (16.0 GT/s) | Gen4 x16 (16.0 GT/s) |
| NUMA Node | -1 (none) | -1 (none) | -1 (none) |

### NVIDIA Driver

| Property | Value |
|----------|-------|
| Driver Type | NVIDIA UNIX Open Kernel Module |
| Driver Version | 580.126.16 |
| Build Date | Sat Jan 31 03:18:57 UTC 2026 |
| Kernel Modules | nvidia, nvidia_uvm, nvidia_modeset, nvidia_drm |
| nvidia-persistenced | Running (PID 3068) |
| DRM Devices | /dev/dri/card1, /dev/dri/card2, /dev/dri/card3 (minor 1-3) |
| Kubernetes GPUs | nvidia.com/gpu: **3** allocatable / **3** capacity |
| Container Runtime | `nvidia` runtime handler available |

### Intel iGPU

| Property | Value |
|----------|-------|
| GPU | Intel HD Graphics 630 (Kaby Lake, integrated) |
| PCI BDF | 00:02.0 |
| Vendor:Device | 8086:5912 |
| i915 Extension | Loaded (v20260110-v1.12.4) |
| DRM | Initialized i915 1.6.0 for 0000:00:02.0 on minor 0 |
| DMC Firmware | i915/kbl_dmc_ver1_04.bin (v1.4) |
| VT-d | Active for gfx access |
| THP | Using Transparent Hugepages |

The i915 driver takes the primary DRM device (minor 0), while NVIDIA GPUs are on minor 1-3.

## 10. Installed Extensions

| Extension | Version | Purpose |
|-----------|---------|---------|
| drbd | 9.2.16-v1.12.4 | DRBD kernel module for LINSTOR/Piraeus storage replication |
| i915 | 20260110-v1.12.4 | Intel integrated GPU driver |
| intel-ice-firmware | 20260110 | Intel ICE NIC firmware (E800 series) -- **not needed on this node** |
| intel-ucode | 20260210 | Intel CPU microcode updates |
| nvme-cli | v2.14 | NVMe management utilities -- **not needed on this node** |
| nvidia-open-gpu-kernel-modules-lts | 580.126.16-v1.12.4 | NVIDIA open kernel GPU driver |
| nvidia-container-toolkit-lts | 580.126.16-v1.18.2 | NVIDIA Container Toolkit for GPU containers |

**Not installed but in schematic:** gvisor, realtek-firmware -- these will be available after `make -C talos upgrade-node-gpu-01`.

**Schematic ID:** `60b815d95e1e79a818edadfffafa3cf3e2dcab27c7e6bb4cd53ed4aa52f5df84`

**Install image:** `factory.talos.dev/metal-installer/60b815d95e1e79a818edadfffafa3cf3e2dcab27c7e6bb4cd53ed4aa52f5df84:v1.12.4`

## 11. Observations

### Critical Issues

1. **`debugfs=off` in GPU schematic will cause boot loop.** The `talos-factory-schematic-gpu.yaml` includes `debugfs=off` in `extraKernelArgs`. Per project documentation, Talos needs debugfs to create the root filesystem. Running `make -C talos upgrade-node-gpu-01` with this parameter will render the node unbootable. **Remove `debugfs=off` from `talos-factory-schematic-gpu.yaml` before upgrading.**

2. **All boot parameters pending.** All 18 schematic `extraKernelArgs` are missing from `/proc/cmdline`. The node is running on the old factory image. Run `make -C talos upgrade-node-gpu-01` (after fixing the debugfs issue) to apply performance and security boot parameters.

3. **PCIe running at Gen1 x1 on all GPUs.** All three GPUs report current link speed of 2.5 GT/s x1 vs their maximum of 16.0 GT/s x16. This is a 128x bandwidth reduction. On the BTC B250C mining board, this is likely by design (PCIe x1 risers for mining slots). For CUDA compute/inference workloads where data fits in GPU VRAM, this is acceptable. For workloads requiring frequent host-GPU data transfer, this is a severe bottleneck.

### Hardware

4. **Unique hardware platform.** BTC B250C crypto mining motherboard -- completely different from the Lenovo ThinkCentre Tiny nodes. Custom build with desktop i7-7700K CPU, multiple PCIe slots for GPUs, and USB-attached Ethernet.

5. **3 NVIDIA Ampere GPUs.** 1x RTX 3070 (10de:2484) + 2x RTX 3060 Ti (10de:2486), all GA104 architecture. 3 GPUs allocatable in Kubernetes via `nvidia.com/gpu`. NVIDIA open kernel modules v580.126.16 loaded. nvidia-persistenced running.

6. **USB Ethernet as primary NIC.** The primary NIC (enp0s20f0u2) is a Realtek RTL8153 USB 3.0 Gigabit Ethernet adapter, not a PCIe NIC. The onboard PCI NIC (enp4s0, RTL8105e) is only 100 Mbps Fast Ethernet and is unused (link down).

7. **NIC firmware missing.** RTL8153 firmware (`rtl_nic/rtl8153b-2.fw`) failed to load. The `siderolabs/realtek-firmware` extension is in the schematic but not yet installed (pending upgrade). Without firmware, the adapter lacks hardware offloads, contributing to higher packet drop rates (0.75% vs ~0.1% on other nodes).

8. **Turbo Boost disabled.** `no_turbo=1` -- the i7-7700K is locked at 4.20GHz base clock (running at ~4.00GHz) instead of boosting to 4.50GHz. Likely a BIOS setting for thermal/stability under multi-GPU load, or a VRM limitation of the mining board.

9. **No NVMe storage.** The only node in the cluster without NVMe. Uses two SATA SSDs: Intenso 240 GB (boot/OS) and SanDisk Ultra 3D 500 GB (local storage).

### Configuration

10. **CPU governor mismatch.** Running `powersave` instead of the intended `performance`. Will be resolved when boot parameters are applied via upgrade.

11. **bpf_jit_harden = 1.** Intentionally lowered from Talos KSPP default of 2 in `patches/worker-gpu.yaml`. Level 2 can interfere with NVIDIA eBPF operations. Acceptable security trade-off for GPU functionality.

12. **All sysctls fully applied.** Every configured sysctl matches its live value -- no gaps.

13. **IOMMU active via BIOS.** VT-d is enabled in BIOS (DMAR tables present, DMA-FQ mode active). The `intel_iommu=on` boot parameter in the schematic is redundant but harmless. `iommu.strict=1` (once applied) will add strict DMA TLB invalidation but may slightly impact GPU DMA throughput.

14. **IOMMU groups are clean for passthrough.** Each GPU shares its IOMMU group only with its HDMI audio controller. This is ideal for VFIO passthrough if ever needed.

### Extensions

15. **Unnecessary extensions installed.** `intel-ice-firmware` (for Intel E800 NICs) and `nvme-cli` (no NVMe devices) are installed but unused. Harmless but add to image size. These are present because the GPU schematic inherited them; they could be removed.

16. **gvisor not yet installed.** Listed in the GPU schematic but not installed on the running node. Will be available after upgrade.

### Memory

17. **32 GB RAM with low utilization.** 23.8 GB free, 27.4 GB available (~16% used). GPU workloads are primarily VRAM-bound rather than system RAM-bound. Ample headroom.

18. **3 DRBD volumes active.** drbd1003, drbd1004, drbd1005 -- moderate DRBD footprint for a GPU compute node. Network traffic is relatively low compared to standard workers.
