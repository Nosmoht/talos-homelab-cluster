# Hardware Analysis: node-05

> **Date:** 2026-02-28
> **Talos:** v1.12.4 | **Kubernetes:** v1.35.0
> **Node IP:** 192.168.2.65 | **Role:** worker

---

## 1. System Overview

| Property | Value |
|----------|-------|
| Vendor | Lenovo |
| Product | 10MQS6LK09 (ThinkCentre M910q Tiny) |
| Board | 3111 |
| BIOS | M1AKT59A (2023-10-27) |
| CPU | Intel Core i5-7500T @ 2.70GHz (Kaby Lake, family 6 model 158 stepping 9) |
| Cores/Threads | 4C/4T (no Hyper-Threading) |
| Frequency Range | 800 MHz - 3.30 GHz (turbo) |
| Microcode | 0xf8 |
| L3 Cache | 6 MB |
| RAM | 24 GB DDR4 (24,349,160 KB) |
| Boot Disk | SanDisk SD9SB8W1 128 GB (sda, SATA, serial naa.5001b448b9acc025) |
| Data Disk | Samsung SSD 980 PRO 250 GB (nvme0n1, NVMe PCIe, serial S5GZNF0R129195B) |
| Active NIC | enp0s31f6 (Intel I219-LM, 1 Gbps, MAC 6c:4b:90:95:97:2e) |
| NUMA Nodes | 1 (node0) |
| GPU | Intel HD Graphics 630 (integrated, 8086:5912) |
| Container Runtime | containerd 2.1.6 |
| Kernel | 6.18.9-talos |

## 2. PCI Device Inventory

| BDF | Vendor:Device | Class | Description |
|-----|---------------|-------|-------------|
| 00:00.0 | 8086:591f | 0600 (Host Bridge) | Intel Kaby Lake Host Bridge/DRAM Registers |
| 00:02.0 | 8086:5912 | 0300 (VGA) | Intel HD Graphics 630 |
| 00:14.0 | 8086:a2af | 0c03 (USB) | Intel 200 Series USB 3.0 xHCI Controller |
| 00:14.2 | 8086:a2b1 | 1180 (Signal Processing) | Intel 200 Series Thermal Subsystem |
| 00:16.0 | 8086:a2ba | 0780 (Communication) | Intel 200 Series ME Interface |
| 00:17.0 | 8086:a282 | 0106 (SATA/AHCI) | Intel 200 Series SATA Controller (AHCI, 6 Gbps, 6 ports) |
| 00:1b.0 | 8086:a2eb | 0604 (PCI Bridge) | Intel 200 Series PCIe Root Port |
| 00:1f.0 | 8086:a2c8 | 0601 (ISA Bridge) | Intel 200 Series LPC Controller |
| 00:1f.2 | 8086:a2a1 | 0580 (Memory Controller) | Intel 200 Series PMC |
| 00:1f.4 | 8086:a2a3 | 0c05 (SMBus) | Intel 200 Series SMBus Controller |
| 00:1f.6 | 8086:15b8 | 0200 (Ethernet) | Intel I219-LM Ethernet |
| 01:00.0 | 144d:a80a | 0108 (NVMe) | Samsung 980 PRO NVMe SSD |

All 12 PCI devices are assigned to IOMMU groups (0-8). Intel VT-d is enabled with strict DMA isolation (Queued invalidation, IRQ remapping in x2apic mode).

## 3. USB Device Inventory

| Bus-Port | Vendor:Device | Description |
|----------|---------------|-------------|
| usb1 | 1d6b:0002 | Linux Foundation USB 2.0 Root Hub |
| usb2 | 1d6b:0003 | Linux Foundation USB 3.0 Root Hub |
| 1-3 | 8087:0a2a | Intel Bluetooth Controller (Wireless class) |

The Intel Bluetooth controller (8087:0a2a) is built into the M910q motherboard. It is unused in this headless configuration.

## 4. NFD Feature Highlights

