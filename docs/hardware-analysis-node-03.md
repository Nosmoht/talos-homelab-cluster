# Hardware Analysis: node-03

> **Date:** 2026-02-28
> **Talos:** v1.12.4 | **Kubernetes:** v1.35.0
> **Node IP:** 192.168.2.63 | **Role:** control-plane

---

## 1. System Overview

| Property | Value |
|----------|-------|
| Vendor | LENOVO |
| Product | 10MQS7QB00 (ThinkCentre M910q Tiny) |
| Board | 3111 |
| CPU | Intel Core i5-7400T @ 2.40 GHz (Kaby Lake, family 6 model 158 stepping 9) |
| Cores / Threads | 4C / 4T (no Hyper-Threading) |
| Microcode | 0xf8 |
| L3 Cache | 6 MB (shared) |
| Base / Max Freq | 800 MHz / 3000 MHz (turbo enabled, no_turbo=0) |
| Scaling Governor | performance (available: performance, powersave) |
| Energy Perf Pref | performance (available: default, performance, balance_performance, balance_power, power) |
| RAM | 32 GB DDR4 (32,735,344 KB total, ~29.7 GB available at collection time) |
| Swap | None (0 kB) |
| Boot Disk | INTENSO SSD 128 GB (sda, SATA, /dev/disk/by-path/pci-0000:00:17.0-ata-1) |
| Data Disk | Samsung MZVLW256HEHP-000L7 256 GB (nvme0n1, NVMe, serial S35ENX0KB25860) |
| Active NIC | enp0s31f6 (Intel I219-LM, 1 Gbps full-duplex, MTU 1500, MAC 6c:4b:90:69:53:7d) |
| NUMA Nodes | 1 (node0) |
| iGPU | Intel HD Graphics 630 (Kaby Lake, 8086:5912, i915 driver) |
| Container Runtime | containerd 2.1.6 |
| Kernel | 6.18.9-talos |
| OS Image | Talos v1.12.4 |
| Kubelet | v1.35.0 |
| Runtime Handlers | runc, runsc (gVisor), runsc-kvm |

## 2. PCI Device Inventory

| BDF | Vendor:Device | Class | Description |
|-----|---------------|-------|-------------|
| 0000:00:00.0 | 8086:591f | 0600 (Host Bridge) | Xeon E3-1200 v5/v6 / Kaby Lake Host Bridge |
| 0000:00:02.0 | 8086:5912 | 0300 (VGA) | Intel HD Graphics 630 (Kaby Lake GT2) |
| 0000:00:14.0 | 8086:a2af | 0c03 (USB 3.0) | 200 Series/Z370 USB 3.0 xHCI Controller |
| 0000:00:14.2 | 8086:a2b1 | 1180 (Signal Proc) | 200 Series/Z370 Thermal Subsystem |
| 0000:00:16.0 | 8086:a2ba | 0780 (Comms) | 200 Series/Z370 MEI Controller #1 |
| 0000:00:17.0 | 8086:a282 | 0106 (SATA/AHCI) | 200 Series/Z370 SATA Controller (AHCI) |
| 0000:00:1b.0 | 8086:a2eb | 0604 (PCI Bridge) | 200 Series PCIe Root Port (NVMe slot) |
| 0000:00:1f.0 | 8086:a2c8 | 0601 (ISA Bridge) | 200 Series/Z370 LPC Controller/eSPI |
| 0000:00:1f.2 | 8086:a2a1 | 0580 (Memory) | 200 Series/Z370 PMC (Power Management) |
| 0000:00:1f.4 | 8086:a2a3 | 0c05 (SMBus) | 200 Series/Z370 SMBus Controller |
| 0000:00:1f.6 | 8086:15b8 | 0200 (Ethernet) | Intel I219-LM Ethernet Connection |
| 0000:01:00.0 | 144d:a804 | 0108 (NVMe) | Samsung PM961 / 970 EVO NVMe SSD |

All devices are in IOMMU group with DMA domain type "Translated" (strict TLB invalidation).

## 3. USB Device Inventory

| Vendor:Device | Class | Description |
|---------------|-------|-------------|
| 1d6b:0002 | 09 (Hub) | Linux Foundation USB 2.0 Root Hub (bus 1) |
| 1d6b:0003 | 09 (Hub) | Linux Foundation USB 3.0 Root Hub (bus 2) |

