# Hardware Analysis: node-04

> **Date:** 2026-02-28
> **Talos:** v1.12.4 | **Kubernetes:** v1.35.0 | **Kernel:** 6.18.9-talos
> **Node IP:** 192.168.2.64 | **Role:** worker

---

## 1. System Overview

| Property | Value |
|----------|-------|
| Vendor | LENOVO |
| Product | 10MQS1590A (ThinkCentre M910q Tiny) |
| Board | 3111 |
| BIOS | M1AKT59A (2023-10-27) |
| CPU | Intel Core i3-6100T @ 3.20 GHz (Skylake, family 6 model 94 stepping 3) |
| Cores/Threads | 2C/4T (Hyper-Threading enabled) |
| Microcode | 0xf0 |
| L3 Cache | 3 MB |
| RAM | 16 GB DDR4 (16,245,212 KB total, 15,749,596 Ki allocatable) |
| Boot Disk | INTENSO SSD 128 GB (sda, SATA/AHCI) |
| Data Disk | SanDisk SSD Plus 250GB A3N (nvme0n1, NVMe PCIe) |
| Active NIC | enp0s31f6 (Intel I219-V, 1 Gbps, MAC 6c:4b:90:51:99:c7) |
| NUMA Nodes | 1 (node0) |
| GPU | Intel HD Graphics 530 (integrated, 8086:1912) |
| Container Runtime | containerd 2.1.6 |
| Runtime Handlers | runc, runsc (gVisor), runsc-kvm |

---

## 2. PCI Device Inventory

| BDF | Vendor:Device | Class | Description |
|-----|---------------|-------|-------------|
| 00:00.0 | 8086:190f | 0600 (Host Bridge) | Xeon E3-1200 v5/6th Gen Core DRAM Controller |
| 00:02.0 | 8086:1912 | 0300 (VGA) | Intel HD Graphics 530 (Skylake GT2) |
| 00:14.0 | 8086:a2af | 0c03 (USB) | 200 Series/Z370 USB 3.0 xHCI Controller |
| 00:14.2 | 8086:a2b1 | 1180 (Signal Processing) | 200 Series/Z370 Thermal Subsystem |
| 00:16.0 | 8086:a2ba | 0780 (Communication) | 200 Series/Z370 CSME HECI #1 (Intel ME) |
| 00:17.0 | 8086:a282 | 0106 (SATA/AHCI) | 200 Series PCH SATA Controller (AHCI mode) |
| 00:1b.0 | 8086:a2eb | 0604 (PCI Bridge) | 200 Series PCH PCI Express Root Port |
| 00:1f.0 | 8086:a2c8 | 0601 (ISA Bridge) | 200 Series PCH LPC Controller/eSPI |
| 00:1f.2 | 8086:a2a1 | 0580 (Memory) | 200 Series/Z370 PMC (Power Management Controller) |
| 00:1f.4 | 8086:a2a3 | 0c05 (SMBus) | 200 Series/Z370 SMBus Controller |
| 00:1f.6 | 8086:15b8 | 0200 (Ethernet) | Intel I219-V Gigabit Ethernet (e1000e driver) |
| 01:00.0 | 15b7:5019 | 0108 (NVMe) | SanDisk SSD Plus 250GB A3N (NVMe) |

### IOMMU Groups

IOMMU is active (Intel VT-d, strict TLB invalidation, translated domain mode). All PCI devices are assigned to 9 IOMMU groups:

| Group | Devices |
|-------|---------|
| 0 | Intel HD Graphics 530 (00:02.0) |
| 1 | Host Bridge (00:00.0) |
| 2 | USB 3.0 + Thermal (00:14.0, 00:14.2) |
| 3 | Intel ME (00:16.0) |
| 4 | SATA Controller (00:17.0) |
| 5 | PCI Express Root Port (00:1b.0) |
| 6 | LPC + PMC + SMBus (00:1f.0, 00:1f.2, 00:1f.4) |
| 7 | Ethernet I219-V (00:1f.6) |
| 8 | NVMe SSD (01:00.0) |

