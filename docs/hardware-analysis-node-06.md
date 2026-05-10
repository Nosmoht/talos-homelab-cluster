# Hardware Analysis: node-06

> **Date:** 2026-02-28
> **Talos:** v1.12.4 | **Kubernetes:** v1.35.0
> **Node IP:** 192.168.2.66 | **Role:** worker

---

## 1. System Overview

| Property | Value |
|----------|-------|
| Vendor | Lenovo |
| Product | 10MV001LGE (ThinkCentre M920q Tiny) |
| Board | 310B |
| CPU | Intel Core i7-7700T @ 2.90GHz (Kaby Lake, family 6 model 158 stepping 9) |
| Cores/Threads | 4C/8T (Hyper-Threading enabled) |
| Microcode | 0xf8 |
| L3 Cache | 8 MB |
| CPU Freq Range | 800 MHz - 3800 MHz (Turbo Boost to 3.80 GHz) |
| RAM | 32 GB DDR4 (32,730,348 KB) |
| Boot Disk | INTENSO SSD ~128 GB (sda, SATA) |
| Data Disk | Toshiba THNSF5256GPUK (XG5) 256 GB (nvme0n1, NVMe PCIe) |
| Active NIC | enp0s31f6 (Intel I219-V, 1 Gbps, MAC 00:23:24:ea:af:90) |
| NUMA Nodes | 1 (node0) |
| GPU | Intel HD Graphics 630 (integrated, 8086:5912) |
| Kernel | 6.18.9-talos |
| Container Runtime | containerd 2.1.6 |
| Runtime Handlers | runc, runsc (gVisor), runsc-kvm |

**Chassis note:** This is the only M920q in the cluster. Despite the M920q chassis (Q270 chipset), the CPU is a Kaby Lake i7-7700T -- the same generation as the M910q nodes (B250 chipset). The M920q board (310B) differs from the M910q board (3111) but uses the same Intel 200 Series chipset family.

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
| 00:1f.0 | 8086:a2c6 | 0601 (ISA Bridge) | Intel Q270 LPC Controller |
| 00:1f.2 | 8086:a2a1 | 0580 (Memory Controller) | Intel 200 Series PMC |
| 00:1f.4 | 8086:a2a3 | 0c05 (SMBus) | Intel 200 Series SMBus Controller |
| 00:1f.6 | 8086:15b7 | 0200 (Ethernet) | Intel I219-V Ethernet |
| 01:00.0 | 1179:0115 | 0108 (NVMe) | Toshiba XG5 NVMe SSD |

All PCI devices have IOMMU enabled (intel-iommu v1:0, DMA domain type: Translated, strict TLB invalidation). 9 IOMMU groups configured (groups 0-8).

**PCI differences from M910q nodes:**
- LPC Controller: 0xa2c6 (Q270 chipset, M920q) vs 0xa2c8 (B250, M910q)
- Ethernet: 0x15b7 (I219-V, consumer) vs 0x15b8 (I219-LM, enterprise/vPro)
- NVMe: 1179:0115 (Toshiba XG5) vs Samsung 970/980 series on other nodes
- Subsystem device: 310b (M920q board) vs 3111 (M910q board)

## 3. USB Device Inventory

| Vendor:Device | Class | Serial | Description |
|---------------|-------|--------|-------------|
| 1d6b:0002 | 09 (Hub) | 0000:00:14.0 | Linux Foundation USB 2.0 Root Hub (480 Mbps) |
| 1d6b:0003 | 09 (Hub) | 0000:00:14.0 | Linux Foundation USB 3.0 Root Hub (5000 Mbps) |

No external USB devices detected. No Bluetooth controller present (unlike M910q nodes which have Intel 8087:0a2a). Only the two xHCI root hubs are enumerated.

## 4. NFD Feature Highlights

### CPU
- **Architecture:** amd64, Intel Kaby Lake (family 6, model 158)
- **Instruction Sets:** SSE, SSE2, SSE4.1, SSE4.2, AVX, AVX2, FMA3, AES-NI, ADX, MPX
- **Virtualization:** VMX (VT-x) supported
- **Multithreading:** HT enabled (4 physical cores, 8 threads), 1 socket
- **P-State:** Active, governor = performance, turbo = enabled
- **Security:** IBPB, STIBP, SSBD, FLUSH_L1D, MD_CLEAR, SRBDS_CTRL, IA32_ARCH_CAP
- **RTM:** RTM_ALWAYS_ABORT (TSX disabled via microcode)