No external USB peripherals detected. USB 3.0 SuperSpeed supported via xHCI controller at 0000:00:14.0.

## 4. NFD Feature Highlights

### CPU Features (CPUID)
- **Cryptographic:** AESNI, ADX
- **Vector/SIMD:** AVX, AVX2, FMA3, SSE4.1, SSE4.2
- **Security:** IBPB, STIBP, SPEC_CTRL_SSBD, SRBDS_CTRL, MD_CLEAR, FLUSH_L1D, IA32_ARCH_CAP
- **Virtualization:** VMX (VT-x)
- **State Save:** XSAVE, XSAVEC, XSAVEOPT, XSAVES, XGETBV1, OSXSAVE
- **Other:** MOVBE, MPX (deprecated), SYSCALL, SYSEE, X87, FXSR, FXSROPT, LAHF, CMPXCHG8
- **Note:** RTM_ALWAYS_ABORT = true (TSX removed via microcode update)
- **Hyper-Threading:** false (4 physical cores, no SMT)

### CPU P-State
- **Governor:** performance
- **Status:** active (intel_pstate driver)
- **Turbo:** enabled

### Kernel Config
- NO_HZ: true (tickless idle)
- NO_HZ_IDLE: true

### PCI Features
- pci-0300_8086.present: true (Intel VGA controller detected)

### Storage
- storage-nonrotationaldisk: true (all SSDs)

### System
- OS: Talos v1.12.4
- Kernel: 6.18.9-talos (major=6, minor=18, revision=9)

## 5. CPU Vulnerability Status

| Vulnerability | Status |
|---------------|--------|
| gather_data_sampling | **Mitigation: Microcode** |
| ghostwrite | Not affected |
| indirect_target_selection | Not affected |
| itlb_multihit | KVM: Mitigation: Split huge pages |
| l1tf | Mitigation: PTE Inversion; VMX: conditional cache flushes, SMT disabled |
| mds | Mitigation: Clear CPU buffers; SMT disabled |
| meltdown | **Mitigation: PTI** (via `pti=on` boot param) |
| mmio_stale_data | Mitigation: Clear CPU buffers; SMT disabled |
| old_microcode | Not affected (microcode 0xf8 is current) |
| reg_file_data_sampling | Not affected |
| retbleed | Mitigation: IBRS |
| spec_rstack_overflow | Not affected |
| spec_store_bypass | Mitigation: Speculative Store Bypass disabled via prctl |
| spectre_v1 | Mitigation: usercopy/swapgs barriers and __user pointer sanitization |
| spectre_v2 | Mitigation: IBRS; IBPB: conditional; STIBP: disabled; RSB filling; PBRSB-eIBRS: Not affected; BHI: Not affected |
| srbds | **Mitigation: Microcode** |
| tsa | Not affected |
| tsx_async_abort | Not affected |
| vmscape | Mitigation: IBPB before exit to userspace |

All known vulnerabilities are either mitigated or not applicable. The `mitigations=auto` boot parameter ensures hardware mitigations are applied based on CPU capabilities. Kaby Lake (7th gen) is affected by Meltdown, Spectre, MDS, L1TF, MMIO stale data, GDS, SRBDS, and Retbleed -- all are mitigated. No SMT means several SMT-dependent attacks are inherently not applicable.

## 6. Current Kernel Parameters

### 6.1 Boot Parameters (from /proc/cmdline)

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