### CPU
- **Architecture:** amd64, Intel Kaby Lake (family 6, model 158)
- **Instruction Sets:** SSE, SSE2, SSE4.1, SSE4.2, AVX, AVX2, FMA3, AES-NI, ADX, MPX
- **Virtualization:** VMX (VT-x) supported
- **Multithreading:** No HT (4 physical cores only)
- **P-State:** Active, governor = performance, turbo = enabled
- **C-States:** Disabled (intel_idle.max_cstate=0, processor.max_cstate=0)
- **Security:** IBPB, STIBP, SSBD, FLUSH_L1D, MD_CLEAR, SRBDS_CTRL, SGX enabled (EPC: 98 MB)

### Storage
- Non-rotational disk present (SSD/NVMe)

### Kernel
- Version: 6.18.9-talos
- Config: NO_HZ=y, NO_HZ_IDLE=y (tickless idle)

### PCI Features
- `pci-0300_8086.present: true` -- Intel integrated GPU detected

### Runtime Handlers
- `runc` -- default OCI runtime
- `runsc` -- gVisor userspace kernel
- `runsc-kvm` -- gVisor with KVM acceleration

## 5. CPU Vulnerability Status

| Vulnerability | Status |
|---------------|--------|
| gather_data_sampling | Mitigation: Microcode (locked) |
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
| tsx_async_abort | Mitigation: TSX disabled |
| vmscape | Mitigation: IBPB before exit to userspace |

All known vulnerabilities are mitigated. GDS is mitigated via microcode (locked). The `tsx_async_abort` entry shows "Mitigation: TSX disabled" rather than "Not affected" -- this i5-7500T has TSX support in the silicon but it has been disabled by microcode update, which also mitigates TSX-related attacks.

## 6. Current Kernel Parameters

### 6.1 Boot Parameters (/proc/cmdline)

| Parameter | Value | Source |
|-----------|-------|--------|
| talos.platform | metal | Talos default |
| console | tty0 | Talos default |
| init_on_alloc | 1 | Talos default |
| slab_nomerge | (enabled) | Talos default |
| pti | on | Talos default |
| consoleblank | 0 | Talos default |
| nvme_core.io_timeout | 4294967295 | Talos default |
| printk.devkmsg | on | Talos default |
| selinux | 1 | Talos default |
| module.sig_enforce | 1 | Talos default |
| cpufreq.default_governor | performance | Schematic |
| intel_idle.max_cstate | 0 | Schematic |
| processor.max_cstate | 0 | Schematic |
| transparent_hugepage | madvise | Schematic |
| elevator | none | Schematic |
| mitigations | auto | Schematic |
| init_on_free | 1 | Schematic |
| page_alloc.shuffle | 1 | Schematic |
| randomize_kstack_offset | on | Schematic |
| vsyscall | none | Schematic |
| nvme_core.default_ps_max_latency_us | 0 | Schematic |
| pcie_aspm | off | Schematic |
| workqueue.power_efficient | 0 | Schematic |
| intel_iommu | on | Schematic |
| iommu | force | Schematic |
| iommu.passthrough | 0 | Schematic |
| iommu.strict | 1 | Schematic |

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
| pcie_aspm=off | Disable PCIe Active State Power Management |
| workqueue.power_efficient=0 | Disable power-efficient work queues |
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

**All 17 schematic boot parameters are present in /proc/cmdline.** The node has been upgraded to the factory image with the current schematic. Live state confirms:
- **CPU governor:** performance (confirmed via NFD and sysfs)
- **C-States:** Disabled (intel_idle.max_cstate=0, processor.max_cstate=0)
- **THP:** `always [madvise] never` -- madvise is active (matches schematic)
- **IOMMU:** Active (intel_iommu=on, strict DMA isolation, Queued invalidation)
- **Turbo boost:** Enabled (no_turbo = 0)
- **NVMe power saving:** Disabled (nvme_core.default_ps_max_latency_us=0)
- **PCIe ASPM:** Off (pcie_aspm=off)

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
| net.core.bpf_jit_harden | -- | 2 | N/A (Talos KSPP default) |
| net.ipv4.tcp_slow_start_after_idle | 0 | 0 | Yes |
| net.ipv4.tcp_congestion_control | -- | cubic | N/A (kernel default) |
| net.ipv4.conf.all.rp_filter | 0 | 0 | Yes |
| kernel.kexec_load_disabled | 1 | 1 | Yes |
| kernel.pid_max | 4194304 | 4194304 | Yes |
| fs.inotify.max_user_watches | 524288 | 524288 | Yes |
| net.netfilter.nf_conntrack_max | 131072 | 131072 | Yes |

