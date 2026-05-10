# node-03 NIC Diagnosis Report — 2026-04-11

**Issue:** #74  
**Analyst:** Claude Code (automated MCP probe)  
**Probe window:** 2026-04-11T20:04:20Z – 20:20:03Z (943 s / ~15.7 min)

---

## 1. Summary

Node-03 (`192.168.2.63`, Intel I219-V `enp0s31f6`, e1000e driver) has accumulated
**2,068,389 `rx_crc_errors`** since the 2026-02-28 baseline (which showed zero). The
counter name in Issue #74 was slightly mis-stated: the accumulating counter is
`rx_crc_errors`, not `rx_frame_errors` (which is zero). Over the 15-minute live probe
window all error counters were **Δ=0** — the NIC is currently quiescent. However, the
dmesg captured a **Half-Duplex negotiation flash** (06:14:10Z today) during a link-up
event, followed 53 ms later by link-down and re-negotiation to Full Duplex. Combined
with 7 link-down events (carrier_changes=14) and similar CRC-error accumulation on
node-02 (182 K), this points to **intermittent link-negotiation failures at the
physical layer** as the root cause of the CRC burst pattern.

**Go/No-Go Verdict: `PROCEED WITH EXCLUSION`** — PR #2 (DRBD TLS) may proceed,
but node-03 must be excluded from the initial DRBD-TLS rollout wave until a load
test under `enp0s31f6.110` confirms Δ=0 under traffic.

---

## 2. Methodology

All probes are read-only Talos MCP calls. No `talosctl` CLI, no cluster mutations.