| Parameter | Category | Purpose |
|-----------|----------|---------|
| `cpufreq.default_governor=performance` | Performance | Max CPU frequency at all times |
| `intel_idle.max_cstate=0` | Performance | Disable all CPU idle C-states |
| `processor.max_cstate=0` | Performance | Disable ACPI processor C-states |
| `transparent_hugepage=madvise` | Performance | THP only for madvise regions (etcd-safe) |
| `elevator=none` | Performance | No I/O scheduler (NVMe multiqueue passthrough) |
| `nvme_core.default_ps_max_latency_us=0` | Performance | Disable NVMe power saving |
| `nvme_core.io_timeout=4294967295` | Performance | Maximum NVMe I/O timeout (prevents premature aborts) |
| `pcie_aspm=off` | Performance | Disable PCIe Active State Power Management |
| `workqueue.power_efficient=0` | Performance | Disable power-efficient workqueue scheduling |
| `mitigations=auto` | Security | Apply CPU vulnerability mitigations based on hardware |
| `init_on_alloc=1` | Security | Zero memory on allocation (info leak prevention) |
| `init_on_free=1` | Security | Zero memory on free (use-after-free mitigation) |
| `slab_nomerge` | Security | Prevent slab cache merging (heap isolation) |
| `pti=on` | Security | Page Table Isolation (Meltdown mitigation) |
| `selinux=1` | Security | Enable SELinux |
| `module.sig_enforce=1` | Security | Only allow signed kernel modules |
| `page_alloc.shuffle=1` | Security | Randomize page allocator free lists |
| `randomize_kstack_offset=on` | Security | Randomize kernel stack offset per syscall |
| `vsyscall=none` | Security | Disable legacy vsyscall page |
| `intel_iommu=on` | Security | Enable Intel VT-d IOMMU |
| `iommu=force` | Security | Force IOMMU even if not needed by devices |
| `iommu.passthrough=0` | Security | Disable IOMMU passthrough (full DMA isolation) |
| `iommu.strict=1` | Security | Strict IOMMU TLB invalidation (no lazy flushing) |

### 6.3 Configured Sysctls (from patches/common.yaml)

| Sysctl | Configured | Category |
|--------|------------|----------|
| vm.dirty_ratio | 10 | Storage I/O |
| vm.dirty_background_ratio | 5 | Storage I/O |
| vm.dirty_expire_centisecs | 1500 | Storage I/O |
| vm.dirty_writeback_centisecs | 300 | Storage I/O |
| vm.overcommit_memory | 1 | Memory |
| vm.panic_on_oom | 0 | Memory |
| vm.max_map_count | 524288 | Memory |
| vm.min_free_kbytes | 65536 | Memory |
| vm.mmap_rnd_bits | 32 | Security |
| vm.mmap_rnd_compat_bits | 16 | Security |
| net.core.rmem_max | 16777216 | TCP Buffers |
| net.core.wmem_max | 16777216 | TCP Buffers |
| net.core.rmem_default | 1048576 | TCP Buffers |
| net.core.wmem_default | 1048576 | TCP Buffers |
| net.core.optmem_max | 2097152 | TCP Buffers |
| net.ipv4.tcp_rmem | 4096 1048576 16777216 | TCP Buffers |
| net.ipv4.tcp_wmem | 4096 1048576 16777216 | TCP Buffers |
| net.ipv4.tcp_slow_start_after_idle | 0 | TCP Behavior |
| net.ipv4.tcp_tw_reuse | 1 | TCP Behavior |
| net.ipv4.ip_local_port_range | 1024 65535 | TCP Behavior |
| net.ipv4.tcp_fastopen | 3 | TCP Behavior |
| net.ipv4.tcp_mtu_probing | 1 | TCP Behavior |
| net.ipv4.tcp_keepalive_time | 600 | TCP Behavior |
| net.ipv4.tcp_keepalive_intvl | 30 | TCP Behavior |
| net.ipv4.tcp_keepalive_probes | 10 | TCP Behavior |
| net.core.somaxconn | 32768 | Connection Handling |
| net.core.netdev_max_backlog | 16384 | Connection Handling |
| net.ipv4.tcp_max_syn_backlog | 8192 | Connection Handling |
| net.netfilter.nf_conntrack_max | 131072 | Conntrack |
| net.ipv4.neigh.default.gc_thresh1 | 1024 | ARP Cache |
| net.ipv4.neigh.default.gc_thresh2 | 2048 | ARP Cache |
| net.ipv4.neigh.default.gc_thresh3 | 4096 | ARP Cache |
| fs.inotify.max_user_watches | 524288 | Filesystem |
| fs.inotify.max_user_instances | 8192 | Filesystem |
| fs.file-max | 2097152 | Filesystem |
| kernel.pid_max | 4194304 | Process |
| kernel.kexec_load_disabled | 1 | Security |
| kernel.sysrq | 0 | Security |
| kernel.core_pattern | \|/bin/false | Security |
| net.ipv4.conf.all.rp_filter | 0 | Cilium BPF |
| net.ipv4.conf.default.rp_filter | 0 | Cilium BPF |
| net.ipv4.conf.all.log_martians | 0 | Cilium BPF |
| net.ipv4.conf.default.log_martians | 0 | Cilium BPF |
| net.ipv4.icmp_echo_ignore_broadcasts | 1 | ICMP Hardening |
| net.ipv4.icmp_ignore_bogus_error_responses | 1 | ICMP Hardening |
| net.ipv4.tcp_syncookies | 1 | SYN Flood |
| net.ipv4.tcp_rfc1337 | 1 | TIME-WAIT |
| net.ipv4.conf.all.accept_redirects | 0 | MITM Prevention |
| net.ipv4.conf.default.accept_redirects | 0 | MITM Prevention |
| net.ipv4.conf.all.secure_redirects | 0 | MITM Prevention |
| net.ipv4.conf.default.secure_redirects | 0 | MITM Prevention |
| net.ipv6.conf.all.accept_redirects | 0 | MITM Prevention |
| net.ipv6.conf.default.accept_redirects | 0 | MITM Prevention |
| net.ipv4.conf.all.send_redirects | 0 | MITM Prevention |
| net.ipv4.conf.default.send_redirects | 0 | MITM Prevention |
| net.ipv4.conf.all.accept_source_route | 0 | Source Routing |
| net.ipv4.conf.default.accept_source_route | 0 | Source Routing |
| net.ipv6.conf.all.accept_source_route | 0 | Source Routing |
| net.ipv6.conf.default.accept_source_route | 0 | Source Routing |
| net.ipv6.conf.all.accept_ra | 0 | IPv6 RA |
| net.ipv6.conf.default.accept_ra | 0 | IPv6 RA |