**All configured sysctls match their live values.** The config from `patches/common.yaml` has been successfully applied.

## 7. Storage Profile

| Device | Model | Type | Size | Scheduler | Rotational | Serial | Role |
|--------|-------|------|------|-----------|:----------:|--------|------|
| sda | SanDisk SD9SB8W1 | SATA SSD | 128 GB | mq-deadline | No | naa.5001b448b9acc025 | Boot/OS (Talos install disk) |
| nvme0n1 | Samsung 980 PRO 250GB | NVMe | 250 GB | none | No | S5GZNF0R129195B | LINSTOR/DRBD storage pool |

### LINSTOR Storage Pools

| Pool | Driver | Free | Total |
|------|--------|------|-------|
| lvm-thick | LVM | 227.88 GiB | 232.88 GiB |
| DfltDisklessStorPool | DISKLESS | -- | -- |

### DRBD Resources

| Resource | Layers | Usage | Connection | State |
|----------|--------|-------|------------|-------|
| pvc-6c978563-f6d1-4ebe-ae76-9875e425bead | DRBD,STORAGE | Unused | Ok | UpToDate |
| pvc-26d10681-35c0-40b9-a2dd-f7d020612ed1 | DRBD,STORAGE | Unused | Ok | Diskless |
| pvc-73e7da84-5ceb-42c9-97db-06a69006d299 | DRBD,STORAGE | Unused | Ok | TieBreaker |

Active DRBD block devices: drbd1000, drbd1017, drbd1018.
Device-mapper device: dm-0 (5.4 GB).
Install disk path: `/dev/disk/by-path/pci-0000:00:17.0-ata-1` (AHCI port ata1, 6.0 Gbps link).

## 8. Network Profile

| Interface | Type | Speed | MTU | Status | Role |
|-----------|------|-------|-----|--------|------|
| enp0s31f6 | Intel I219-LM (8086:15b8, e1000e) | 1 Gbps | 1500 | Up, Full Duplex | Primary NIC (node + DRBD traffic) |
| cilium_vxlan | VXLAN tunnel | -- | -- | Up | Cilium overlay networking |
| cilium_host/cilium_net | Virtual | -- | -- | Up | Cilium host networking |
| lo | Loopback | -- | -- | Up | Loopback |

Traffic statistics (since last boot, ~5.5 hours):
- **enp0s31f6 RX:** 140 MB (176K packets, 3,492 drops, 87 multicast)
- **enp0s31f6 TX:** 236 MB (222K packets, 3 drops)
- **cilium_vxlan RX:** 2.5 MB (39K packets) | **TX:** 174 MB (18K packets)

The 3,492 RX drops on enp0s31f6 represent ~2.0% of total packets. This is elevated but may reflect early boot transient drops before Cilium networking is fully established. The TX-heavy traffic pattern on the physical NIC (236 MB TX vs 140 MB RX) indicates this worker is serving data or sending DRBD replication traffic.

23 active lxc interfaces indicate heavy pod workload on this node.

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
| THP for GFX | Enabled (transparent hugepages for i915) |
| Display | No display connected (eDP disabled, no CRTC found) |

The i915 extension is installed for Intel GPU support. No discrete GPU present. Kaby Lake uses `kbl_dmc` firmware. The GPU can be used for hardware-accelerated video transcoding (Quick Sync) if workloads require it.

## 10. Installed Extensions