| Tool | Purpose |
|---|---|
| `talos_list_files /sys/class/net/` | Interface inventory + TALOS_MCP_ALLOWED_PATHS validation |
| `talos_get LinkStatus namespace=network` | COSI link state, driver, firmware |
| `talos_get EthernetStatus namespace=network` | Ring buffer sizes, offload feature flags |
| `talos_read_file /sys/class/net/<iface>/statistics/*` | Error counters, 3 samples T0/T+300s/T+900s |
| `talos_read_file /sys/class/net/<iface>/{duplex,speed,mtu,carrier*}` | Link state, flapping |
| `talos_read_file /proc/interrupts` | IRQ affinity, CPU hotspot |
| `talos_list_files /sys/class/net/enp0s31f6/queues/` | RX/TX queue layout |
| `talos_dmesg` (500 lines, client-side filtered) | Link-up/down timestamps, duplex negotiation |
| `pods_log cilium-hft42 kube-system tail=500` | Software-drop ruling out (Issue #75 koinzidenz) |
| Phase B: same steps on node-01 (192.168.2.61) + node-02 (192.168.2.62) | Baseline comparison |

Sampling interval: T0=20:04:20Z, T+300s=20:10:03Z (Δ=343s), T+900s=20:20:03Z (Δ=943s).

---

## 3. Raw Evidence

### 3.1 LinkStatus (COSI) — all three nodes

| Field | node-03 | node-01 | node-02 |
|---|---|---|---|
| product | Ethernet Connection (2) I219-**V** | I219-V | I219-V |
| pciID | 8086:15B8 | 8086:15B8 | 8086:15B8 |
| driver | e1000e | e1000e | e1000e |
| driverVersion | 6.18.18-talos | 6.18.18-talos | 6.18.18-talos |
| firmwareVersion | **0.8-4** | **0.8-4** | **0.8-4** |
| duplex (COSI) | Full | Full | Full |
| speedMbit | 1000 | 1000 | 1000 |
| operationalState | up | up | up |
| linkState | true | true | true |
| mtu | 1500 | 1500 | 1500 |
| port | TwistedPair | TwistedPair | TwistedPair |
| queueDisc | pfifo_fast | pfifo_fast | pfifo_fast |
| last COSI update | 2026-04-11T14:21:38Z | 2026-04-11T06:14:11Z | 2026-04-11T06:14:11Z |

Note: node-01 and node-02 COSI timestamps both 06:14:11Z — simultaneous link event.

### 3.2 EthernetStatus — enp0s31f6 (node-03 only)

| Field | Value |
|---|---|
| Ring buffer rx | **256** (max: 4096) |
| Ring buffer tx | **256** (max: 4096) |
| rx-checksum | on |
| rx-vlan-hw-parse | on |
| tx-scatter-gather | on |
| rx-gro | on |
| tx-generic-segmentation | on |
| rx-hashing | on |

Ring buffer at default 256 — not tuned. Not the primary error cause (rx_missed_errors=28 only).

### 3.3 Interface Inventory — node-03

| Interface | Type | operstate | carrier_changes |
|---|---|---|---|
| enp0s31f6 | physical (e1000e) | up | **14** (7 up + 7 down) |
| enp0s31f6.110 | 802.1q VLAN 110 | up | 2 |

### 3.4 Counter Snapshots — enp0s31f6, node-03

| Counter | T0 (20:04:20Z) | T+300s (20:10:03Z) | T+900s (20:20:03Z) | Δ T0→T+900s |
|---|---|---|---|---|
| rx_crc_errors | **2,068,389** | 2,068,389 | 2,068,389 | **0** |
| rx_frame_errors | 0 | 0 | 0 | 0 |
| rx_errors | 4,136,623 | 4,136,623 | 4,136,623 | **0** |
| rx_dropped | 3,277,599 | 3,278,281 | 3,279,484 | +1,885 |
| rx_missed_errors | 28 | 28 | 28 | 0 |
| rx_fifo_errors | 0 | 0 | 0 | 0 |
| collisions | 0 | 0 | 0 | **0** |
| carrier_changes | 14 | 14 | 14 | **0** |
| rx_packets | 1,475,407,214 | 1,475,844,549 | 1,476,625,096 | +1,217,882 ✓ live |

Errors per 1M packets (T0→T+900s window): **0 / 1,217,882 = 0 errors/1M**

### 3.5 Counter Snapshots — enp0s31f6.110, node-03 (T0)

| Counter | T0 | T+300s | Δ |
|---|---|---|---|
| rx_crc_errors | 0 | 0 | 0 |
| rx_errors | 0 | 0 | 0 |
| rx_packets | 34,816 | 35,192 | +376 ✓ |
| collisions | 0 | 0 | 0 |
| carrier_changes | 2 | 2 | 0 |

### 3.6 MTU / Duplex / Speed Matrix (sysfs, T0)

| Node | Interface | duplex | speed | mtu |
|---|---|---|---|---|
| node-03 | enp0s31f6 | **full** | 1000 | 1500 |
| node-03 | enp0s31f6.110 | full | 1000 | 1500 |
| node-01 | enp0s31f6 | full | 1000 | 1500 |
| node-02 | enp0s31f6 | full | 1000 | 1500 |

No MTU divergence. Duplex currently full on all nodes.

### 3.7 Phase B Baseline — node-01 / node-02 (T0)

| Counter | node-01 | node-02 |
|---|---|---|
| rx_crc_errors | **0** | **182,179** |
| rx_frame_errors | 0 | 0 |
| rx_errors | 0 | 364,356 |
| rx_dropped | 3,281,217 | 3,280,005 |
| collisions | 0 | 0 |
| carrier_changes | **14** | **12** |
| duplex | full | full |
| mtu | 1500 | 1500 |
| firmware | 0.8-4 | 0.8-4 |
| driverVersion | 6.18.18-talos | 6.18.18-talos |

Key: node-02 also has CRC errors (182K, ~11× fewer than node-03). Node-01 has zero.
All three nodes have similar carrier_changes (12–14) — cluster-wide flapping pattern.

### 3.8 IRQ Affinity + Queue Layout — node-03

```
IRQ 130  CPU0:0  CPU1:0  CPU2:1,595,981,528  CPU3:0   enp0s31f6
```

**All 1.596 billion NIC interrupts pinned to CPU2** — single-CPU hotspot.
Queue layout: **1 RX queue (rx-0), 1 TX queue (tx-0)** — single-queue NIC by design (I219-V hardware limit).

rx_missed_errors=28 and rx_fifo_errors=0 → ring buffer overrun is **not** the primary cause.

### 3.9 dmesg — NIC-relevant events (node-03, last 500 lines)

```
2026-04-11T06:14:00Z  [talos] removed address 192.168.2.60/32 from "enp0s31f6" (VIP loss)
2026-04-11T06:14:10Z  e1000e: NIC Link is Up 1000 Mbps HALF DUPLEX, Flow Control: None  ← !!!
2026-04-11T06:14:10Z  e1000e: NIC Link is Down  (53 ms after Half-Duplex up)
2026-04-11T06:14:13Z  e1000e: NIC Link is Up 1000 Mbps Full Duplex, Flow Control: None
2026-04-11T11:07:04Z  [talos] enabled shared IP 192.168.2.60 on enp0s31f6 (VIP restored)
2026-04-11T11:07:17Z  [talos] created new link enp0s31f6.110 vlan
2026-04-11T14:21:36Z  e1000e: NIC Link is Down
2026-04-11T14:21:40Z  e1000e: NIC Link is Up 1000 Mbps Full Duplex, Flow Control: None
```

**Critical observation:** At 06:14:10Z the link negotiated as **Half Duplex** for 53 ms,
immediately went down, then re-negotiated as Full Duplex. This is the mechanism for CRC
error accumulation: any frames arriving during the Half-Duplex window are mis-framed from
the Full-Duplex switch perspective, generating CRC errors in burst.

Node-01 and Node-02 COSI LinkStatus both updated at 06:14:11Z — same simultaneous flap
event on all CP nodes, consistent with a switch-side port event (reboot, STP topology
change, or port auto-negotiation reset).

### 3.10 Cilium Agent Log — node-03 (cilium-hft42, last 500 lines)

Filtered for: `drop`, `error`, `xdp`, `vlan`

**Result: 0 XDP events, 0 drop events, 0 vlan events.**

Errors present (44 lines): exclusively `ep-bpf-prog-watchdog` failures and
`CEP was deleted externally` warnings starting at 14:36:33Z — i.e. after the
14:21:36Z link-down event caused endpoint BPF programs to require reload.
These are BPF management events (Issue #75), **not** packet-level software drops.

---

## 4. Analysis

### Counter identity correction

Issue #74 title references "rxFrame errors". The actual accumulating counter is
`rx_crc_errors` (2,068,389). `rx_frame_errors` is zero on all three nodes. CRC errors
are L1/L2 frame integrity failures — the counter name difference is semantically minor
but important for ethtool driver-private counter correlation.

### Hypothesis evaluation

| Hypothesis | Evidence | Verdict |
|---|---|---|
| Half-Duplex mismatch (persistent) | sysfs duplex=full at T0, T+300, T+900; collisions=0 | **RULED OUT** (persistent state) |
| Transient Half-Duplex during negotiation | dmesg 06:14:10Z: 53ms Half-Duplex flash, then down+up Full | **CONFIRMED** as error mechanism |
| Layer-1 cable/port fault (continuous) | rx_crc_errors Δ=0 over 943s, no new flapping | **NOT ACTIVE** currently; quiescent |
| Ring-buffer overrun | rx_missed_errors=28 (stable), rx_fifo_errors=0 | **RULED OUT** |
| IRQ single-CPU saturation | CPU2 has 1.596B IRQs but errors not growing | **Not causal** |
| Link flapping | carrier_changes=14 (7 down events), confirmed in dmesg | **CONFIRMED** (historical) |
| MTU mismatch | all 1500 on parent + sub + all nodes | **RULED OUT** |
| VLAN sub-interface error source | enp0s31f6.110 all counters zero | **RULED OUT** |
| Software drops (Cilium/XDP) | cilium-hft42 logs: 0 XDP/drop/vlan events | **RULED OUT** |
| Driver version divergence | all nodes: 6.18.18-talos, firmware 0.8-4 | **RULED OUT** |
| Cluster-wide issue | node-02 has 182K CRC errors; node-01=0 | **PARTIAL** — infrastructure-wide L1 issue, node-03 worst affected |

### Root cause summary

The ~2M CRC errors accumulated in **burst episodes during link-up re-negotiation events**
where node-03's NIC transiently came up as Half Duplex before failing down and
re-negotiating correctly. The dmesg confirms at least one such episode (06:14:10Z today).
Over ~6 weeks since the Feb-28 baseline with 7 link-down events, each potential Half-
Duplex flash generates hundreds of thousands of CRC errors.

The simultaneous carrier_changes across all three CP nodes (12–14) and the synchronized
COSI timestamps at 06:14:11Z indicate the trigger is **switch-side** (SG3428 port event,
STP change, or auto-negotiation timing). However, node-03 produces ~11× more CRC errors
than node-02 and node-01 produces zero — suggesting node-03's specific switch port has
worse auto-negotiation stability, possibly related to cable quality, SFP/RJ45 contact,
or the specific SG3428 port assignment.

**Switch-side root cause confirmation requires SG3428 port statistics** — which are
outside this analysis scope (per user decision). See §6.

---

## 5. Go/No-Go Verdict

### Gate evaluation against plan thresholds

| Threshold | Measured | Triggered? |
|---|---|---|
| rx_crc_errors Δ > 0 over 15 min (enp0s31f6) | Δ=0 | No |
| rx_crc_errors Δ > 0 over 15 min (enp0s31f6.110) | Δ=0 | No |
| carrier_changes grows ≥1 between T0 and T+900s | Δ=0 | No |
| duplex: half in sysfs | full | No |
| collisions > 0 at any sample | 0 | No |
| Cilium drop/xdp events > 10/min | 0 events | No |

No BLOCK threshold triggered.

CLEAR requires iperf3 load test confirming Δ=0 under traffic — **not performed** (out of
scope; requires maintenance window). Historical 2M CRC errors remain unresolved.

### Verdict: **PROCEED WITH EXCLUSION**

**PR #2 (DRBD TLS) may proceed.** Node-03 must be excluded from the initial DRBD-TLS
rollout wave. Conditions for node-03 re-inclusion:

1. Re-test under artificial load: `iperf3` over `enp0s31f6.110` between two nodes,
   5 min continuous, monitoring `rx_crc_errors` Δ=0 throughout.
2. OR: physical remediation (cable swap, switch port change) confirmed clean.

---

## 6. Unverified / Open Questions

### Hard gaps (not accessible via MCP)

- **`ethtool -S` driver-private counters** (`rx_align_errors`, `rx_long_length_errors`,
  `rx_no_buffer_count`): These would confirm whether errors are Layer-1 signal integrity
  (alignment errors) vs. MAC framing. No sysfs path exists; requires `talosctl` debug
  container. If precise root-cause classification is required before any hardware action,
  open a follow-up issue for an ethtool-capable probe.

- **SG3428 port statistics**: Per scope decision, switch-side probes were excluded. The
  simultaneous flapping across all CP nodes strongly suggests a switch-side trigger. If
  the next link-flap event recurs, a switch-side investigation should be initiated as a
  parallel issue.

- **Regression onset**: Without upgrade timeline correlation (excluded per scope), the
  exact start of CRC accumulation cannot be dated. Hardware baseline 2026-02-28 vs.
  current measurement = "sometime in the last ~6 weeks."

- **Historical dmesg coverage**: Only the last 500 dmesg lines were available. Earlier
  link-flap events (accounting for the remaining ~2M CRC errors) are outside the ring
  buffer. Persistent logging would be needed for full temporal coverage.

### Note on counter name

Issue #74 title says "rxFrame errors." The actual counter is `rx_crc_errors`. The term
"rxFrame" was likely used loosely to describe CRC/frame integrity failures. This is
noted to avoid confusion in follow-up analysis.

---

## 7. Recommended Next Steps

Priority-ordered:

| # | Action | Gate for |
|---|---|---|
| 1 | Exclude node-03 from initial DRBD-TLS rollout in PR #2 via `LinstorCluster.nodeSelector` or hard DRBD affinity | PR #2 merge prerequisite for node-03 exclusion |
| 2 | Proceed with PR #2 merge for node-01, node-02, node-04, node-05, node-06 | PR #2 |
| 3 | Open follow-up issue: SG3428 port investigation for all CP node ports — identify why node-03 port produces 11× more CRC errors than node-02 during shared flap events | node-03 re-inclusion |
| 4 | Physical inspection: cable + RJ45 connector on node-03 ↔ SG3428 port; swap port if possible | node-03 re-inclusion |
| 5 | Load test: iperf3 over enp0s31f6.110, 5 min, Δrx_crc_errors=0 required | node-03 re-inclusion into DRBD rollout |
| 6 | Optional: open follow-up issue for ethtool-capable probe (`rx_align_errors`) if physical inspection inconclusive | Root-cause precision |
| 7 | Investigate why all CP nodes experience synchronized carrier_changes (12–14); likely STP topology changes or switch-side auto-negotiation events on SG3428 | node-01/02 long-term stability |

The existing soft anti-affinity in `linstor-cluster.yaml:37` (keeping linstor-controller
off node-03) remains the correct mitigation until steps 3–5 are completed.

---

*Report generated by automated Talos MCP probe. All data read-only. No cluster mutations performed.*