### 6.4 Sysctl Live Verification

| Sysctl | Configured | Live Value | Status |
|--------|------------|------------|--------|
| vm.dirty_ratio | 10 | 10 | OK |
| vm.dirty_background_ratio | 5 | 5 | OK |
| vm.dirty_expire_centisecs | 1500 | 1500 | OK |
| vm.dirty_writeback_centisecs | 300 | 300 | OK |
| vm.overcommit_memory | 1 | 1 | OK |
| vm.max_map_count | 524288 | 524288 | OK |
| vm.min_free_kbytes | 65536 | 65536 | OK |
| vm.mmap_rnd_bits | 32 | 32 | OK |
| vm.mmap_rnd_compat_bits | 16 | 16 | OK |
| net.core.rmem_max | 16777216 | 16777216 | OK |
| net.core.wmem_max | 16777216 | 16777216 | OK |
| net.core.somaxconn | 32768 | 32768 | OK |
| net.core.netdev_max_backlog | 16384 | 16384 | OK |
| net.core.bpf_jit_harden | (not configured) | 2 | INFO |
| net.ipv4.tcp_slow_start_after_idle | 0 | 0 | OK |
| net.ipv4.tcp_congestion_control | (not configured) | cubic | INFO |
| net.ipv4.tcp_rmem | 4096 1048576 16777216 | 4096 1048576 16777216 | OK |
| net.ipv4.tcp_wmem | 4096 1048576 16777216 | 4096 1048576 16777216 | OK |
| net.ipv4.conf.all.rp_filter | 0 | 0 | OK |
| kernel.kexec_load_disabled | 1 | 1 | OK |
| kernel.pid_max | 4194304 | 4194304 | OK |
| kernel.sysrq | 0 | 0 | OK |
| fs.inotify.max_user_watches | 524288 | 524288 | OK |
| net.netfilter.nf_conntrack_max | 131072 | 131072 | OK |

All configured sysctls are verified active on the live node. No discrepancies detected.

**Notable unconfigured values:**
- `net.core.bpf_jit_harden = 2` -- BPF JIT hardening is enabled (set by Talos default or Cilium), which is good for security.
- `net.ipv4.tcp_congestion_control = cubic` -- Using kernel default; BBR could be considered for DRBD replication performance but cubic is well-suited for LAN.

### 6.5 Boot Parameter vs Live State Verification

| Boot Parameter | Expected Effect | Live State | Status |
|----------------|-----------------|------------|--------|
| cpufreq.default_governor=performance | Governor = performance | performance | OK |
| intel_idle.max_cstate=0 | Max C-state disabled | C0 only (max freq sustained) | OK |
| transparent_hugepage=madvise | THP = madvise | always [madvise] never | OK |
| elevator=none | NVMe scheduler = none | nvme0n1: [none] | OK |
| intel_iommu=on | IOMMU enabled | DMAR: IOMMU enabled, VT-d active | OK |
| iommu.strict=1 | Strict TLB invalidation | DMA domain TLB: strict mode | OK |
| pti=on | Page Table Isolation | Meltdown: Mitigation: PTI | OK |