| Extension | Version | Purpose |
|-----------|---------|---------|
| drbd | 9.2.16-v1.12.4 | DRBD kernel module for LINSTOR/Piraeus storage replication |
| gvisor | 20260202.0 | gVisor userspace kernel (runsc/runsc-kvm runtime handlers) |
| i915 | 20260110-v1.12.4 | Intel integrated GPU driver |
| intel-ucode | 20260210 | Intel CPU microcode updates |
| nvme-cli | v2.14 | NVMe management utilities |

**Schematic ID:** `24f8c9280e59a44d8d9bc457cb80d5b4182313730710e6e41b413c9ededcb18a`

Note: The standard schematic (`talos-factory-schematic.yaml`) no longer includes `intel-ice-firmware`. The extension list matches the schematic exactly.

## 11. Observations

- **Boot parameters fully applied:** All 17 schematic `extraKernelArgs` are present in `/proc/cmdline`. The node has been successfully upgraded to the factory image with the current schematic. No `make -C talos upgrade-node-05` required.
- **CPU governor correct:** Running `performance` as intended. C-states are disabled (intel_idle.max_cstate=0, processor.max_cstate=0). Turbo boost is enabled with a max frequency of 3.30 GHz.
- **Sysctls fully applied:** All configured sysctls from `patches/common.yaml` match the live values.
- **IOMMU fully active:** Intel VT-d is enabled with strict DMA isolation, Queued invalidation, and IRQ remapping in x2apic mode. All 12 PCI devices are in IOMMU groups.
- **Different CPU from CP nodes:** Intel Core i5-7500T @ 2.70GHz vs CP nodes' i5-7400T @ 2.40GHz. Same Kaby Lake architecture (family 6 model 158), same 4C/4T (no HT), same 6MB L3, but higher base clock (+300 MHz) and turbo up to 3.30 GHz.
- **24 GB RAM (not 32 GB):** This node has 24 GB total memory, less than the 32 GB in CP nodes. Memory utilization is light (~10% used, ~21.8 GB available), but the lower total capacity should be considered when scheduling memory-intensive workloads.
- **Samsung 980 PRO NVMe:** Device ID 0xa80a. PCIe Gen 3x4 in this system (CPU/chipset does not support Gen 4). NVMe power saving disabled via boot parameter. D3 entry latency set to 10 seconds. 4 NVMe queues configured (4/0/0 default/read/poll).
- **SanDisk boot disk:** Uses a SanDisk SD9SB8W1 SATA SSD (128 GB) instead of the Intenso SSD found on other nodes. Functionally equivalent for Talos boot/OS purposes. I/O scheduler is `mq-deadline` (appropriate for SATA SSD).
- **LINSTOR storage pool healthy:** LVM-thick pool with 227.88 GiB free of 232.88 GiB total (~2.1% used). 3 DRBD resources: 1 UpToDate, 1 Diskless, 1 TieBreaker. Low storage utilization.
- **Intel Bluetooth controller present:** USB device 8087:0a2a detected. Unused in headless server configuration, harmless.
- **TSX disabled via microcode:** This i5-7500T reports "Mitigation: TSX disabled" for tsx_async_abort -- indicating the silicon originally supported TSX but the microcode update disabled it. Security posture equivalent to "Not affected".
- **SGX enabled:** Intel SGX is available with 98 MB EPC (Enclave Page Cache). Not currently utilized but available for confidential computing workloads.
- **gVisor available:** The gvisor extension provides `runsc` and `runsc-kvm` runtime handlers for sandboxed container execution.
- **Elevated RX drops:** 3,492 drops (~2.0%) on enp0s31f6 since boot. This warrants monitoring -- if persistent under steady-state load, may indicate NIC ring buffer or interrupt coalescing tuning is needed.
- **Heavy pod workload:** 23 active lxc interfaces indicate this is one of the more heavily utilized worker nodes.
- **No taints:** Node is healthy with no taints applied. All conditions report nominal status.
- **Kernel modules loaded:** drbd, drbd_transport_tcp, i915, e1000e, nvme, iTCO_wdt, ahci, intel_rapl_msr, intel_rapl_common -- all expected for this hardware profile.