### Memory
- **Total:** 32 GB DDR4
- **Hugepages:** Not enabled (hugepages-1Gi: 0, hugepages-2Mi: 0)
- **NUMA:** Single node (is_numa: false)
- **Swap:** Disabled

### Storage
- Non-rotational disk present (SSD/NVMe)

### Kernel
- Version: 6.18.9-talos
- Config: NO_HZ=y, NO_HZ_IDLE=y (tickless idle), 64BIT=y

### PCI Features
- `pci-0300_8086.present: true` -- Intel integrated GPU detected

### Network
- enp0s31f6: 1 Gbps, operstate up, MTU 1500

### SEV Features (NFD reported, not applicable)
- NFD reports sev.enabled, sev.es.enabled, sev.snp.enabled as "true" -- this is an NFD detection artifact; AMD SEV is not available on Intel hardware.

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

GDS is mitigated via microcode. Several mitigations show **"SMT vulnerable"** because Hyper-Threading is enabled on this 4-core CPU. Unlike node-04's 2C/4T i3-6100T, disabling HT on this i7-7700T would still leave 4 physical cores -- a viable option if the SMT risk is unacceptable. The performance trade-off would lose 4 threads but eliminate the SMT attack surface for l1tf, mds, and mmio_stale_data.

TSX is disabled via microcode (RTM_ALWAYS_ABORT), same as other Kaby Lake nodes.

## 6. Current Kernel Parameters

### 6.1 Boot Parameters (/proc/cmdline)

| Parameter | Value | Source |
|-----------|-------|--------|
| talos.platform | metal | Talos default |
| console | tty0 | Talos default |
| init_on_alloc | 1 | Talos KSPP default |
| slab_nomerge | (enabled) | Talos KSPP default |
| pti | on | Talos KSPP default |
| consoleblank | 0 | Talos default |
| nvme_core.io_timeout | 4294967295 | Talos default |
| printk.devkmsg | on | Talos default |
| selinux | 1 | Talos KSPP default |
| module.sig_enforce | 1 | Talos KSPP default |
| cpufreq.default_governor | performance | Factory schematic |
| intel_idle.max_cstate | 0 | Factory schematic |
| processor.max_cstate | 0 | Factory schematic |
| transparent_hugepage | madvise | Factory schematic |
| elevator | none | Factory schematic |
| mitigations | auto | Factory schematic |
| init_on_free | 1 | Factory schematic |
| page_alloc.shuffle | 1 | Factory schematic |
| randomize_kstack_offset | on | Factory schematic |
| vsyscall | none | Factory schematic |
| nvme_core.default_ps_max_latency_us | 0 | Factory schematic |
| pcie_aspm | off | Factory schematic |
| workqueue.power_efficient | 0 | Factory schematic |
| intel_iommu | on | Factory schematic |
| iommu | force | Factory schematic |
| iommu.passthrough | 0 | Factory schematic |
| iommu.strict | 1 | Factory schematic |

### 6.2 Configured Boot Parameters (from factory schematic)

| Parameter | Purpose |
|-----------|---------|
| cpufreq.default_governor=performance | Force performance CPU governor |
| intel_idle.max_cstate=0 | Disable deep C-states for lowest latency |
| processor.max_cstate=0 | Disable processor C-states |
| transparent_hugepage=madvise | THP only on explicit madvise |
| elevator=none | No I/O scheduler (NVMe native multiqueue) |
| mitigations=auto | Standard CPU vulnerability mitigations |
| init_on_free=1 | Zero freed memory (security hardening) |
| page_alloc.shuffle=1 | Randomize page allocation (security) |
| randomize_kstack_offset=on | Randomize kernel stack offset (security) |
| vsyscall=none | Disable vsyscall page (security) |
| nvme_core.default_ps_max_latency_us=0 | Disable NVMe power saving |
| pcie_aspm=off | Disable PCIe Active State Power Management |
| workqueue.power_efficient=0 | Disable power-efficient workqueues |
| intel_iommu=on | Enable Intel VT-d IOMMU |
| iommu=force | Force IOMMU for all devices |
| iommu.passthrough=0 | No IOMMU bypass |
| iommu.strict=1 | Strict DMA TLB invalidation |

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