**Note:** The `sda` (SATA boot disk) shows scheduler `none [mq-deadline] kyber bfq` -- mq-deadline is active, not `none`. The `elevator=none` boot parameter only affects device-mapper and NVMe; SATA disks fall back to mq-deadline by default, which is appropriate for the SATA boot disk.

## 7. Storage Profile

### Physical Disks

| Device | Model | Transport | Size | Rotational | Scheduler | Queue Depth | Serial |
|--------|-------|-----------|------|------------|-----------|-------------|--------|
| sda | INTENSO SSD | SATA (AHCI) | 128 GB (250,069,680 sectors) | No (SSD) | mq-deadline | 64 | (via WWID t10.ATA INTENSO SSD 1642312010002018) |
| nvme0n1 | Samsung MZVLW256HEHP-000L7 | NVMe PCIe | 256 GB (500,118,192 sectors) | No (SSD) | none | 1023 | S35ENX0KB25860 |

### DRBD / LINSTOR Volumes

| Device | Purpose |
|--------|---------|
| drbd1000 | LINSTOR replicated volume |
| drbd1001 | LINSTOR replicated volume |
| drbd1002 | LINSTOR replicated volume |
| drbd1003 | LINSTOR replicated volume (connected to node-gpu-01) |
| drbd1004 | LINSTOR replicated volume (connected to node-gpu-01) |
| dm-0 through dm-4 | Device-mapper layers for DRBD/LINSTOR |

### Storage Notes
- Boot disk (`sda`) is installed at stable path `/dev/disk/by-path/pci-0000:00:17.0-ata-1`
- Samsung PM961 NVMe (nvme0n1) is the LINSTOR storage pool backend
- NVMe power saving disabled via boot parameter (`nvme_core.default_ps_max_latency_us=0`)
- NVMe I/O timeout set to maximum (`nvme_core.io_timeout=4294967295`)
- All block devices report rotational=0 (non-rotational / SSD)
- 5 DRBD resources active, all with established replication connections

## 8. Network Profile

### Physical Interface

| Property | Value |
|----------|-------|
| Interface | enp0s31f6 |
| Driver | e1000e (Intel PRO/1000) |
| PCI BDF | 0000:00:1f.6 |
| Device ID | 8086:15b8 (Intel I219-LM) |
| Link Speed | 1000 Mbps (1 Gbps) |
| Duplex | Full |
| MTU | 1500 |
| MAC Address | 6c:4b:90:69:53:7d |
| Operstate | up |
| IP Address | 192.168.2.63/24 |
| Gateway | 192.168.2.1 |
| VIP | 192.168.2.60 (control-plane shared VIP) |

### Network Statistics (at collection time)

| Interface | RX Bytes | RX Packets | RX Drops | TX Bytes | TX Packets | TX Drops |
|-----------|----------|------------|----------|----------|------------|----------|
| enp0s31f6 | 3.73 GB | 3,059,430 | 5,377 | 736 MB | 1,246,863 | 4 |
| cilium_vxlan | 3.21 GB | 444,986 | 0 | 457 MB | 437,742 | 0 |
| lo | 372 MB | 678,154 | 0 | 372 MB | 678,154 | 0 |

### Network Observations
- **RX drops on enp0s31f6: 5,377** -- This is a non-trivial number of drops on the physical NIC. At ~3M total RX packets this represents a 0.18% drop rate. This could be caused by interrupt coalescing under high DRBD replication bursts or by ring buffer exhaustion. Worth monitoring but not critical.
- **TX drops on enp0s31f6: 4** -- Negligible.
- Cilium VXLAN overlay is healthy with zero drops.
- Interrupt throttling set to dynamic conservative mode (e1000e default).

### Overlay Interfaces
- `cilium_net` / `cilium_host` -- Cilium node-local communication
- `cilium_vxlan` -- Cilium VXLAN tunnel overlay (high traffic volume = cross-node pod traffic)
- `lxc*` -- Per-pod veth interfaces managed by Cilium
- 7 active pod veth interfaces (lxc_health + 6 workload pods)

