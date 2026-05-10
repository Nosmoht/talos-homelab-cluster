# Hardware Analysis: node-01

> **Date:** 2026-02-28
> **Talos:** v1.12.4 | **Kubernetes:** v1.35.0 | **Kernel:** 6.18.9-talos
> **Node IP:** 192.168.2.61 | **Role:** control-plane

---

## 1. System Overview

| Property | Value |
|----------|-------|
| Vendor | Lenovo |
| Product | 10MQS7QB00 (ThinkCentre M910q Tiny) |
| Board | 3111 |
| CPU | Intel Core i5-7400T @ 2.40 GHz (Kaby Lake, family 6, model 158, stepping 9) |
| Cores / Threads | 4C / 4T (no Hyper-Threading) |
| CPU Freq Range | 800 MHz - 3000 MHz (base 2400 MHz, turbo to 3.0 GHz) |
| Microcode | 0xf8 |
| L3 Cache | 6 MB |
| Turbo Boost | Enabled (no_turbo = 0) |
| Governor | performance (available: performance, powersave) |
| RAM | 32 GB DDR4 (32,731,576 KB total, ~31.2 GiB) |
| Boot Disk | INTENSO SSD 128 GB (sda, SATA) |
| Data Disk | Samsung SSD 970 PRO 512 GB (nvme0n1, NVMe PCIe) |
| Active NIC | enp0s31f6 (Intel I219-V 8086:15b8, e1000e, 1 Gbps, MAC 6c:4b:90:79:3e:4c) |
| NUMA Nodes | 1 (node0) |
| GPU | Intel HD Graphics 630 (integrated, 8086:5912) |
| Container Runtime | containerd 2.1.6 |
| Runtime Handlers | runc, runsc (gVisor), runsc-kvm |
| Bootloader | sd-boot (UEFI) |

---

## 2. PCI Device Inventory

| BDF | Vendor:Device | Class | Description |
|-----|---------------|-------|-------------|
| 00:00.0 | 8086:591f | 0600 (Host Bridge) | Intel Kaby Lake Host Bridge/DRAM Registers |
| 00:02.0 | 8086:5912 | 0300 (VGA) | Intel HD Graphics 630 |
| 00:14.0 | 8086:a2af | 0c03 (USB) | Intel 200 Series USB 3.0 xHCI Controller |
| 00:14.2 | 8086:a2b1 | 1180 (Signal Processing) | Intel 200 Series Thermal Subsystem |
| 00:16.0 | 8086:a2ba | 0780 (Communication) | Intel 200 Series CSME HECI #1 |
| 00:17.0 | 8086:a282 | 0106 (SATA/AHCI) | Intel 200 Series SATA Controller (AHCI) |
| 00:1b.0 | 8086:a2eb | 0604 (PCI Bridge) | Intel 200 Series PCIe Root Port |
| 00:1f.0 | 8086:a2c8 | 0601 (ISA Bridge) | Intel 200 Series LPC Controller |
| 00:1f.2 | 8086:a2a1 | 0580 (Memory Controller) | Intel 200 Series PMC |
| 00:1f.4 | 8086:a2a3 | 0c05 (SMBus) | Intel 200 Series SMBus Controller |
| 00:1f.6 | 8086:15b8 | 0200 (Ethernet) | Intel I219-V Ethernet Controller |
| 01:00.0 | 144d:a808 | 0108 (NVMe) | Samsung 970 PRO NVMe SSD |

All PCI devices are in IOMMU DMA domain (Intel VT-d active, strict translated mode, queued invalidation).

---

## 3. USB Device Inventory

| Vendor:Device | Class | Description |
|---------------|-------|-------------|
| 046a:0011 | 03 (HID) | Cherry keyboard/input device |
| 1d6b:0002 | 09 (Hub) | Linux Foundation USB 2.0 Root Hub |
| 1d6b:0003 | 09 (Hub) | Linux Foundation USB 3.0 Root Hub |

USB controller: xHCI on 0000:00:14.0, 12 USB 2.0 ports + 6 USB 3.0 ports.
One low-speed USB HID device on port 1-11.

---

## 4. NFD Feature Highlights