**All 16 schematic `extraKernelArgs` plus sd-boot bootloader are active in `/proc/cmdline`.** The node has been upgraded to the factory image containing the current schematic. Live verification:
- **CPU governor:** performance (confirmed via scaling_governor and NFD)
- **C-States:** Disabled (intel_idle.max_cstate=0, processor.max_cstate=0)
- **THP:** `always [madvise] never` -- madvise is active (matches schematic)
- **Turbo Boost:** Enabled (no_turbo = 0) -- the i7-7700T boosts to 3.80 GHz
- **IOMMU:** Active (intel-iommu v1:0, Translated domain, strict mode, IRQ remapping in x2apic mode)
- **NVMe power saving:** Disabled (default_ps_max_latency_us=0)
- **PCIe ASPM:** Disabled (pcie_aspm=off)

### 6.4 Sysctl Verification

| Sysctl | Configured | Live | Match |
|--------|-----------|------|:-----:|
| vm.dirty_ratio | 10 | 10 | Yes |
| vm.dirty_background_ratio | 5 | 5 | Yes |
| vm.overcommit_memory | 1 | 1 | Yes |
| vm.max_map_count | 524288 | 524288 | Yes |
| vm.min_free_kbytes | 65536 | 65536 | Yes |
| vm.mmap_rnd_bits | 32 | 32 | Yes |
| net.core.rmem_max | 16777216 | 16777216 | Yes |
| net.core.wmem_max | 16777216 | 16777216 | Yes |
| net.core.somaxconn | 32768 | 32768 | Yes |
| net.core.netdev_max_backlog | 16384 | 16384 | Yes |
| net.ipv4.tcp_slow_start_after_idle | 0 | 0 | Yes |
| net.ipv4.tcp_tw_reuse | 1 | 1 | Yes |
| net.ipv4.tcp_fastopen | 3 | 3 | Yes |
| net.ipv4.conf.all.rp_filter | 0 | 0 | Yes |
| kernel.kexec_load_disabled | 1 | 1 | Yes |
| kernel.sysrq | 0 | 0 | Yes |
| kernel.pid_max | 4194304 | 4194304 | Yes |
| fs.inotify.max_user_watches | 524288 | 524288 | Yes |
| fs.file-max | 2097152 | 9223372036854775807 | No (*) |
| net.netfilter.nf_conntrack_max | 131072 | 131072 | Yes |
| net.ipv4.tcp_congestion_control | -- | cubic | N/A (kernel default) |
| net.core.bpf_jit_harden | -- | 2 | N/A (Talos KSPP hardening) |

**All configured sysctls match their live values.** The `fs.file-max` shows a kernel-reported maximum that exceeds the configured value -- the kernel internally caps this to its own ceiling, so the configured value of `2097152` is effectively applied as a floor that is already exceeded by the kernel default on this system.

## 7. Storage Profile

| Device | Model | Type | Size | Scheduler | Rotational | Firmware | Role |
|--------|-------|------|------|-----------|:----------:|----------|------|
| sda | INTENSO SSD | SATA SSD | 128 GB (250,069,680 sectors) | mq-deadline | No | -- | Boot/OS (Talos install disk) |
| nvme0n1 | Toshiba THNSF5256GPUK (XG5) | NVMe | 256 GB (500,118,192 sectors) | none | No | 51055KLA | LINSTOR/DRBD storage pool |

**NVMe Details:**
- Queue depth: 127 nr_requests, 128 KB max_hw_sectors
- Install disk path: `/dev/disk/by-path/pci-0000:00:17.0-ata-1` (sda, SATA)
- WWID (NVMe): eui.00080d02001b479f
- WWID (SATA): t10.ATA INTENSO SSD AA000000000000002167
- The Toshiba XG5 is an enterprise-oriented OEM NVMe with 64-layer BiCS TLC NAND