## 9. GPU Profile

This node has an integrated Intel HD Graphics 630 (Kaby Lake GT2) at PCI 0000:00:02.0.

| Property | Value |
|----------|-------|
| Device | Intel HD Graphics 630 |
| PCI ID | 8086:5912 |
| Driver | i915 (v1.6.0) |
| DMC Firmware | i915/kbl_dmc_ver1_04.bin (v1.4) |
| VT-d | Active for gfx access |
| Transparent Hugepages | In use by i915 |
| Display | No display connected (eDP disabled, no CRTC found) |

The `siderolabs/i915` extension is installed, providing the i915 kernel module and firmware. This iGPU is not used for compute workloads on this control-plane node; the extension is present for potential hardware transcoding or SR-IOV use cases.

## 10. Installed Extensions

| Extension | Version | Purpose |
|-----------|---------|---------|
| drbd | 9.2.16-v1.12.4 | DRBD kernel module for LINSTOR/Piraeus CSI storage replication |
| gvisor | 20260202.0 | gVisor (runsc) container sandbox runtime |
| i915 | 20260110-v1.12.4 | Intel GPU i915 kernel module + firmware |
| intel-ucode | 20260210 | Intel CPU microcode updates (security + stability) |
| nvme-cli | v2.14 | NVMe management CLI tools |
| modules.dep | 6.18.9-talos | Kernel module dependency resolution |

**Schematic ID:** `24f8c9280e59a44d8d9bc457cb80d5b4182313730710e6e41b413c9ededcb18a`

## 11. Observations

### Hardware Summary
1. **Lenovo ThinkCentre M910q** with Intel Core i5-7400T (Kaby Lake, 4C/4T) and 32 GB RAM. This is one of the standard control-plane nodes identical in hardware to node-01 and node-02.
2. **Single NIC** (Intel I219-LM, 1 Gbps) -- correctly pinned via `hardwareAddr: 6c:4b:90:69:53:7d` in the node config to avoid multi-NIC ambiguity.
3. **Dual storage:** SATA SSD for Talos boot (128 GB Intenso) + NVMe SSD for LINSTOR data pool (256 GB Samsung PM961).
4. **No discrete GPU.** The integrated HD 630 is managed by the i915 extension but serves no compute function.

### Configuration Health
5. **All sysctls verified:** Every configured sysctl in `patches/common.yaml` matches the live node values. No drift detected.
6. **All boot parameters active:** CPU governor, C-state limits, THP mode, I/O scheduler, IOMMU, and security hardening are all confirmed operational on the live node.
7. **IOMMU fully operational:** Intel VT-d is active with 2 DMAR hardware units, strict TLB invalidation, queued invalidation, and IRQ remapping in x2apic mode. All 12 PCI devices are assigned to IOMMU groups 0-8.
8. **CPU mitigations comprehensive:** All applicable Kaby Lake vulnerabilities (Meltdown, Spectre v1/v2, MDS, L1TF, MMIO stale data, GDS, SRBDS, Retbleed, SSB, vmscape) have active mitigations. Microcode 0xf8 is current (old_microcode: Not affected).

### Potential Concerns
9. **NIC RX drops (5,377):** While the drop rate is low (0.18%), this should be monitored over time. On a control-plane node handling etcd and API server traffic, even occasional drops can cause latency spikes. Consider checking ring buffer size (`ethtool -g enp0s31f6`) and interrupt coalescing settings.
10. **SATA boot disk scheduler mismatch:** The `elevator=none` boot parameter does not override the SATA disk's default scheduler. `sda` uses mq-deadline, which is appropriate for SATA and is not a concern.
11. **DRBD replication active:** 5 DRBD resources are connected and replicating, including 2 resources for node-gpu-01. DRBD traffic shares the single 1 Gbps link with etcd, API server, and pod traffic.
12. **No BBR congestion control:** TCP uses `cubic` (default). For the LAN-only DRBD replication and etcd traffic pattern, cubic is adequate. BBR would primarily benefit high-bandwidth WAN links.
13. **BPF JIT harden = 2:** Enabled by default (Talos or Cilium), which adds overhead to BPF JIT compilation but prevents BPF JIT spraying attacks. Appropriate for a security-focused cluster.