### CPU
- **Architecture:** amd64, Intel Kaby Lake (family 6, model 158)
- **Instruction Sets:** SSE, SSE2, SSE4.1, SSE4.2, AVX, AVX2, FMA3, AES-NI, ADX, MOVBE
- **Virtualization:** VMX (VT-x) supported
- **Multithreading:** false (4 physical cores, no SMT)
- **P-State:** Active, governor = performance, turbo = true
- **Security:** IBPB, STIBP, SSBD, FLUSH_L1D, MD_CLEAR, SRBDS_CTRL, IA32_ARCH_CAP
- **RTM:** Always abort (TSX disabled via microcode)

### Storage
- `storage-nonrotationaldisk: true` (all block devices are SSD/NVMe)

### Kernel
- Version: 6.18.9-talos
- Config: NO_HZ=y, NO_HZ_IDLE=y (tickless idle)

### PCI Features
- `pci-0300_8086.present: true` -- Intel integrated GPU detected

---

## 5. CPU Vulnerability Status

| Vulnerability | Status |
|---------------|--------|
| gather_data_sampling | **Mitigation:** Microcode |
| ghostwrite | Not affected |
| indirect_target_selection | Not affected |
| itlb_multihit | **Mitigation:** KVM: Split huge pages |
| l1tf | **Mitigation:** PTE Inversion; VMX: conditional cache flushes, SMT disabled |
| mds | **Mitigation:** Clear CPU buffers; SMT disabled |
| meltdown | **Mitigation:** PTI |
| mmio_stale_data | **Mitigation:** Clear CPU buffers; SMT disabled |
| old_microcode | Not affected |
| reg_file_data_sampling | Not affected |
| retbleed | **Mitigation:** IBRS |
| spec_rstack_overflow | Not affected |
| spec_store_bypass | **Mitigation:** Speculative Store Bypass disabled via prctl |
| spectre_v1 | **Mitigation:** usercopy/swapgs barriers and __user pointer sanitization |
| spectre_v2 | **Mitigation:** IBRS; IBPB: conditional; STIBP: disabled; RSB filling; PBRSB-eIBRS: Not affected; BHI: Not affected |
| srbds | **Mitigation:** Microcode |
| tsa | Not affected |
| tsx_async_abort | Not affected |
| vmscape | **Mitigation:** IBPB before exit to userspace |

All applicable Kaby Lake vulnerabilities are mitigated. Microcode 0xf8 is current (old_microcode = Not affected). `mitigations=auto` boot param ensures all recommended mitigations are applied. No SMT to disable (4C/4T).

---

## 6. Current Kernel Parameters

### 6.1 Boot Parameters (/proc/cmdline)

```
talos.platform=metal console=tty0 init_on_alloc=1 slab_nomerge pti=on consoleblank=0
nvme_core.io_timeout=4294967295 printk.devkmsg=on selinux=1 module.sig_enforce=1
cpufreq.default_governor=performance intel_idle.max_cstate=0 processor.max_cstate=0
transparent_hugepage=madvise elevator=none mitigations=auto init_on_free=1
page_alloc.shuffle=1 randomize_kstack_offset=on vsyscall=none
nvme_core.default_ps_max_latency_us=0 pcie_aspm=off workqueue.power_efficient=0
intel_iommu=on iommu=force iommu.passthrough=0 iommu.strict=1
```

### 6.2 Boot Parameter Breakdown

| Category | Parameter | Purpose |
|----------|-----------|---------|
| Performance | `cpufreq.default_governor=performance` | Lock CPU to max frequency |
| Performance | `intel_idle.max_cstate=0` | Disable deep C-states |
| Performance | `processor.max_cstate=0` | Disable processor C-states |
| Performance | `transparent_hugepage=madvise` | THP only for apps that opt in |
| Performance | `elevator=none` | No I/O scheduler (NVMe native multiqueue) |
| Performance | `nvme_core.default_ps_max_latency_us=0` | Disable NVMe power states |
| Performance | `pcie_aspm=off` | Disable PCIe Active State Power Management |
| Performance | `workqueue.power_efficient=0` | Disable power-efficient workqueues |
| Security | `mitigations=auto` | Apply all CPU vulnerability mitigations |
| Security | `init_on_alloc=1` | Zero memory on allocation (Talos default) |
| Security | `init_on_free=1` | Zero memory on free |
| Security | `slab_nomerge` | Prevent slab cache merging (Talos default) |
| Security | `pti=on` | Page Table Isolation (Talos default) |
| Security | `page_alloc.shuffle=1` | Randomize page allocator freelists |
| Security | `randomize_kstack_offset=on` | Per-syscall kernel stack offset randomization |
| Security | `vsyscall=none` | Disable vsyscall (removes fixed-address gadgets) |
| Security | `module.sig_enforce=1` | Require signed kernel modules (Talos default) |
| Security | `selinux=1` | Enable SELinux (Talos default) |
| IOMMU | `intel_iommu=on` | Enable Intel VT-d IOMMU |
| IOMMU | `iommu=force` | Force IOMMU for all DMA devices |
| IOMMU | `iommu.passthrough=0` | Translated mode (no IOMMU bypass) |
| IOMMU | `iommu.strict=1` | Strict DMA TLB invalidation |
| NVMe | `nvme_core.io_timeout=4294967295` | Effectively infinite I/O timeout (Talos default) |
| Debug | `printk.devkmsg=on`, `consoleblank=0`, `console=tty0` | Console output (Talos defaults) |