---

## 3. USB Device Inventory

| Bus | Device | Description |
|-----|--------|-------------|
| usb1 | Root Hub | xHCI Host Controller (kernel 6.18.9-talos) |
| usb2 | Root Hub | xHCI Host Controller (kernel 6.18.9-talos) |

No external USB devices attached. Clean hardware surface.

---

## 4. NFD Feature Highlights

Source: Node Feature Discovery v0.18.3

### CPU

- **Architecture:** amd64, Intel Skylake (family 6, model 94)
- **Instruction Sets:** SSE4.1, SSE4.2, AVX, AVX2, FMA3, AES-NI, ADX, BMI1, BMI2, RDSEED, MPX
- **Virtualization:** VMX (VT-x) supported
- **Multithreading:** HT enabled (2 physical cores, 4 threads)
- **P-State:** Active, governor = performance, turbo = true
- **C-States:** Disabled via boot params (intel_idle.max_cstate=0, processor.max_cstate=0)
- **Security Features:** IBPB, STIBP, SSBD, FLUSH_L1D, MD_CLEAR, SRBDS_CTRL, IA32_ARCH_CAP

### Storage

- Non-rotational disk present (SSD/NVMe)

### Kernel

- Version: 6.18.9-talos
- Config: NO_HZ=y, NO_HZ_IDLE=y (tickless idle)

### PCI Features

- `pci-0300_8086.present: true` -- Intel integrated GPU detected

### NFD Anomaly

NFD reports `cpu-security.sev.enabled`, `sev.es.enabled`, and `sev.snp.enabled` as true. These are false positives -- AMD SEV is not supported on Intel Skylake hardware. This is a known NFD detection issue and does not affect functionality.

---

## 5. CPU Vulnerability Status

| Vulnerability | Status |
|---------------|--------|
| gather_data_sampling | **Vulnerable: No microcode** |
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
| tsx_async_abort | Not affected |
| vmscape | Mitigation: IBPB before exit to userspace |

**GDS (Gather Data Sampling) is VULNERABLE** -- the intel-ucode extension is installed (v20260210) but Intel has not released a GDS microcode fix for the Skylake i3-6100T (model 94, stepping 3). This is a data-leaking side-channel vulnerability (CVE-2022-40982) that primarily affects SGX enclaves. Risk is low in a non-SGX Kubernetes worker context. Full mitigation would require `nosmt` boot param, reducing threads from 4 to 2, which is impractical on this hardware.

Several mitigations show "SMT vulnerable" because Hyper-Threading is enabled. This is expected on 2C/4T hardware where disabling SMT is not practical.

---

## 6. Current Kernel Parameters

### 6.1 Boot Parameters (/proc/cmdline)

All boot parameters from the factory schematic are confirmed active:

```
talos.platform=metal console=tty0 init_on_alloc=1 slab_nomerge pti=on
consoleblank=0 nvme_core.io_timeout=4294967295 printk.devkmsg=on selinux=1
module.sig_enforce=1 cpufreq.default_governor=performance intel_idle.max_cstate=0
processor.max_cstate=0 transparent_hugepage=madvise elevator=none mitigations=auto
init_on_free=1 page_alloc.shuffle=1 randomize_kstack_offset=on vsyscall=none
nvme_core.default_ps_max_latency_us=0 pcie_aspm=off workqueue.power_efficient=0
intel_iommu=on iommu=force iommu.passthrough=0 iommu.strict=1
```

### 6.2 Boot Parameter Breakdown

**Performance (6 params):**

| Parameter | Purpose | Verified |
|-----------|---------|----------|
| cpufreq.default_governor=performance | Force performance CPU governor | Yes (scaling_governor=performance) |
| intel_idle.max_cstate=0 | Disable Intel idle C-states | Yes |
| processor.max_cstate=0 | Disable ACPI processor C-states | Yes |
| transparent_hugepage=madvise | THP only via madvise() | Yes (confirmed: `always [madvise] never`) |
| elevator=none | No I/O scheduler (NVMe multiqueue) | Yes (NVMe scheduler=none) |
| nvme_core.default_ps_max_latency_us=0 | Disable NVMe power states | Yes |