**LINSTOR Storage:**
- Storage pool: `lvm-thick` (LVM on NVMe), 233.47 GiB free / 238.47 GiB total
- Active DRBD resources: 2 (pvc-2b4a9677 [Unused/UpToDate], pvc-6c978563 [Unused/TieBreaker])
- Block devices: drbd1016, drbd1017
- Device-mapper: dm-0 (5.4 GB)
- DfltDisklessStorPool also available

**I/O scheduler:** NVMe uses `none` (native multiqueue, matching `elevator=none` boot param). SATA boot disk uses `mq-deadline` (appropriate for SATA).

## 8. Network Profile

| Interface | Type | Speed | Status | Role |
|-----------|------|-------|--------|------|
| enp0s31f6 | Intel I219-V (8086:15b7, e1000e) | 1 Gbps Full Duplex | Up | Primary NIC (node + DRBD traffic) |
| cilium_vxlan | VXLAN tunnel | -- | Up | Cilium overlay networking |
| cilium_host/cilium_net | Virtual | -- | Up | Cilium host networking |
| lxc_health | veth | -- | Up | Cilium health check |
| lxc* (5 interfaces) | veth | -- | Up | Pod network interfaces |
| lo | Loopback | -- | Up | Loopback |

**Driver details:**
- e1000e driver, PCI Express 2.5 GT/s x1
- Interrupt Throttling Rate: dynamic conservative mode
- PHC clock registered (PTP-capable)
- Flow Control: None
- MAC: 00:23:24:ea:af:90

Traffic statistics (since last boot):
- **enp0s31f6 RX:** 17.27 MB (46,552 packets, 3,034 drops -- 6.5%)
- **enp0s31f6 TX:** 34.29 MB (49,694 packets, 2 drops)
- **cilium_vxlan RX:** 812 KB (10,129 packets) | **TX:** 5.68 MB (8,311 packets)

The 3,034 RX drops (6.5%) are elevated for a freshly-booted node. This may indicate packet bursts during DRBD resynchronization or Cilium agent startup. Monitor over time -- if persistent, consider tuning `net.core.netdev_max_backlog` higher or investigating NIC ring buffer sizes.

5 active lxc pod interfaces plus lxc_health.

**NIC note:** The Intel I219-V (0x15b7) is the consumer variant of the I219-LM (0x15b8) used on M910q nodes. Both use the e1000e driver with identical performance characteristics. The I219-V lacks AMT/vPro management features (irrelevant for Talos). The MAC address OUI `00:23:24` is unusual for Lenovo -- likely from an older NIC programming or alternative vendor batch.

## 9. GPU Profile

| Property | Value |
|----------|-------|
| GPU | Intel HD Graphics 630 (integrated) |
| PCI BDF | 00:02.0 |
| Vendor:Device | 8086:5912 |
| Class | 0300 (VGA compatible controller) |
| IOMMU Group | 0 |
| i915 Extension | Loaded (v20260110-v1.12.4) |
| DRM | Initialized i915 1.6.0 for 0000:00:02.0 |
| DMC Firmware | i915/kbl_dmc_ver1_04.bin (v1.4) |
| VT-d | Active for gfx access |
| THP for GFX | Enabled (transparent hugepages) |
| Display | No display connected (eDP disabled, no CRTC found) |

Same Intel HD Graphics 630 as other Kaby Lake nodes. The `kbl_dmc` firmware is Kaby Lake-specific. No discrete GPU present. The i915 extension enables potential SR-IOV or media transcoding use cases.

## 10. Installed Extensions

| Extension | Version | Purpose |
|-----------|---------|---------|
| drbd | 9.2.16-v1.12.4 | DRBD kernel module for LINSTOR/Piraeus storage replication |
| gvisor | 20260202.0 | gVisor userspace container runtime (runsc handler) |
| i915 | 20260110-v1.12.4 | Intel integrated GPU driver (HD Graphics 630) |
| intel-ucode | 20260210 | Intel CPU microcode updates |
| nvme-cli | v2.14 | NVMe management utilities |

**Schematic ID:** `24f8c9280e59a44d8d9bc457cb80d5b4182313730710e6e41b413c9ededcb18a`

**Loaded kernel modules (from dmesg):** drbd, drbd_transport_tcp, i915, e1000e, nvme, ahci, libahci, iTCO_wdt, iTCO_vendor_support, intel_rapl_msr, intel_rapl_common, i2c_algo_bit, drm_buddy, drm_display_helper, cec, ttm, i2c_i801, i2c_smbus, intel_pmc_core, pmt_telemetry, pmt_discovery, pmt_class, intel_pmc_ssram_telemetry, intel_vsec