### 6.3 Boot Parameter Gap Analysis

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

**All 17 schematic boot parameters are present in /proc/cmdline. No gaps.**

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

**All configured sysctls match their live values. No drift detected.**

---

## 7. Storage Profile

| Device | Model | Type | Size | Scheduler | Rotational | Role |
|--------|-------|------|------|-----------|:----------:|------|
| sda | INTENSO SSD | SATA SSD | 128 GB | mq-deadline | No | Boot/OS (Talos install disk) |
| nvme0n1 | Samsung SSD 970 PRO 512GB | NVMe | 512 GB | none | No | LINSTOR/DRBD storage pool |

**Install disk path:** `/dev/disk/by-path/pci-0000:00:17.0-ata-1` (sda, SATA via AHCI controller)

**NVMe details:**
- Controller: Samsung a808 (PCI 0000:01:00.0, subsystem 144d:a801)
- Firmware: 1B2QEXP7
- Serial: S463NX0MA00749A
- WWID: eui.0025385a91b011b2
- I/O timeout: infinite (boot param)
- Power states: disabled (boot param)
- I/O scheduler: none (optimal for NVMe direct multiqueue submission)

**DRBD volumes on this node:** drbd1000-drbd1005, drbd1016-drbd1018 (9 volumes total)
**Device-mapper devices:** dm-0 through dm-8 (LVM/thin provisioning for LINSTOR)

---

## 8. Network Profile

| Interface | Type | Speed | Duplex | MTU | State | Driver |
|-----------|------|-------|--------|-----|-------|--------|
| enp0s31f6 | Intel I219-V (8086:15b8) | 1000 Mbps | Full | 1500 | Up | e1000e |
| cilium_vxlan | VXLAN tunnel | -- | -- | -- | Up | -- |
| cilium_host / cilium_net | Virtual | -- | -- | -- | Up | -- |
| lo | Loopback | -- | -- | -- | Up | -- |

**PCI info:** PCI Express 2.5 GT/s x1, interrupt throttling in dynamic conservative mode.

**Traffic statistics (since boot 2026-02-28T14:52):**

| Interface | RX Bytes | RX Packets | RX Drops | TX Bytes | TX Packets | TX Drops |
|-----------|----------|------------|----------|----------|------------|----------|
| enp0s31f6 | 5.18 GB | 5,637,626 | 12,901 | 6.39 GB | 6,531,603 | 4 |
| cilium_vxlan | 2.91 GB | 1,157,742 | 0 | 4.70 GB | 804,426 | 0 |
| lo | 1.37 GB | 4,676,633 | 0 | 1.37 GB | 4,676,633 | 0 |

**VIP:** 192.168.2.60/32 currently assigned on enp0s31f6 (control plane VIP, gratuitous ARP sent).

**Notes on RX drops:** 12,901 RX drops on enp0s31f6 (~0.23% of total RX packets). This is within acceptable range for a 1 GbE Intel NIC but warrants monitoring. Likely caused by brief traffic bursts exceeding NIC ring buffer capacity.

---

## 9. GPU Profile