**Security (8 params):**

| Parameter | Purpose |
|-----------|---------|
| init_on_alloc=1 | Zero memory on allocation |
| init_on_free=1 | Zero memory on free |
| slab_nomerge | Prevent SLAB merging (heap hardening) |
| pti=on | Page table isolation (Meltdown mitigation) |
| mitigations=auto | Enable all CPU vulnerability mitigations |
| page_alloc.shuffle=1 | Randomize page allocator freelists |
| randomize_kstack_offset=on | Randomize kernel stack offsets |
| vsyscall=none | Disable vsyscall page (ASLR hardening) |

**Power Management (3 params):**

| Parameter | Purpose |
|-----------|---------|
| pcie_aspm=off | Disable PCIe Active State Power Management |
| workqueue.power_efficient=0 | Disable power-efficient workqueues |
| nvme_core.default_ps_max_latency_us=0 | Disable NVMe power saving |

**IOMMU (4 params):**

| Parameter | Purpose |
|-----------|---------|
| intel_iommu=on | Enable Intel VT-d IOMMU |
| iommu=force | Force IOMMU for all devices |
| iommu.passthrough=0 | Disable IOMMU passthrough (enforce DMA translation) |
| iommu.strict=1 | Strict DMA TLB invalidation |

**System (5 params, Talos defaults + schematic):**

| Parameter | Purpose |
|-----------|---------|
| talos.platform=metal | Bare-metal platform |
| console=tty0 | Console output |
| consoleblank=0 | Disable console blanking |
| printk.devkmsg=on | Enable device kernel messages |
| nvme_core.io_timeout=4294967295 | Infinite NVMe I/O timeout |
| selinux=1 | Enable SELinux |
| module.sig_enforce=1 | Enforce kernel module signatures |

### 6.3 Gap Analysis

All 16 schematic `extraKernelArgs` are present in `/proc/cmdline`. The node has been upgraded to the factory image with the current schematic. No boot parameter gaps detected.

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
| net.core.bpf_jit_harden | -- | 2 | N/A (Talos KSPP default, full hardening) |
| net.ipv4.tcp_slow_start_after_idle | 0 | 0 | Yes |
| net.ipv4.tcp_congestion_control | -- | cubic | N/A (kernel default, appropriate for 1G LAN) |
| net.ipv4.conf.all.rp_filter | 0 | 0 | Yes |
| kernel.kexec_load_disabled | 1 | 1 | Yes |
| kernel.pid_max | 4194304 | 4194304 | Yes |
| fs.inotify.max_user_watches | 524288 | 524288 | Yes |
| net.netfilter.nf_conntrack_max | 131072 | 131072 | Yes |

**All configured sysctls match their live values.** No sysctl gaps detected.

---

## 7. Storage Profile

| Device | Model | Serial | Type | Size | Scheduler | Rotational | Role |
|--------|-------|--------|------|------|-----------|:----------:|------|
| sda | INTENSO SSD | 1642312001001896 | SATA SSD | 128 GB | mq-deadline | No | Talos OS / EPHEMERAL |
| nvme0n1 | SanDisk SSD Plus 250GB A3N | 23495R801097 | NVMe | 250 GB | none | No | LINSTOR/DRBD storage pool |
| drbd1001 | (virtual) | -- | DRBD | ~5 GB | -- | -- | LINSTOR replicated volume |

### Storage Notes

- **Install disk path:** `/dev/disk/by-path/pci-0000:00:17.0-ata-1` (SATA INTENSO SSD)
- **NVMe firmware:** 236050WD
- **NVMe scheduler:** `none` -- correct for NVMe multiqueue passthrough; matches `elevator=none` boot parameter
- **SATA scheduler:** `mq-deadline` -- appropriate default for SATA AHCI; `elevator=none` only affects queues that support it natively
- **NVMe power saving:** Disabled (`nvme_core.default_ps_max_latency_us=0`)
- **NVMe I/O timeout:** Max value (`nvme_core.io_timeout=4294967295`) to prevent timeout-triggered resets under high I/O
- **PCIe ASPM:** Disabled (`pcie_aspm=off`) to avoid NVMe latency spikes
- **DRBD:** 1 active replicated volume (drbd1001, ~5 GB) using TCP transport