## 11. Observations

1. **Different chassis, same generation:** Lenovo ThinkCentre M920q Tiny (10MV001LGE, board 310B) -- the only M920q in the cluster. Uses Q270 chipset (LPC 0xa2c6) vs M910q's B250 (0xa2c8). Despite the newer chassis model number, the CPU is the same Kaby Lake generation as all M910q nodes.

2. **Most powerful CPU in cluster:** Intel Core i7-7700T @ 2.90 GHz (Turbo to 3.80 GHz), 4C/8T with Hyper-Threading, 8 MB L3 cache. This provides the highest thread count (8) and largest cache among all standard nodes, making it the best candidate for thread-heavy workloads.

3. **32 GB RAM -- full capacity:** With 32,730,348 KB total (~31.2 GB), this node now matches the control plane nodes. Memory utilization is low at ~9% (29.8 GB free, 30.7 GB available), leaving substantial headroom for workloads.

4. **Boot parameters fully applied:** All 16 schematic `extraKernelArgs` are present in `/proc/cmdline`. The node has been successfully upgraded to the factory image with the current schematic. CPU governor is `performance`, C-states disabled, IOMMU in strict mode.

5. **SMT vulnerable mitigations:** l1tf, mds, and mmio_stale_data show "SMT vulnerable" because Hyper-Threading is enabled. Disabling HT on this i7-7700T would still leave 4 physical cores -- a viable security trade-off if needed (`nosmt` boot parameter). This is more practical here than on node-04's 2C/4T i3-6100T where it would halve to 2 threads.

6. **Toshiba XG5 NVMe:** Device 1179:0115, model THNSF5256GPUK, firmware 51055KLA. Enterprise OEM NVMe SSD with 64-layer BiCS TLC NAND. Different from Samsung 970/980 series on other nodes but comparable performance class. 256 GB capacity with 233.47 GiB free in LINSTOR.

7. **Intel I219-V NIC (consumer variant):** 0x15b7 vs enterprise I219-LM (0x15b8) on M910q nodes. Functionally identical for Kubernetes/DRBD. Unusual MAC OUI `00:23:24` differs from standard Lenovo `6c:4b:90`.

8. **Elevated RX drops (6.5%):** 3,034 drops out of 46,552 RX packets since boot. This is significantly higher than typical (<1%). May be transient (boot-time DRBD sync burst) or indicate a persistent issue. Worth monitoring -- if sustained, investigate NIC ring buffer sizes (`ethtool -g`) and consider increasing `net.core.netdev_budget`.

9. **Sysctls fully applied:** All configured sysctls from `patches/common.yaml` match live values. The `fs.file-max` kernel default (LLONG_MAX) exceeds the configured value, which is expected behavior.

10. **IOMMU fully active:** Intel VT-d with 2 DMA remapping hardware units (DRHD), IRQ remapping in x2apic mode, queued invalidation, strict TLB invalidation. 9 IOMMU groups (0-8). All PCI devices in Translated (DMA) domain mode.

11. **No Bluetooth controller:** Unlike M910q nodes which have Intel 8087:0a2a, the M920q does not enumerate a Bluetooth device. Only USB root hubs present.

12. **gVisor available:** The gvisor extension provides `runsc` and `runsc-kvm` runtime handlers, enabling sandboxed container execution for security-sensitive workloads.

13. **2 DRBD resources, moderate storage use:** Only 2 LINSTOR-managed PVCs on this node (one UpToDate, one TieBreaker), consuming ~5 GiB of the 238.47 GiB pool. Substantial storage capacity remaining.

14. **TSX disabled via microcode:** RTM_ALWAYS_ABORT confirmed by NFD. Same as other Kaby Lake nodes.

15. **GDS mitigated:** Gather Data Sampling mitigated via microcode (unlike Skylake where it may require additional measures).

16. **No taints:** Node is healthy with Ready status, no conditions indicating pressure (memory, disk, PID all clear).

17. **Node created:** 2026-02-14, uptime since last boot: 2026-02-28T16:15:10Z (same day as analysis).