| Property | Value |
|----------|-------|
| GPU | Intel HD Graphics 630 (integrated) |
| PCI BDF | 00:02.0 |
| Vendor:Device | 8086:5912 |
| Class | 0300 (VGA compatible controller) |
| i915 Extension | Loaded (v20260110-v1.12.4) |
| DRM | Initialized i915 1.6.0 for 0000:00:02.0 |
| Display Version | 9.00, stepping C0 |
| DMC Firmware | i915/kbl_dmc_ver1_04.bin (v1.4) |
| VT-d | Active for gfx access |
| IOMMU Group | 0 |
| Display | No display connected (eDP disabled) |
| THP | Active for i915 |

No discrete GPU. The i915 extension provides the kernel module for the integrated GPU, enabling potential hardware video transcoding (QuickSync/VA-API) for workloads if needed.

---

## 10. Installed Extensions

| Extension | Version | Purpose |
|-----------|---------|---------|
| drbd | 9.2.16-v1.12.4 | DRBD kernel module for LINSTOR/Piraeus storage replication |
| gvisor | 20260202.0 | gVisor userspace container runtime (runsc + runsc-kvm handlers) |
| i915 | 20260110-v1.12.4 | Intel integrated GPU kernel driver |
| intel-ucode | 20260210 | Intel CPU microcode updates |
| nvme-cli | v2.14 | NVMe management utilities |

**Schematic ID:** `24f8c9280e59a44d8d9bc457cb80d5b4182313730710e6e41b413c9ededcb18a`

**Kernel modules loaded (from dmesg):**
- drbd, drbd_transport_tcp (out-of-tree, DRBD replication)
- i915, i2c_algo_bit, drm_buddy, drm_display_helper, cec, ttm (GPU stack)
- e1000e (Intel ethernet)
- nvme (NVMe storage)
- ahci, libahci (SATA)
- i2c_i801, i2c_smbus (I2C/SMBus)
- iTCO_wdt, iTCO_vendor_support, watchdog (hardware watchdog)
- intel_rapl_msr, intel_rapl_common (power monitoring)
- intel_pmc_core, pmt_telemetry, pmt_discovery, pmt_class, intel_pmc_ssram_telemetry, intel_vsec (platform monitoring)

---

## 11. Observations

1. **All boot parameters applied.** All 17 schematic `extraKernelArgs` are present in `/proc/cmdline`. The node has been upgraded to the factory image with the current schematic. CPU governor is `performance`, C-states are disabled, IOMMU is in strict translated mode.

2. **All sysctls match.** No drift between configured values in `patches/common.yaml` and live values on the node. Security and performance tuning is fully active.

3. **CPU mitigations are comprehensive.** All Kaby Lake vulnerabilities have active mitigations. Microcode 0xf8 is current. PTI is active. No SMT means no HT-related side-channel exposure.

4. **Memory utilization is healthy.** ~24 GB free out of ~31 GB total. MemAvailable is ~28 GB (~87%). The 64 MB min_free_kbytes reserve is appropriate for the 32 GB total.

5. **Storage configuration is correct.** OS on SATA SSD (128 GB, mq-deadline scheduler), data on NVMe (512 GB Samsung 970 PRO, none scheduler). The 970 PRO is a high-endurance MLC drive, well-suited for DRBD replication workloads. 9 DRBD volumes are active on this node.

6. **NVMe I/O scheduler.** `elevator=none` boot param correctly sets NVMe to no I/O scheduler (direct hardware multiqueue submission). The SATA disk correctly uses `mq-deadline` which is appropriate for AHCI devices.

7. **RX drops on physical NIC.** 12,901 RX drops on enp0s31f6 (~0.23% of 5.6M packets). Within acceptable range but worth monitoring. If drops increase, investigate NIC ring buffer size or interrupt coalescing.

8. **VIP active on this node.** The control plane VIP (192.168.2.60) is currently assigned to node-01 via enp0s31f6.

9. **No unnecessary extensions.** All 5 extensions serve clear purposes: drbd (storage), gvisor (security runtime), i915 (integrated GPU), intel-ucode (microcode), nvme-cli (storage management). Previous `intel-ice-firmware` extension has been removed (not needed -- this node uses e1000e, not ICE).

10. **Hardware well-matched to role.** The i5-7400T is a 35W TDP part suitable for a compact control-plane node. 4 cores without SMT means predictable scheduling. 32 GB RAM provides ample headroom for etcd, API server, controller manager, scheduler, and DRBD metadata.