### CPU Frequency

| Property | Value |
|----------|-------|
| Governor | performance |
| Available Governors | performance, powersave |
| Min Frequency | 800 MHz |
| Max Frequency | 3200 MHz |
| Current Frequency | ~2444 MHz (sample, varies with load) |
| Turbo Boost | Not supported (i3-6100T has no Turbo; `no_turbo=0` sysfs exists but is inert) |
| C-States | Disabled (intel_idle.max_cstate=0, processor.max_cstate=0) |

---

## 8. Network Profile

| Interface | Type | Speed | Status | Role |
|-----------|------|-------|--------|------|
| enp0s31f6 | Intel I219-V (8086:15b8, e1000e) | 1 Gbps Full Duplex | Up | Primary NIC |
| cilium_vxlan | VXLAN tunnel | -- | Up | Cilium overlay |
| cilium_host/cilium_net | Virtual | -- | Up | Cilium host networking |
| lo | Loopback | -- | Up | Loopback |

### NIC Details

| Property | Value |
|----------|-------|
| Driver | e1000e (Intel PRO/1000 Network Driver) |
| PCI Address | 00:1f.6 |
| MAC Address | 6c:4b:90:51:99:c7 |
| Speed | 1000 Mbps Full Duplex |
| Flow Control | None |
| MTU | 1500 |
| PCIe Link | 2.5 GT/s, Width x1 |
| Interrupt Throttling | Dynamic conservative mode |

### Traffic Statistics (since last boot)

| Interface | RX Bytes | RX Packets | RX Drops | TX Bytes | TX Packets | TX Drops |
|-----------|----------|------------|----------|----------|------------|----------|
| enp0s31f6 | 299 MB | 315,337 | 3,960 | 89 MB | 203,975 | 2 |
| cilium_vxlan | 19.8 MB | 33,299 | 0 | 15.4 MB | 30,922 | 0 |
| lo | 16.7 MB | 36,129 | 0 | 16.7 MB | 36,129 | 0 |

### Network Notes

- **IP configuration:** Static 192.168.2.64/24, gateway 192.168.2.1, DNS 192.168.2.1
- **No VIP:** Worker node; VIP (192.168.2.60) is on control plane nodes only
- **RX drops (3,960):** Present on enp0s31f6. On a 1 Gbps e1000e NIC, drops are typically caused by ring buffer overflows during burst traffic. The configured `net.core.netdev_max_backlog=16384` helps mitigate but some drops remain under load. Within acceptable range for a worker node.
- **Cilium overlay:** VXLAN encapsulation active, zero drops on tunnel interface

---

## 9. GPU Profile

| Property | Value |
|----------|-------|
| GPU | Intel HD Graphics 530 (Skylake GT2, integrated) |
| PCI BDF | 00:02.0 |
| Vendor:Device | 8086:1912 |
| Class | 0300 (VGA compatible controller) |
| i915 Extension | Loaded (v20260110-v1.12.4) |
| DRM | Initialized i915 1.6.0 for 0000:00:02.0 |
| DMC Firmware | i915/skl_dmc_ver1_27.bin (v1.27) |
| VT-d | Active for gfx access |
| THP | Using Transparent Hugepages (i915 internal) |
| Display | No display connected (eDP disabled, no CRTC found) |
| IOMMU Group | 0 |

No discrete GPU present. The i915 extension provides the Intel GPU kernel driver. The integrated GPU is headless and could be used for Intel Quick Sync Video (QSV) hardware transcoding if workloads require it. Skylake uses `skl_dmc` firmware (vs `kbl_dmc` on Kaby Lake nodes).

---

## 10. Installed Extensions

