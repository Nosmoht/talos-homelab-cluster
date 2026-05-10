# Kernel-Tuning: Performance & Security

> **Scope:** node-01 bis node-06 (Lenovo ThinkCentre M910q + M920q)
> **Erstellt:** 2026-02-28
> **Talos:** v1.12.4 | **Kubernetes:** v1.35.0 | **Cilium:** v1.19.0 (eBPF kube-proxy replacement)
> **Nicht abgedeckt:** node-gpu-01 (andere Hardware mit NVIDIA GPU)

---

## Inhaltsverzeichnis

1. [Hardware-Profil](#1-hardware-profil)
2. [Patch-Platzierung](#2-patch-platzierung)
   - 2.1 [Schematic-Strategie: Shared vs. Per-Node](#schematic-strategie-shared-vs-per-node)
3. [Talos-Defaults (bereits gesetzt)](#3-talos-defaults-bereits-gesetzt)
4. [Performance-Parameter](#4-performance-parameter)
   - 4.1 [Storage I/O](#41-storage-io)
   - 4.2 [TCP-Buffer (DRBD-Replikation)](#42-tcp-buffer-drbd-replikation)
   - 4.3 [TCP-Verhalten](#43-tcp-verhalten)
   - 4.4 [Connection Handling & Backlog](#44-connection-handling--backlog)
   - 4.5 [Conntrack](#45-conntrack)
   - 4.6 [ARP-Cache](#46-arp-cache)
   - 4.7 [Memory Management](#47-memory-management)
   - 4.8 [Filesystem & Process Limits](#48-filesystem--process-limits)
   - 4.9 [Boot-Parameter: Performance](#49-boot-parameter-performance)
5. [Security-Parameter](#5-security-parameter)
   - 5.1 [Netzwerk-Hardening](#51-netzwerk-hardening)
   - 5.2 [Kernel-Hardening](#52-kernel-hardening)
   - 5.3 [Memory Protection](#53-memory-protection)
   - 5.4 [Boot-Parameter: Security](#54-boot-parameter-security)
   - 5.5 [CPU-Vulnerability-Matrix (Skylake / Coffee Lake)](#55-cpu-vulnerability-matrix-skylake--coffee-lake)
6. [Nicht empfohlene Parameter](#6-nicht-empfohlene-parameter)
7. [Hinweis: bpf_jit_harden auf GPU-Worker](#7-hinweis-bpf_jit_harden-auf-gpu-worker)
8. [Offene Punkte](#8-offene-punkte)
9. [Verifikation](#9-verifikation)
10. [Quellen](#10-quellen)

---

## 1. Hardware-Profile

Im Cluster gibt es zwei Hardware-Generationen. Beide basieren auf der gleichen Intel
Skylake-Mikroarchitektur (Coffee Lake ist ein Skylake-Refresh mit mehr Cores auf 14nm++),
weshalb identische Kernel-Parameter anwendbar sind.

### ThinkCentre M910q (node-01 bis node-05)

| Eigenschaft | Wert |
|-------------|------|
| Modell | Lenovo ThinkCentre M910q Tiny (DMI: `10MQS7QB00`) |
| CPU | Intel 7th Gen Kaby Lake, z.B. i5-7400T (4C/4T) oder i7-7700T (4C/8T) |
| Chipset | Intel B250 / Q270 (200-series) |
| RAM | DDR4-2400, non-ECC, 2x SODIMM, max 32GB |
| Boot-Disk | SATA SSD (`/dev/sda`) |
| Daten-Disk | NVMe (`/dev/nvme0n1`), M.2 2242, **PCIe 3.0 x2** (~2 GB/s max) |
| Netzwerk | Intel I219-LM (e1000e, PCI 8086:15b8), 1 GbE, vPro/AMT-fähig |
| Nodes | node-01, node-02, node-03 (Control Plane), node-04, node-05 (Worker) |

> **Modell-Identifikation:** DMI-Daten von node-01 zeigen `10MQS7QB00` (ThinkCentre
> **M910q**, Business/vPro-Linie) mit Intel I219-**LM** (8086:15b8). Die frühere
> Bezeichnung als "M910q" war falsch — M910q wäre die Budget-Variante mit I219-V
> (8086:15b7). M910q und M910q nutzen die gleiche Kaby Lake-Plattform mit identischem
> Kernel-Tuning. Verifizierung der anderen Nodes:
> `talosctl -n <ip> -e <ip> read /sys/devices/virtual/dmi/id/product_name`

### ThinkCentre M920q (node-06)

| Eigenschaft | Wert |
|-------------|------|
| Modell | Lenovo ThinkCentre M920q Tiny (10MV001LGE) |
| CPU | Intel Core i7-7700T @ 2.90GHz (Kaby Lake, 4C/8T, Hyper-Threading) |
| Chipset | Intel Q270 (200-series, LPC 0xa2c6) |
| RAM | DDR4, non-ECC, **16 GB** (niedrigster RAM im Cluster) |
| Boot-Disk | SATA SSD (`/dev/sda`) |
| Daten-Disk | Toshiba XG5 256GB NVMe (`/dev/nvme0n1`, 1179:0115) |
| Netzwerk | Intel I219-V (e1000e, 8086:15b7), 1 GbE |
| Nodes | node-06 (Worker) |

### Hardware-Vergleich

| Attribut | M910q (node-01..05) | M920q (node-06) | Auswirkung auf Kernel-Tuning |
|----------|---------------------|-----------------|------------------------------|
| Mikroarchitektur | Kaby Lake (Skylake-Refresh, 14nm+) | Kaby Lake (identisch, trotz M920q-Gehäuse) | **Identisch** — gleiche Vulnerability-Surface |
| CPU-Stepping | Stepping 9 (B0) für 7th Gen | Stepping 9 (B0) — gleiche Generation | Gleiche Software-Mitigations nötig |
| NVMe-Anbindung | PCIe 3.0 x2 | PCIe 3.0 (Toshiba XG5) | Gleiche Config |
| NIC-Driver | e1000e (I219-LM, 8086:15b8) | e1000e (I219-V, 8086:15b7) | Gleicher Treiber, Consumer-Variante (V statt LM) |
| VT-d/IOMMU | B250/Q270 — VT-d aktiv auf allen Nodes bestätigt (DMA-FQ Mode) | Q270 (LPC 0xa2c6) — VT-d aktiv | Beide Chipsets exponieren VT-d |
| Cores/Threads | 4C/4T (i5-7400T/7500T) oder 2C/4T (i3-6100T) | 4C/8T (i7-7700T, HT aktiv) | Mehr Threads, gleiche Config |
| Install-Image | `talos-factory-schematic.yaml` | `talos-factory-schematic.yaml` (gleiches Schematic) | **Kompatibel** — alle Extensions + Boot-Params funktionieren auf beiden |
| Boot/Data-Disk | `/dev/sda` + `/dev/nvme0n1` | `/dev/sda` + `/dev/nvme0n1` | Gleiche Device-Pfade |

**Fazit:** Alle Standard-Nodes (M910q + M920q) nutzen Kaby Lake CPUs, das **gleiche Factory
Schematic**, die **gleichen Sysctls** in `common.yaml`, und die **gleichen Boot-Parameter**.
Es gibt keine Konfigurationsunterschiede. Siehe [Schematic-Strategie](#schematic-strategie-shared-vs-per-node)
für die detaillierte Begründung.

### Nicht abgedeckt durch dieses Dokument

- **node-gpu-01** (GPU Worker) — andere Hardware mit NVIDIA GPU, eigenes Schematic
  (`talos-factory-schematic-gpu.yaml`)

### Bekannte Hardware-Probleme

**M910q (Kaby Lake):** [Dokumentiertes Hyper-Threading-Problem](https://pcsupport.lenovo.com/solutions/ht504407)
— bei ungepatchtem Microcode kann unvorhersehbares Systemverhalten auftreten. Die Extension
`siderolabs/intel-ucode` ist bereits im Factory Schematic enthalten und liefert aktuelle
Microcode-Patches (node-01: Microcode 0xf8).

**M920q (Coffee Lake):** [Dokumentiertes BIOS-Flash-Hang-Problem](https://pcsupport.lenovo.com/solutions/ht509488)
— System kann nach BIOS-Update hängen bleiben. Lösung: Power-Cycle. Kein bekanntes
HT-spezifisches Problem wie bei der M910q. `intel-ucode` Extension liefert auch hier
aktuellen Microcode.

**M920q i5-8500T Sonderfall:** Falls node-06 einen i5-8500T (6C/**6T**, kein HT) hat,
entfällt die Cross-Thread-Attackvektorfläche (MDS, L1TF, TAA) komplett — ohne den
Performance-Verlust von `nosmt`. Ein Security-Vorteil gegenüber den M910q-Nodes mit
HT-fähigen i7-CPUs.

---

## 2. Patch-Platzierung

### Warum alle Sysctls in `common.yaml` gehören

Die Patch-Chain im Makefile ist:
```
common.yaml → [controlplane|worker|worker-gpu].yaml → nodes/<name>.yaml
```

Die Sysctls in diesem Dokument lassen sich in zwei Kategorien teilen:

| Kategorie | Hardware-spezifisch? | Platzierung |
|-----------|---------------------|-------------|
| **Sysctls** (TCP-Tuning, Netzwerk-Security, Filesystem-Limits, Memory-Management, Kernel-Hardening) | **Nein** — das sind Linux/Kubernetes/DRBD Best Practices, die jedem Node nutzen | `patches/common.yaml` |
| **Boot-Parameter** (CPU-Governor, C-States, IOMMU, CPU-Mitigations) | **Intel-spezifisch** — funktionieren aber identisch auf Skylake + Coffee Lake | `talos-factory-schematic.yaml` via Image Factory |

**Sysctls sind betriebssystem-/workload-abhängig, nicht hardware-abhängig.** `vm.dirty_ratio`,
`net.ipv4.tcp_syncookies`, `fs.inotify.max_user_watches` etc. funktionieren identisch auf
jeder x86_64-Hardware.

**Boot-Parameter sind Intel-spezifisch, aber für beide Generationen identisch.**
`intel_idle.max_cstate`, `intel_iommu`, `cpufreq.default_governor=performance` nutzen die
gleichen Intel-Hardware-Interfaces auf Skylake und Coffee Lake. Sie gehören ins Image Factory
Schematic (`talos-factory-schematic.yaml`), das alle 6 Standard-Nodes teilen.

### Talos v1.12 UKI-Boot Hinweis

Ab Talos v1.8+ mit UKI-Boot (sd-boot) werden `machine.install.extraKernelArgs` **nur beim
Install/Upgrade in das UKI-Image gebrannt**. Für dauerhaft wirksame Boot-Parameter ist der
empfohlene Weg das Image Factory Schematic mit `customization.extraKernelArgs`. Ein
`talosctl upgrade` mit dem neuen Schematic-Image wendet die Parameter an.

### Schematic-Strategie: Shared vs. Per-Node

Das Image Factory Schematic bestimmt zwei Aspekte des Install-Images:
1. `extraKernelArgs` — Boot-Parameter, die ins UKI gebrannt werden
2. `systemExtensions` — Kernel-Module und Firmware im Image

**Drei Granularitätsstufen** wurden evaluiert:

| Strategie | Schematics | Operativer Aufwand pro Talos-Upgrade |
|-----------|:----------:|--------------------------------------|
| **Per-Node** (7 Schematics) | 7 | 7x Image Factory API, 7 Install-URLs, 7 Schematic-IDs |
| **Per-Role** (3 Schematics) | 3 | 3x API, differenzierte URLs in CP/Worker/GPU-Patches |
| **Shared + GPU** (2 Schematics) | 2 | 2x API, 2 Install-URLs — aktueller Stand |

#### Analyse: Was würde sich pro Node/Rolle unterscheiden?

**Boot-Parameter:** Alle `extraKernelArgs` (CPU-Governor, C-States, IOMMU, NVMe-Tuning,
Security-Hardening) sind universell anwendbar. Kein Parameter ist nur für eine Rolle oder
einen einzelnen Node relevant:
- `nvme_core.default_ps_max_latency_us=0` — wichtiger auf Control-Plane (etcd fdatasync)
  aber auch für Worker (DRBD) vorteilhaft
- `cpufreq.default_governor=performance` — gleicher Nutzen auf allen Nodes
- Security-Parameter (`mitigations=auto`, IOMMU) — keine Rolle-spezifischen Unterschiede

**Extensions:** Alle Standard-Nodes nutzen identische Extensions:
- `drbd` — LINSTOR/DRBD auf allen Nodes
- `i915` — Integrierte Intel GPU; auf headless Servern geladen aber harmlos
- `intel-ice-firmware` — Nicht benötigt (alle Nodes nutzen I219-LM/e1000e), aber harmlos
  (~wenige MB Image-Overhead)
- `intel-ucode` — Microcode-Updates auf allen Nodes nötig
- `nvme-cli` — NVMe-Management auf allen Nodes nützlich

#### Entscheidung: Shared + GPU (2 Schematics)

**Per-Node-Schematics sind nicht empfohlen.** Die Gründe:

1. **Keine Hardware-Divergenz:** Alle Standard-Nodes (M910q + M920q) nutzen die gleiche
   Intel-Mikroarchitektur (Skylake/Coffee Lake) mit identischen Boot-Parametern und
   Extensions.
2. **Operativer Overhead:** Jedes zusätzliche Schematic bedeutet einen separaten Image
   Factory API-Call pro Talos-Version-Upgrade, eine separate `machine.install.image`-URL,
   und eine separate Schematic-ID. Bei 6 Standard-Nodes vervielfacht sich der
   Upgrade-Aufwand.
3. **Konfigurationsdrift-Risiko:** Separate Schematics können über Zeit auseinanderdriften
   (vergessene Parameter auf einzelnen Nodes) — ein gemeinsames Schematic garantiert
   Konsistenz.
4. **Kein Rolle-spezifischer Bedarf:** Control-Plane- und Worker-Nodes profitieren gleich
   von allen Boot-Parametern. Die etcd-spezifischen Vorteile
   (`nvme_core.default_ps_max_latency_us=0`, `pcie_aspm=off`) sind auf Workers nicht
   schädlich — sie reduzieren dort ebenso I/O-Latenz für DRBD.
5. **YAGNI:** Falls ein Node in Zukunft andere Hardware bekommt (z.B. AMD statt Intel),
   kann das Schematic dann aufgesplit werden. Präventives Splitting erzeugt unnötige
   Komplexität.

**Die GPU-Separierung ist korrekt** weil dort tatsächlich andere Extensions (NVIDIA statt
i915) und andere Modul-Parameter benötigt werden — ein fundamental anderes Image.

```
Aktuelle Schematic-Zuordnung:
┌─────────────────────────────────────────────┐
│ talos-factory-schematic.yaml                │
│ → node-01, node-02, node-03 (Control Plane) │
│ → node-04, node-05, node-06 (Worker)        │
├─────────────────────────────────────────────┤
│ talos-factory-schematic-gpu.yaml            │
│ → node-gpu-01 (GPU Worker)                  │
└─────────────────────────────────────────────┘
```

---

## 3. Talos-Defaults (bereits gesetzt)

Talos v1.12 erzwingt die folgenden KSPP (Kernel Self Protection Project) Parameter automatisch.
**Diese dürfen NICHT nochmal gesetzt werden** (Duplikate können Konflikte verursachen):

### Boot-Parameter (Talos-enforced)
| Parameter | Wert | Zweck |
|-----------|------|-------|
| `slab_nomerge` | (flag) | Verhindert Slab-Cache-Merging, härtet Heap-Exploitation |
| `pti` | `on` | Page Table Isolation — Meltdown-Mitigation |
| `init_on_alloc` | `1` | Memory bei Allokation nullen (via `CONFIG_INIT_ON_ALLOC_DEFAULT_ON`) |
| `module.sig_enforce` | `1` | Nur signierte Kernel-Module laden |
| `proc_mem.force_override` | `never` | Verhindert Schreiben auf `/proc/PID/mem` |

### Sysctls (Talos-enforced)
| Sysctl | Wert | Zweck |
|--------|------|-------|
| `kernel.kptr_restrict` | `2` | Kernel-Pointer vor allen Prozessen verstecken |
| `kernel.dmesg_restrict` | `1` | Kernel-Log nur mit `CAP_SYSLOG` |
| `kernel.perf_event_paranoid` | `3` | Kein Profiling ohne Root |
| `kernel.randomize_va_space` | `2` | Volle ASLR für Userspace |
| `kernel.yama.ptrace_scope` | `2` | ptrace nur mit `CAP_SYS_PTRACE` |
| `kernel.unprivileged_bpf_disabled` | `1` | eBPF nur mit `CAP_BPF` |
| `net.core.bpf_jit_harden` | `2` | Volle BPF JIT-Hardening (Constant Blinding für alle User) |
| `user.max_user_namespaces` | `0` | Unprivilegierte User-Namespaces deaktiviert |
| `vm.unprivileged_userfaultfd` | `0` | Unprivilegiertes userfaultfd deaktiviert |
| `dev.tty.ldisc_autoload` | `0` | TTY Line-Discipline Autoloading aus |
| `dev.tty.legacy_tiocsti` | `0` | Legacy-Keystroke-Injection aus |
| `fs.protected_symlinks` | `1` | Symlink-TOCTOU-Races verhindern |
| `fs.protected_hardlinks` | `1` | Hardlink-TOCTOU-Races verhindern |
| `fs.protected_fifos` | `2` | FIFO-Erstellung in Sticky-Dirs einschränken |
| `fs.protected_regular` | `2` | Regular-File-Erstellung in Sticky-Dirs einschränken |
| `fs.suid_dumpable` | `0` | Keine Core-Dumps von SUID-Prozessen |

> **Quelle:** [`pkg/kernel/kspp/kspp.go`](https://github.com/siderolabs/talos/blob/main/pkg/kernel/kspp/kspp.go)
> im Talos-Repository.

---

## 4. Performance-Parameter

### 4.1 Storage I/O

**Platzierung:** `patches/common.yaml` → `machine.sysctls`

Diese Parameter steuern, wann der Kernel modifizierte (dirty) Memory-Pages auf Disk flusht.
Auf SSDs/NVMe sind Flushes schnell, daher wollen wir öfter und kleinere Flushes statt
seltene große (die Write-Stalls verursachen).

| Sysctl | Wert | Default | Begründung |
|--------|------|---------|------------|
| `vm.dirty_ratio` | `10` | `20` | Maximaler Prozentsatz des Gesamtspeichers, der dirty sein darf, bevor der schreibende Prozess blockiert und flusht. Auf 10% gesenkt, weil SSDs/NVMe schnell flushen können — kürzere, vorhersagbarere Flush-Zeiten. Verhindert plötzliche Write-Stalls wenn sich 20% des RAMs an dirty pages angesammelt haben. |
| `vm.dirty_background_ratio` | `5` | `10` | Prozentsatz bei dem der Background-Writeback-Thread anfängt zu flushen. Früher starten = kleinerer dirty-pool = geringere Wahrscheinlichkeit dass `dirty_ratio` erreicht wird. |
| `vm.dirty_expire_centisecs` | `1500` | `3000` | Wie lange (in 1/100s) dirty data maximal im Cache liegen darf. 15s statt 30s — reduziert Datenverlust-Risiko bei Stromausfall und hält die Write-Pipeline in Bewegung. |
| `vm.dirty_writeback_centisecs` | `300` | `500` | Wie oft der Writeback-Thread aufwacht. Alle 3s statt 5s = gleichmäßigere I/O-Last. |

**Hinweis zum I/O-Scheduler:** Der Scheduler (`none`/noop) wird über Boot-Parameter gesetzt,
siehe [4.9 Boot-Parameter: Performance](#49-boot-parameter-performance).

**Block-Device-Queue-Parameter** (`read_ahead_kb`, `nr_requests`, `rq_affinity`) können in
Talos **nicht** per Sysctl gesetzt werden — sie liegen unter `/sys/block/*/queue/` und
bräuchten udev-Rules. Die Kernel-Defaults (128KB read-ahead, 256 nr_requests) sind für
gemischte Kubernetes-Workloads akzeptabel.

---

### 4.2 TCP-Buffer (DRBD-Replikation)

**Platzierung:** `patches/common.yaml` → `machine.sysctls`

Große TCP-Buffer sind kritisch für DRBD-Replikation. LINBIT empfiehlt in ihrer
[Performance-Tuning-Dokumentation](https://kb.linbit.com/tuning-drbd-for-write-performance)
Buffer bis 56MB für 10Gbps-Links. Für unsere 1Gbps-Links sind 16MB ein guter Kompromiss.

| Sysctl | Wert | Default | Begründung |
|--------|------|---------|------------|
| `net.core.rmem_max` | `16777216` | `~212992` | Maximaler Receive-Socket-Buffer (16MB). Default ist ~208KB — viel zu klein für DRBD-Replikation und Kubernetes-API-Traffic. Erlaubt dem TCP-Autotuner auf 1Gbps-Links volle Throughput zu nutzen. |
| `net.core.wmem_max` | `16777216` | `~212992` | Maximaler Send-Socket-Buffer (16MB). Gleiche Begründung. |
| `net.core.rmem_default` | `1048576` | `~212992` | Default-Receive-Buffer (1MB). Hebt den Default an, sodass Anwendungen ohne explizite Buffer-Konfiguration trotzdem vernünftige Buffer bekommen. |
| `net.core.wmem_default` | `1048576` | `~212992` | Default-Send-Buffer (1MB). |
| `net.ipv4.tcp_rmem` | `4096 1048576 16777216` | `4096 131072 6291456` | TCP-Receive-Buffer: min=4K, default=1MB, max=16MB. Der Kernel auto-tuned innerhalb dieses Bereichs. Default-Max von ~6MB kann DRBD auf schnellen Links bottlenecken. |
| `net.ipv4.tcp_wmem` | `4096 1048576 16777216` | `4096 16384 4194304` | TCP-Send-Buffer: min=4K, default=1MB, max=16MB. Default-Max von ~4MB ist zu niedrig für konsistenten DRBD-Throughput. |
| `net.core.optmem_max` | `2097152` | `20480` | Maximale Größe für Ancillary-Buffer (sendmsg() Control-Data). 2MB statt 20KB — relevant für High-Throughput-Networking mit vielen Socket-Options. |

---

### 4.3 TCP-Verhalten

**Platzierung:** `patches/common.yaml` → `machine.sysctls`

| Sysctl | Wert | Default | Begründung |
|--------|------|---------|------------|
| `net.ipv4.tcp_slow_start_after_idle` | `0` | `1` | **Einzeln wichtigster DRBD-Tuning-Parameter** (LINBIT-Empfehlung). Deaktiviert TCP Slow Start nach Idle-Perioden. DRBD-Verbindungen sind langlebig aber können burst-artig sein. Ohne diesen Param resettet TCP das Congestion-Window nach Idle, was temporäre Throughput-Einbrüche bei der Replikation verursacht. |
| `net.ipv4.tcp_tw_reuse` | `1` | `0` | Erlaubt Wiederverwendung von TIME_WAIT-Sockets für neue Verbindungen (wenn sicher). Kubernetes erzeugt viele kurzlebige Verbindungen — ohne dies können Ephemeral-Ports unter Last ausgehen. |
| `net.ipv4.ip_local_port_range` | `1024 65535` | `32768 60999` | Erweitert den Ephemeral-Port-Bereich. Mehr Ports = weniger Contention für Outbound-Verbindungen (Kubernetes Service-Traffic, Pod-zu-Pod, DRBD-Replikation). |
| `net.ipv4.tcp_fastopen` | `3` | `0` | Aktiviert TCP Fast Open für Client (1) + Server (2) = 3 (beide). Reduziert Connection-Setup-Latenz durch Senden von Daten im SYN-Packet. Nutzt Kubernetes Service-zu-Service-Kommunikation. |
| `net.ipv4.tcp_mtu_probing` | `1` | `0` | Aktiviert Path MTU Discovery bei Blackhole-Erkennung. Wert 1 = probt nur bei Blackhole-Detection (konservativ). Hilft wenn Netzwerkpfade unterschiedliche MTUs haben. |
| `net.ipv4.tcp_keepalive_time` | `600` | `7200` | Sekunden bevor Keepalive-Probes auf Idle-Verbindungen gesendet werden. 10min statt 2h — Kubernetes profitiert von schnellerer Erkennung toter Verbindungen. |
| `net.ipv4.tcp_keepalive_intvl` | `30` | `75` | Sekunden zwischen Keepalive-Probes. Zusammen mit `tcp_keepalive_time` und `tcp_keepalive_probes`: tote Verbindung erkannt in 600 + (30 x 10) = 900s (15min). |
| `net.ipv4.tcp_keepalive_probes` | `10` | `9` | Anzahl fehlgeschlagener Probes bevor Verbindung geschlossen wird. |

---

### 4.4 Connection Handling & Backlog

**Platzierung:** `patches/common.yaml` → `machine.sysctls`

| Sysctl | Wert | Default | Begründung |
|--------|------|---------|------------|
| `net.core.somaxconn` | `32768` | `4096` | Maximum Listen-Backlog-Queue-Länge. Kubernetes API-Server, Kubelet und Service-Endpoints akzeptieren viele gleichzeitige Verbindungen. Verhindert Connection-Drops bei Burst-Traffic (z.B. nach Node-Reboot wenn alle Pods gleichzeitig reconnecten). |
| `net.core.netdev_max_backlog` | `16384` | `1000` | Maximale Pakete in der INPUT-Queue wenn das Interface schneller empfängt als der Kernel verarbeiten kann. Default 1000 ist für Gigabit-Links mit vielen Pods zu niedrig — verhindert Packet-Drops bei Traffic-Bursts. |
| `net.ipv4.tcp_max_syn_backlog` | `8192` | `1024` | Maximale Half-Open (SYN_RECV) Verbindungen. Schützt vor SYN-Floods und erlaubt gleichzeitig legitimen Burst-Traffic nach Node-Restarts. |

---

### 4.5 Conntrack

**Platzierung:** `patches/common.yaml` → `machine.sysctls`

| Sysctl | Wert | Default | Begründung |
|--------|------|---------|------------|
| `net.netfilter.nf_conntrack_max` | `131072` | `65536` | Maximale Conntrack-Table-Einträge. Obwohl Cilium mit eBPF-basiertem kube-proxy-Replacement den Großteil des Connection-Trackings selbst handhabt, trifft mancher Traffic (host-network Pods, node-lokaler Traffic) noch die Kernel-Conntrack-Table. 131072 gibt Headroom. Jeder Eintrag verbraucht ~300 Bytes = ~37MB RAM bei voller Table. |

---

### 4.6 ARP-Cache

**Platzierung:** `patches/common.yaml` → `machine.sysctls`

Kubernetes-Cluster mit vielen Pods generieren viele ARP-Einträge. Die Defaults sind für
7+ Nodes mit Hunderten Pods zu niedrig und führen zu "neighbor table overflow"-Errors.

| Sysctl | Wert | Default | Begründung |
|--------|------|---------|------------|
| `net.ipv4.neigh.default.gc_thresh1` | `1024` | `128` | Minimum ARP-Einträge bevor Garbage Collection läuft. |
| `net.ipv4.neigh.default.gc_thresh2` | `2048` | `512` | Soft-Maximum — GC wird über diesem Wert für 5s verzögert. |
| `net.ipv4.neigh.default.gc_thresh3` | `4096` | `1024` | Hard-Maximum — GC läuft immer über diesem Wert. |

---

### 4.7 Memory Management

**Platzierung:** `patches/common.yaml` → `machine.sysctls`

| Sysctl | Wert | Default | Begründung |
|--------|------|---------|------------|
| `vm.overcommit_memory` | `1` | `0` | Standard-Kubernetes-Empfehlung. Erlaubt immer Memory-Overcommit. Kubelet und cgroups verwalten Memory-Limits — ohne diesen Param kann `malloc()` fehlschlagen obwohl via cgroups Memory verfügbar ist. |
| `vm.panic_on_oom` | `0` | `0` | Kein Kernel-Panic bei OOM. Der OOM-Killer soll seine Arbeit machen — Kubernetes QoS-Klassen (Guaranteed/Burstable/BestEffort) steuern seine Auswahl. Explizit gesetzt als Dokumentation der Absicht. |
| `vm.max_map_count` | `524288` | `65530` | Maximale Memory-Mapped-Areas pro Prozess. Benötigt von Elasticsearch, JVM-basierten Apps, und Workloads mit vielen mmap-Regionen. Standard-Produktionswert für Kubernetes. |
| `vm.min_free_kbytes` | `65536` | `~variabel` | 64MB reservierter Freispeicher für Kernel-Allokationen. Verhindert Memory-Allocation-Failures während Netzwerk-Paketverarbeitung oder Disk-I/O. Besonders wichtig für DRBD, das Memory für seine Replikations-Buffer braucht. |

---

### 4.8 Filesystem & Process Limits

**Platzierung:** `patches/common.yaml` → `machine.sysctls`

| Sysctl | Wert | Default | Begründung |
|--------|------|---------|------------|
| `fs.inotify.max_user_watches` | `524288` | `8192` | Standard-Kubernetes-Produktionsempfehlung. Kubelet, Container-Runtimes und viele Pods (Config-Watchers, Log-Tailer) nutzen inotify intensiv. Jeder Watch verbraucht ~1KB Kernel-Memory. |
| `fs.inotify.max_user_instances` | `8192` | `128` | Jeder Container kann mehrere inotify-Instanzen erstellen. 8192 gibt ausreichend Headroom für hohe Pod-Dichte. |
| `fs.file-max` | `2097152` | `~100K-400K` | Systemweites File-Handle-Limit. Kubernetes-Nodes mit vielen Pods öffnen viele Files (Sockets, Logs, ConfigMap-Mounts). 2M gibt großzügigen Headroom. |
| `kernel.pid_max` | `4194304` | `32768` | Maximaler PID-Wert. Jeder Container-Prozess bekommt eine PID. 4M ermöglicht hohe Pod-Dichte ohne PID-Exhaustion. |

---

### 4.9 Boot-Parameter: Performance

**Platzierung:** `talos-factory-schematic.yaml` → `customization.extraKernelArgs`

Diese Parameter sind **Intel-spezifisch** und gehören ins Image Factory Schematic.
Kaby Lake (M910q) und Coffee Lake (M920q) nutzen die gleichen Intel-Hardware-Interfaces —
alle Parameter funktionieren identisch auf beiden Plattformen.

| Parameter | Begründung |
|-----------|------------|
| `cpufreq.default_governor=performance` | Talos defaultet auf `schedutil`, der die CPU-Frequenz dynamisch skaliert. `performance` locked alle Cores auf Max-Frequenz — eliminiert Ramp-Up-Latenz bei DRBD-Replikation und Container-Scheduling. Trade-off: ~2-5W mehr Verbrauch pro Node. Auf M910q/M920q (35W TDP) akzeptabel. |
| `intel_idle.max_cstate=0` | Deaktiviert Intel Idle-Driver C-State-Übergänge komplett. Kaby Lake und Coffee Lake unterstützen tiefe C-States (bis C10), jeder Exit kostet Mikrosekunden Latenz. Wert 0 hält alle Cores aktiv. |
| `processor.max_cstate=0` | Companion zum obigen — limitiert den ACPI-Processor-Driver C-States. Beide sind nötig, da der Kernel zwei separate C-State-Kontrollpfade hat. |
| `transparent_hugepage=madvise` | Setzt Transparent Huge Pages auf `madvise` statt `always`. In `always`-Mode verursacht THP Latenz-Spikes durch Memory-Compaction/Defragmentierung — besonders schädlich für etcd (auf Control-Plane-Nodes) und Redis. `madvise` = Apps die profitieren können opt-in, alles andere vermeidet den Overhead. |
| `elevator=none` | Setzt den I/O-Scheduler global auf `none` (noop). Für NVMe universell empfohlen — NVMe-Drives haben eigenes internes Command-Queuing (bis 64K Queue-Depth), Kernel-seitiges Reordering ist nur CPU-Overhead. Für SATA-SSDs ebenfalls korrekt — kein Seek-Penalty. |
| `nvme_core.default_ps_max_latency_us=0` | Deaktiviert NVMe Autonomous Power State Transitions (APST). Samsung SSDs (970 PRO/EVO) wechseln aggressiv in Stromsparmodi, was beim Aufwachen Latenz-Spikes von bis zu 500µs verursacht. Besonders schädlich für etcd-fdatasync auf Control-Plane-Nodes, aber auch für DRBD-I/O auf Workers relevant. Ohne diesen Parameter können sporadische I/O-Latenz-Ausreißer auftreten, selbst wenn ASPM und C-States bereits deaktiviert sind, da APST ein NVMe-Controller-interner Mechanismus ist. |
| `pcie_aspm=off` | Deaktiviert PCIe Active State Power Management auf allen Links. Eliminiert Link-Level-Power-State-Übergänge, die variable Latenz auf dem NVMe-PCIe-Pfad erzeugen. Ergänzt `intel_idle.max_cstate=0` für konsistente Low-Latency — ohne diesen Parameter kann der PCIe-Link in L0s/L1 wechseln, auch wenn die CPU wach bleibt. Auf Always-On-Servern mit 35W TDP ist der zusätzliche Stromverbrauch (<1W) vernachlässigbar. |
| `workqueue.power_efficient=0` | Deaktiviert Power-Efficient Workqueue-Modus. Im Default kann der Kernel per-CPU-Workqueues auf Shared-Workers verschieben, um Strom zu sparen — dies opfert CPU-Cache-Lokalität. Auf Always-On-Server-Nodes ist der eingesparte Strom irrelevant, aber die bessere Cache-Nutzung verbessert Latenz bei Interrupt-Verarbeitung, Timer-Callbacks und Netzwerk-Workqueues. |

---

## 5. Security-Parameter

### 5.1 Netzwerk-Hardening

**Platzierung:** `patches/common.yaml` → `machine.sysctls`

Keine dieser Einstellungen wird von Talos automatisch gesetzt. Sie sind
Standard-Linux-Netzwerk-Hardening.

#### IP-Spoofing-Schutz (Reverse Path Filtering)

| Sysctl | Wert | Default | Begründung |
|--------|------|---------|------------|
| `net.ipv4.conf.all.rp_filter` | `0` | `2` | **Deaktiviert.** Cilium BPF-Datapath bypassed den Kernel-FIB für Pod-Traffic — `rp_filter=1` (strict) verursacht False-Positive-Drops auf Pod-lxc-Interfaces, da der Kernel die BPF-Routing-Entscheidung nicht sieht. Cilium übernimmt Source-Validierung im eBPF-Programm. |
| `net.ipv4.conf.default.rp_filter` | `0` | `2` | Gilt für neu erstellte Interfaces (z.B. Cilium veth-Pairs). Gleiche Begründung. |

> **Cilium-Kompatibilität:** `rp_filter` muss `0` sein wenn Cilium im eBPF kube-proxy
> replacement mode läuft. Der BPF-Datapath routet Pakete ohne den Kernel-FIB — der Kernel
> sieht Source-Adressen die nicht über das empfangende Interface routbar erscheinen und
> droppt sie fälschlicherweise. Cilium's eigene eBPF-Programme validieren Source-Adressen.

#### ICMP-Hardening

| Sysctl | Wert | Default | Begründung |
|--------|------|---------|------------|
| `net.ipv4.icmp_echo_ignore_broadcasts` | `1` | `0` | Ignoriert Broadcast-ICMP-Echo-Requests. Verhindert Smurf-Attacks, bei denen ein Angreifer ICMP-Echo an die Broadcast-Adresse sendet und alle Hosts antworten. |
| `net.ipv4.icmp_ignore_bogus_error_responses` | `1` | `0` | Ignoriert ungültige ICMP-Error-Responses. Verhindert Log-Flooding durch fehlerhafte Netzwerkgeräte. |

#### SYN-Flood-Schutz

| Sysctl | Wert | Default | Begründung |
|--------|------|---------|------------|
| `net.ipv4.tcp_syncookies` | `1` | `0` | Aktiviert SYN-Cookies: Bei SYN-Flood werden Verbindungen ohne Connection-Table-Einträge gehandhabt. Der Server kodiert seinen State im SYN-ACK-Cookie und validiert ihn im finalen ACK. |

#### TCP TIME-WAIT Assassination Protection

| Sysctl | Wert | Default | Begründung |
|--------|------|---------|------------|
| `net.ipv4.tcp_rfc1337` | `1` | `0` | Dropped RST-Pakete für Sockets im TIME-WAIT-State (RFC 1337). Verhindert dass ein Angreifer TIME-WAIT-Sockets vorzeitig beendet, was zu Connection-Hijacking führen kann. |

#### ICMP-Redirects (MITM-Schutz)

Kubernetes-Nodes sind keine Router und sollten weder Routing-Änderungen per ICMP-Redirect
akzeptieren noch senden. Ein Angreifer im gleichen Netzwerk könnte Redirects senden um
Traffic über sich umzuleiten (Man-in-the-Middle).

| Sysctl | Wert | Default | Begründung |
|--------|------|---------|------------|
| `net.ipv4.conf.all.accept_redirects` | `0` | `1` | Keine ICMP-Redirects akzeptieren. |
| `net.ipv4.conf.default.accept_redirects` | `0` | `1` | Auch für neue Interfaces. |
| `net.ipv4.conf.all.secure_redirects` | `0` | `1` | Auch keine "secure" Redirects von Gateway-Routern. Unsere Routing-Tabelle ist statisch. |
| `net.ipv4.conf.default.secure_redirects` | `0` | `1` | |
| `net.ipv6.conf.all.accept_redirects` | `0` | `1` | IPv6-Pendant. |
| `net.ipv6.conf.default.accept_redirects` | `0` | `1` | |
| `net.ipv4.conf.all.send_redirects` | `0` | `1` | Keine Redirects senden — Nodes sind keine Router. |
| `net.ipv4.conf.default.send_redirects` | `0` | `1` | |

#### Source-Routing deaktivieren

| Sysctl | Wert | Default | Begründung |
|--------|------|---------|------------|
| `net.ipv4.conf.all.accept_source_route` | `0` | `0` | Source-Routing erlaubt dem Absender die Route eines Pakets vorzugeben — kann Firewall-Regeln umgehen. Auf den meisten Systemen bereits default 0, explizit gesetzt als Absicherung. |
| `net.ipv4.conf.default.accept_source_route` | `0` | `0` | |
| `net.ipv6.conf.all.accept_source_route` | `0` | `0` | IPv6-Pendant. |
| `net.ipv6.conf.default.accept_source_route` | `0` | `0` | |

#### Martian-Packet-Logging

| Sysctl | Wert | Default | Begründung |
|--------|------|---------|------------|
| `net.ipv4.conf.all.log_martians` | `0` | `0` | **Deaktiviert.** Cilium BPF-Routing erzeugt False-Positive Martian-Warnings auf Pod-lxc-Interfaces und flutet damit das Kernel-Log. Da `rp_filter=0` gesetzt ist (siehe oben), wären Martian-Logs ohnehin wenig aussagekräftig. |
| `net.ipv4.conf.default.log_martians` | `0` | `0` | Gleiche Begründung. |

#### IPv6 Router Advertisements deaktivieren

| Sysctl | Wert | Default | Begründung |
|--------|------|---------|------------|
| `net.ipv6.conf.all.accept_ra` | `0` | `1` | Verhindert Rogue-RA-Attacks. Unsere Nodes nutzen statische IPv4-Adressen — Router Advertisements sind unnötig. Ein Angreifer könnte RA senden um sich als Default-Gateway einzuschleusen. |
| `net.ipv6.conf.default.accept_ra` | `0` | `1` | |

---

### 5.2 Kernel-Hardening

**Platzierung:** `patches/common.yaml` → `machine.sysctls`

Ergänzend zu den Talos-KSPP-Defaults (siehe [Kapitel 3](#3-talos-defaults-bereits-gesetzt)):

| Sysctl | Wert | Default | Begründung |
|--------|------|---------|------------|
| `kernel.kexec_load_disabled` | `1` | `0` | Verhindert Laden eines neuen Kernels zur Laufzeit via kexec. Könnte von einem Angreifer genutzt werden um Security-Controls zu umgehen. Dies ist ein **One-Way-Switch** — einmal gesetzt, kann er nur durch Reboot zurückgesetzt werden. |
| `kernel.sysrq` | `0` | `~varies` | Deaktiviert SysRq komplett. Talos-Nodes sind headless — SysRq über Tastatur ist irrelevant. Über `/proc/sysrq-trigger` könnte ein Angreifer mit Root-Zugriff das System manipulieren (Reboot, Sync, Crash). |
| `kernel.core_pattern` | `\|/bin/false` | `core` | Leitet Core-Dumps nach `/bin/false` um — effektiv deaktiviert. Core-Dumps können sensitive Memory-Inhalte (Secrets, Credentials) auf Disk schreiben. Ergänzt `fs.suid_dumpable=0` (bereits von Talos gesetzt). |

---

### 5.3 Memory Protection

**Platzierung:** `patches/common.yaml` → `machine.sysctls`

| Sysctl | Wert | Default | Begründung |
|--------|------|---------|------------|
| `vm.mmap_rnd_bits` | `32` | `28` | Erhöht die mmap-ASLR-Entropie von 28 auf 32 Bit auf x86_64. Das sind 16x mehr mögliche Adressen — macht ASLR-Bypasses signifikant schwieriger. |
| `vm.mmap_rnd_compat_bits` | `16` | `8` | Gleiches für 32-Bit-Kompatibilitäts-mmap. 16 Bit statt 8 Bit Entropie. |

---

### 5.4 Boot-Parameter: Security

**Platzierung:** `talos-factory-schematic.yaml` → `customization.extraKernelArgs`

| Parameter | Begründung |
|-----------|------------|
| `mitigations=auto` | Aktiviert automatisch alle relevanten CPU-Vulnerability-Mitigations für die erkannte CPU. Der Kernel erkennt die CPUID und wendet automatisch die korrekten Mitigations an — funktioniert für Skylake (M910q) und Coffee Lake (M920q) gleichermaßen. Siehe [5.5 CPU-Vulnerability-Matrix](#55-cpu-vulnerability-matrix-skylake--coffee-lake). `auto` ist der Default, aber explizit setzen dokumentiert die Absicht. Ohne `nosmt` — auf 4C/8T M910q wäre der HT-Verlust (20-30% Throughput) zu schmerzhaft. |
| `init_on_free=1` | Nullt Memory bei Freigabe. Verhindert Use-After-Free Info-Leaks — freigegebener Speicher kann keine sensitiven Daten mehr enthalten. 3-8% Performance-Overhead, akzeptabel für Homelab. Talos hat `init_on_alloc=1` bereits per Kernel-Config aktiv, aber `init_on_free` ist **nicht** standardmäßig an. |
| `page_alloc.shuffle=1` | Randomisiert die Page-Allocator-Freelists. Macht page-level Heap-Attacks schwieriger. Vernachlässigbarer Performance-Impact, kann sogar Cache-Behavior leicht verbessern. |
| `randomize_kstack_offset=on` | Randomisiert den Kernel-Stack-Offset bei jedem Syscall-Entry. Verhindert Exploits die auf deterministischem Kernel-Stack-Layout basieren (z.B. CVE-2019-18683). Sehr geringer Overhead. |
| `vsyscall=none` | Deaktiviert die Legacy-vsyscall-Page (feste virtuelle Adresse). Wurde als ROP-Gadget-Quelle missbraucht. Moderne Software nutzt vDSO statt vsyscall. Kein Impact auf Container-Workloads oder Kubernetes-Komponenten. |
| `debugfs=off` | Deaktiviert das Debug-Filesystem (`/sys/kernel/debug/`). Verhindert Information-Disclosure über Kernel-Interna. Keine bekannten Kompatibilitätsprobleme mit Kubernetes, Cilium oder DRBD. |
| `intel_iommu=on` | Aktiviert den Intel IOMMU-Treiber (VT-d muss im BIOS aktiviert sein). IOMMU bietet DMA-Isolation — verhindert dass ein kompromittiertes PCIe-Gerät beliebig System-Memory lesen/schreiben kann. M910q (B250): VT-d-Exposure im BIOS variiert. M920q (Q370): vPro-Chipset, VT-d ist first-class und sollte im BIOS verfügbar sein. |
| `iommu=force` | Erzwingt IOMMU für alle Geräte, auch wenn der Treiber es normalerweise nicht nutzen würde. |
| `iommu.passthrough=0` | Deaktiviert IOMMU-Passthrough-Mode — stellt sicher dass alle DMA-Operationen durch die IOMMU gehen. |
| `iommu.strict=1` | Erzwingt strikte TLB-Invalidierung. Verhindert Stale-TLB-Einträge die DMA-Attacks ermöglichen könnten. Geringer Performance-Overhead. |

---

### 5.5 CPU-Vulnerability-Matrix (Skylake / Coffee Lake)

Beide Hardware-Generationen basieren auf der gleichen Skylake-Mikroarchitektur. Coffee Lake
(M920q, Stepping 10/U0 bei 8th Gen) hat **keine** Hardware-Fixes für Meltdown oder L1TF —
die gleichen Software-Mitigations wie Skylake sind nötig. Hardware-Fixes existieren erst ab
Coffee Lake Refresh Stepping 12+ (9th Gen).

`mitigations=auto` aktiviert automatisch alle verfügbaren Mitigations basierend auf der
erkannten CPUID:

| Vulnerability | CVE(s) | Kernel-Mitigation | M910q (Skylake) | M920q (Coffee Lake) |
|--------------|--------|-------------------|-----------------|---------------------|
| **Meltdown** | CVE-2017-5754 | Page Table Isolation (PTI) | Software (Talos: `pti=on`) | Software (gleich — kein HW-Fix bei Stepping 10) |
| **Spectre v1** | CVE-2017-5753 | Software-Mitigations (kein Toggle) | Immer aktiv | Immer aktiv |
| **Spectre v2** | CVE-2017-5715 | Retpoline + IBRS | Aktiv via `mitigations=auto` | Identisch |
| **Spectre v2 (BHI)** | CVE-2022-0001 | Branch History Injection Mitigation | Aktiv via `mitigations=auto` | Identisch |
| **Spec Store Bypass (v4)** | CVE-2018-3639 | SSBD (prctl-based) | Aktiv via `mitigations=auto` | Identisch |
| **L1TF (Foreshadow)** | CVE-2018-3615/20/46 | L1D Cache Flush on VMentry | Aktiv via `mitigations=auto` | Software (gleich — kein HW-Fix bei Stepping 10) |
| **MDS (Zombieload etc.)** | CVE-2018-12126/7/30, CVE-2019-11091 | VERW-based Buffer Overwrite | Aktiv via `mitigations=auto` | Identisch |
| **TAA** | CVE-2019-11135 | TSX Async Abort Mitigation | Aktiv via `mitigations=auto` | Identisch |
| **SRBDS (CrossTalk)** | CVE-2020-0543 | Microcode Mitigation | Aktiv via `intel-ucode` Extension | Identisch |
| **MMIO Stale Data** | CVE-2022-21123/5/6 | VERW + Buffer Clearing | Aktiv via `mitigations=auto` | Identisch |
| **Downfall (GDS)** | CVE-2022-40982 | Gather Data Sampling Mitigation | Aktiv via `mitigations=auto` + Microcode | Identisch (gleicher AVX2 Gather-Bug) |

**Entscheidung gegen `nosmt`:** `mitigations=auto,nosmt` würde Hyper-Threading deaktivieren
und damit MDS/L1TF/TAA Cross-Thread-Attacken vollständig eliminieren. Auf M910q mit nur 4
physischen Cores wäre der Verlust von 8→4 Threads aber ein 20-30% Throughput-Einbruch. Da
die Nodes in einem isolierten Homelab-Netzwerk laufen und Cross-Thread-Attacks lokal
privilegierten Zugriff erfordern, ist das Risiko akzeptabel.

**M920q i5-8500T Sonderfall:** Falls node-06 einen i5-8500T (6C/**6T**, kein HT) hat,
gibt es **keine** Hyper-Threading-Threads — Cross-Thread-Attacks (MDS, L1TF, TAA) haben
damit null Angriffsfläche, ohne dass `nosmt` nötig wäre. Dies ist ein inhärenter
Security-Vorteil gegenüber den HT-fähigen M910q-Nodes.

---

## 6. Nicht empfohlene Parameter

Diese Parameter wurden evaluiert und bewusst **nicht** aufgenommen:

| Parameter | Warum nicht |
|-----------|-------------|
| `mitigations=off` | Deaktiviert ALLE CPU-Mitigations. 5-15% Performance-Gewinn, aber alle Spectre/Meltdown/MDS-Schutzmaßnahmen weg. Nur vertretbar auf komplett isolierten Systemen ohne Multi-Tenancy. |
| `kernel.modules_disabled=1` | Verhindert Laden ALLER Kernel-Module nach Boot. DRBD-Module werden dynamisch geladen → bricht Storage. NVIDIA-Module auf GPU-Node → bricht GPU-Support. |
| `lockdown=confidentiality` | Blockiert BPF-Reads von Kernel-Memory. Cilium loggt Warnungen "use of bpf to read kernel RAM is restricted" und kann funktional eingeschränkt sein ([Talos PR #8535](https://github.com/siderolabs/talos/pull/8535)). |
| `lockdown=integrity` | Kann Laden von Out-of-Tree-Modulen (DRBD, NVIDIA) blockieren. Talos erzwingt bereits `module.sig_enforce=1` was ähnlichen Schutz bietet. |
| `net.ipv4.icmp_echo_ignore_all=1` | Bricht Kubernetes Health-Probes und Cilium Connectivity-Checks. Nur `icmp_echo_ignore_broadcasts` ist sicher. |
| `net.ipv4.tcp_timestamps=0` | Deaktiviert TCP-Timestamps → bricht TCP PAWS (Protection Against Wrapped Sequences). Clock-Fingerprinting-Risiko minimal im Homelab-LAN. |
| `net.ipv4.tcp_sack=0` | Deaktiviert TCP Selective Acknowledgements → erheblicher Performance-Verlust auf verlustbehafteten Netzwerken. Security-Risiko auf gepatchten Kerneln gering. |
| `net.ipv4.ip_forward=0` | Kubernetes/Cilium erfordern IP-Forwarding für Pod-Networking. **Niemals setzen.** |
| `net.ipv6.conf.all.disable_ipv6=1` | Manche Kubernetes-Komponenten und Cilium nutzen IPv6-Loopback. Nur deaktivieren wenn sicher ist dass nichts IPv6 nutzt. |
| `kernel.yama.ptrace_scope=3` | Talos setzt bereits `2` (CAP_SYS_PTRACE erforderlich). Wert `3` deaktiviert ptrace komplett, auch für Root — kann Container-Debugging-Tools und Monitoring-Agents brechen. |
| `user.max_user_namespaces=0` | Talos setzt dies bereits. **Achtung:** K8s v1.33+ aktiviert User-Namespaces für Pods per Default. Bei K8s v1.35 (unser Target) muss dies ggf. auf `11255` gesetzt werden wenn UserNamespaces genutzt werden sollen. |
| `kernel.warn_limit=1` / `kernel.oops_limit=1` | KSPP empfiehlt diese, aber sie verursachen Panic/Reboot beim ersten Kernel-Warning oder Oops. Kann Reboot-Loops bei kleineren Issues verursachen. |
| `oops=panic` | Sofortiger Kernel-Panic bei Oops. Gleiches Problem — Reboot-Loops. |
| `iommu.passthrough=1` | Umgeht die IOMMU für DMA — genau das Gegenteil von Hardening. Nur für Performance-Maximierung ohne Security-Anspruch. |
| `nosmt=force` | Deaktiviert Hyper-Threading komplett. Eliminiert Cross-Thread-Attacks, aber 20-30% Throughput-Verlust auf 4-Core M910q. Auf M920q mit i5-8500T (6C/6T) irrelevant, da kein HT vorhanden. Nicht vertretbar für M910q-Nodes. |
| `net.ipv4.tcp_no_metrics_save=1` | Verhindert Caching von TCP-Metriken (RTT, cwnd, ssthresh) pro Destination. DRBD nutzt langlebige, persistente TCP-Verbindungen zu festen Peers — die gecachten Metriken sind akkurat und beschleunigen Connection-Re-Establishment nach Failover. Nur sinnvoll bei vielen kurzlebigen Verbindungen zu wechselnden Hosts. |
| `net.ipv4.tcp_window_scaling=1` | Seit Kernel 2.6.7 standardmäßig aktiviert. Die konfigurierten 16MB TCP-Buffer setzen Window-Scaling bereits implizit voraus (erforderlich für Buffer >64KB). Explizites Setzen bietet keinen Mehrwert. |
| `net.ipv4.tcp_congestion_control=bbr` | BBR (Bottleneck Bandwidth and Round-trip propagation time) kann auf WAN-Strecken mit Paketverlust besser als Cubic performen, hat aber bekannte Fairness-Probleme und kann auf LAN-Verbindungen (1GbE, <1ms RTT) schlechter als Cubic sein. Für DRBD-Replikation im lokalen Netzwerk kein Vorteil. |
| `e1000e EEE=0` (Modul-Param) | Deaktiviert Energy Efficient Ethernet (~4ms Wake-Latenz bei Idle). Auf einem aktiven DRBD-Replikationslink triggert EEE selten. Nur untersuchen falls sporadische DRBD-Latenz-Spikes beobachtet werden. In Talos nur über `machine.kernel.modules` oder Factory-Schematic konfigurierbar. |
| CFS-Scheduler-Tuning (`sched_min_granularity_ns`) | Feinsteuerung der CFS-Zeitscheiben für etcd-Latenz. Risiko: andere Control-Plane-Komponenten (kube-apiserver, kube-scheduler) werden ausgehungert. Auf einem 4-Core-System mit moderater Last nicht notwendig. |

---

## 7. Hinweis: bpf_jit_harden auf GPU-Worker

`patches/worker-gpu.yaml` setzt `net.core.bpf_jit_harden: "1"`, was den Talos-Default
von `2` auf `1` absenkt:

- **Wert 2** (Talos-Default): Constant Blinding für **alle** User, inklusive Root
- **Wert 1** (GPU-Worker): Constant Blinding nur für unprivilegierte User

Da Cilium als privilegierter DaemonSet (Root + alle Capabilities) läuft, sind beide Werte
kompatibel. Wert `2` hat einen minimalen Performance-Impact auf BPF JIT-Compilation für Root.

**Empfehlung:** Den Override in `worker-gpu.yaml` entfernen und den Talos-Default (`2`)
beibehalten, sofern keine messbaren Performance-Probleme auf dem GPU-Node festgestellt
werden. Das Entfernen des Overrides ist eine separate Entscheidung und nicht Teil dieses
Dokuments.

---

## 8. Offene Punkte

### 8.1 VT-d (IOMMU) im BIOS

`intel_iommu=on` erfordert dass VT-d im BIOS aktiviert ist.

✅ **Auf allen 7 Nodes bestätigt aktiv.** Hardware-Analysen (`docs/hardware-analysis-*.md`)
zeigen IOMMU im DMA-FQ-Modus auf allen PCI-Devices aller Nodes. VT-d ist überall im BIOS
aktiviert — auch node-gpu-01 (BTC B250C Board) hat IOMMU für alle Devices inkl. NVIDIA GPUs.

### ~~8.2 Schematic-Update: Neue Boot-Parameter~~ ✅ Erledigt

Die 3 Boot-Parameter wurden in beide Factory Schematics aufgenommen:

```
nvme_core.default_ps_max_latency_us=0   # Samsung NVMe APST deaktivieren
pcie_aspm=off                            # PCIe Link-Power-Management aus
workqueue.power_efficient=0              # Workqueues CPU-gebunden halten
```

Aktuell 18 Boot-Parameter pro Schematic. `make -C talos schematics` + `make -C talos gen-configs` durchgeführt.
Nodes müssen noch per `make -C talos upgrade-<node>` auf das neue Image aktualisiert werden.

### 8.3 Config-Apply auf alle Nodes

Sysctls aus `patches/common.yaml` sind auf allen Nodes verifiziert und aktiv. Die 18
Schematic-Boot-Parameter sind **noch nicht angewendet** — erfordern `make -C talos upgrade-<node>`
pro Node (mit DRBD-Drain vor jedem Reboot).

Empfohlene Reihenfolge:
1. `make -C talos upgrade-<node>` pro Node (mit DRBD-Drain vor jedem Node-Reboot)
2. Verifikation aller Boot-Parameter (siehe [9. Verifikation](#9-verifikation))

### ~~8.4 M920q CPU-Variante ermitteln~~ ✅ Erledigt

Hardware-Analyse zeigt: **i7-7700T** (4C/8T, Kaby Lake, **nicht** Coffee Lake).
Hyper-Threading ist aktiv — Cross-Thread-Mitigations (MDS, L1TF) zeigen "SMT vulnerable".
`nosmt` nicht empfohlen wegen 25% Throughput-Verlust auf einem Node mit nur 16 GB RAM
(bereits ~40% Memory-Utilization, am meisten im Cluster).

### 8.5 Block-Device-Queue-Tuning

`read_ahead_kb`, `nr_requests`, `rq_affinity` und der per-device Scheduler können nicht
per Sysctl gesetzt werden. Optionen:
- `elevator=none` als Boot-Parameter (deckt den Scheduler global ab) — ✅ bereits gesetzt
- Für die restlichen: udev-Rules über Talos-Extension oder Machine-Config (nicht trivial)
- Die Kernel-Defaults sind für gemischte Workloads akzeptabel

### ~~8.6 Hardware-Analyse der restlichen Nodes~~ ✅ Erledigt

Alle 7 Nodes vollständig analysiert. Ergebnisse in `docs/hardware-analysis-<node>.md`.
Wesentliche Erkenntnisse:
- node-04 (i3-6100T, Skylake): GDS-Vulnerability **nicht mitigierbar** (kein Microcode-Fix)
- node-06 (M920q): Tatsächlich i7-7700T Kaby Lake (nicht Coffee Lake wie angenommen)
- node-gpu-01: Realtek USB NIC mit 5% Packet-Drops, `siderolabs/realtek-firmware` hinzugefügt

---

## 9. Verifikation

Nach dem Anwenden der Konfiguration können die Parameter verifiziert werden:

```bash
# Sysctls prüfen (Beispiele)
talosctl -n 192.168.2.61 -e 192.168.2.61 read /proc/sys/vm/dirty_ratio
talosctl -n 192.168.2.61 -e 192.168.2.61 read /proc/sys/net/ipv4/tcp_slow_start_after_idle
talosctl -n 192.168.2.61 -e 192.168.2.61 read /proc/sys/net/ipv4/conf/all/rp_filter
talosctl -n 192.168.2.61 -e 192.168.2.61 read /proc/sys/kernel/kexec_load_disabled
talosctl -n 192.168.2.61 -e 192.168.2.61 read /proc/sys/fs/inotify/max_user_watches

# Boot-Parameter prüfen (sollte alle extraKernelArgs enthalten)
talosctl -n 192.168.2.61 -e 192.168.2.61 read /proc/cmdline
# Erwartete Parameter: cpufreq.default_governor=performance intel_idle.max_cstate=0
# processor.max_cstate=0 transparent_hugepage=madvise elevator=none mitigations=auto
# init_on_free=1 page_alloc.shuffle=1 randomize_kstack_offset=on vsyscall=none
# debugfs=off intel_iommu=on iommu=force iommu.passthrough=0 iommu.strict=1
# nvme_core.default_ps_max_latency_us=0 pcie_aspm=off workqueue.power_efficient=0

# CPU-Vulnerability-Status
talosctl -n 192.168.2.61 -e 192.168.2.61 ls /sys/devices/system/cpu/vulnerabilities/
# Für Details pro Vulnerability:
talosctl -n 192.168.2.61 -e 192.168.2.61 read /sys/devices/system/cpu/vulnerabilities/spectre_v2

# IOMMU aktiv?
talosctl -n 192.168.2.61 -e 192.168.2.61 dmesg | grep -i iommu

# I/O-Scheduler prüfen
talosctl -n 192.168.2.61 -e 192.168.2.61 read /sys/block/sda/queue/scheduler
talosctl -n 192.168.2.61 -e 192.168.2.61 read /sys/block/nvme0n1/queue/scheduler

# CPU-Governor prüfen
talosctl -n 192.168.2.61 -e 192.168.2.61 read /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor

# NVMe APST deaktiviert? (sollte 0 sein)
talosctl -n 192.168.2.61 -e 192.168.2.61 read /sys/module/nvme_core/parameters/default_ps_max_latency_us

# PCIe ASPM deaktiviert?
talosctl -n 192.168.2.61 -e 192.168.2.61 dmesg | grep -i "aspm"
```

---

## 10. Quellen

### Talos / KSPP
- [Talos KSPP Source Code (kspp.go)](https://github.com/siderolabs/talos/blob/main/pkg/kernel/kspp/kspp.go)
- [Talos Kernel Reference](https://docs.siderolabs.com/talos/v1.12/reference/kernel)
- [KSPP Recommended Settings](https://kspp.github.io/Recommended_Settings.html)

### DRBD / LINSTOR
- [LINBIT: Tuning DRBD for Write Performance](https://kb.linbit.com/tuning-drbd-for-write-performance)
- [LINBIT: Performance Tuning for LINSTOR in Kubernetes](https://linbit.com/blog/performance-tuning-for-linstor-persistent-storage-in-kubernetes/)

### Kubernetes
- [Tuning Linux for Kubernetes (Peter Woods)](https://peterwoods.online/blog/tuning-linux-for-kubernetes)
- [Kubernetes Kernel Tuning: Hidden Factors (Latitude.sh)](https://www.latitude.sh/blog/kubernetes-kernel-tuning-hidden-factors-killing-your-node-performance)
- [Kubernetes inotify Limits (GitHub Issue #46230)](https://github.com/kubernetes/kubernetes/issues/46230)

### Cilium
- [Cilium Tuning Guide](https://docs.cilium.io/en/stable/operations/performance/tuning/)
- [Cilium BPF Architecture](https://docs.cilium.io/en/stable/reference-guides/bpf/architecture/)

### Linux Kernel
- [Linux Kernel VM Documentation](https://docs.kernel.org/admin-guide/sysctl/vm.html)
- [Linux Spectre Documentation](https://docs.kernel.org/admin-guide/hw-vuln/spectre.html)
- [Intel P-State Documentation](https://docs.kernel.org/admin-guide/pm/intel_pstate.html)
- [NVMe Power Management (nvme_core module parameters)](https://docs.kernel.org/admin-guide/kernel-parameters.html)
- [PCIe ASPM Documentation](https://docs.kernel.org/power/pci.html)
- [Workqueue Power-Efficient Mode](https://docs.kernel.org/core-api/workqueue.html)

### Security Hardening
- [Madaidan's Linux Hardening Guide](https://madaidans-insecurities.github.io/guides/linux-hardening.html)
- [Kernel Boot Parameter Hardening (docs.arbitrary.ch)](https://docs.arbitrary.ch/security/kernel_params.html)

### Intel CPU Vulnerabilities
- [Intel Affected Processors List](https://www.intel.com/content/www/us/en/developer/topic-technology/software-security-guidance/processors-affected-consolidated-product-cpu-model.html)
- [Intel Downfall (GDS) — Skylake Affected](https://www.phoronix.com/news/Intel-Downfall-All-Skylake)
- [Lenovo ThinkCentre M910q Hyper-Threading Advisory](https://pcsupport.lenovo.com/solutions/ht504407)

### Hardware-Vergleich
- [ServeTheHome: M910q Review](https://www.servethehome.com/lenovo-thinkcentre-m710q-tiny-guide-and-ce-review/)
- [ServeTheHome: M920q Review](https://www.servethehome.com/lenovo-thinkcentre-m920-and-m920q-tiny-guide-and-review/)
- [Intel i5-8500T Specifications](https://www.intel.com/content/www/us/en/products/sku/129941/intel-core-i58500t-processor-9m-cache-up-to-3-50-ghz/specifications.html)
- [Intel Q370 Chipset Specifications](https://www.intel.com/content/www/us/en/products/sku/133282/intel-q370-chipset/specifications.html)
- [Coffee Lake Microarchitecture — WikiChip](https://en.wikichip.org/wiki/intel/microarchitectures/coffee_lake)
- [Lenovo M920q BIOS Flash Hang Issue](https://pcsupport.lenovo.com/solutions/ht509488)

### Talos Issues / PRs
- [Talos Lockdown/BPF Issue PR #8535](https://github.com/siderolabs/talos/pull/8535)
- [Talos extraKernelArgs und UKI Issue #11145](https://github.com/siderolabs/talos/issues/11145)