| Extension | Version | Purpose |
|-----------|---------|---------|
| drbd | 9.2.16-v1.12.4 | DRBD kernel module for LINSTOR/Piraeus storage replication |
| gvisor | 20260202.0 | gVisor userspace container runtime (runsc, runsc-kvm handlers) |
| i915 | 20260110-v1.12.4 | Intel integrated GPU driver (HD Graphics 530) |
| intel-ucode | 20260210 | Intel CPU microcode updates |
| nvme-cli | v2.14 | NVMe management utilities |

**Schematic ID:** `24f8c9280e59a44d8d9bc457cb80d5b4182313730710e6e41b413c9ededcb18a`

### Loaded Kernel Modules (from dmesg)

`drbd`, `drbd_transport_tcp`, `i915`, `e1000e`, `nvme`, `ahci`, `libahci`, `iTCO_wdt`, `iTCO_vendor_support`, `intel_rapl_msr`, `intel_rapl_common`, `i2c_algo_bit`, `drm_buddy`, `drm_display_helper`, `cec`, `ttm`, `i2c_i801`, `i2c_smbus`, `intel_pmc_core`, `pmt_telemetry`, `pmt_discovery`, `pmt_class`, `intel_pmc_ssram_telemetry`, `intel_vsec`, `watchdog`, `loop`

---

## 11. Observations

1. **All boot parameters applied.** All 16 schematic `extraKernelArgs` plus sd-boot bootloader are confirmed active in `/proc/cmdline`. The node has been successfully upgraded to the factory image with the current schematic. No `make -C talos upgrade-node-04` is pending.

2. **All sysctls verified.** Every sysctl from `patches/common.yaml` matches its live runtime value. No configuration drift detected.

3. **GDS vulnerability not mitigated.** `gather_data_sampling: Vulnerable: No microcode` -- Intel has not released a GDS microcode fix for Skylake i3-6100T (stepping 3). Risk is low in a non-SGX Kubernetes worker context. Full mitigation would require disabling SMT (`nosmt`), halving threads from 4 to 2, which is impractical.

4. **SMT-dependent vulnerability exposure.** l1tf, mds, and mmio_stale_data all show "SMT vulnerable" because Hyper-Threading is enabled on this 2-core CPU. Disabling SMT is not practical given the already limited thread count.

5. **CPU governor correctly set to performance.** The `cpufreq.default_governor=performance` boot parameter is active and confirmed via sysfs. C-states are disabled. The i3-6100T runs at a fixed 3.20 GHz (no Turbo Boost support).

6. **Hardware is appropriate for worker role.** The i3-6100T (2C/4T, 3.20 GHz) with 16 GB RAM is adequate for general Kubernetes worker duties. Consistent clock speed (no Turbo) provides predictable performance.

7. **Dual storage topology is correct.** SATA SSD (128 GB) for Talos OS, NVMe SSD (250 GB) for LINSTOR/DRBD. I/O schedulers are appropriate: `none` for NVMe, `mq-deadline` for SATA.

8. **DRBD active.** One DRBD replicated volume (drbd1001, ~5 GB) is present on this node.

9. **Minor NIC RX drops.** 3,960 RX drops on enp0s31f6 since boot. Typical for e1000e under burst traffic on 1 Gbps. Not actionable without ring buffer tuning (not exposed by Talos).

10. **Extensions are appropriate.** All 5 extensions match the hardware profile: drbd (storage), gvisor (sandbox runtime), i915 (Intel GPU), intel-ucode (microcode), nvme-cli (NVMe management). No missing or unnecessary extensions.

11. **NFD SEV false positive.** Node Feature Discovery incorrectly reports AMD SEV/SEV-ES/SEV-SNP as enabled on this Intel Skylake system. Cosmetic issue only.

12. **Clean hardware surface.** No external USB devices, no discrete GPU, single NIC. Minimal attack surface and straightforward management.

13. **Memory utilization is low.** 16 GB total with ~12.7 GB free and ~14.2 GB available (~78% free). The node has significant headroom for additional workloads.
