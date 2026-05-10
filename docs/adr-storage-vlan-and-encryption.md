# ADR-0001: Storage VLAN and Encryption

**Status**: Accepted  
**Date**: 2026-04-11  
**Issue**: #24 — Storage network isolation

---

## Context

The homelab cluster runs 7 nodes, each with a single 1 Gbps NIC (`enp0s31f6`). LINSTOR/DRBD
replication traffic currently shares the management VLAN 1 (`192.168.2.0/24`) with all other
cluster traffic, including etcd heartbeats and Kubernetes API server communication.

The switch was upgraded from a Netgear GS308Ev4 (no ACL) to a **TP-Link Omada SG3428** (L2+
with L2/L3/L4 ACLs, DHCP Snooping, DAI, Storm Control). This upgrade converts VLAN isolation
from "cosmetic" to an enforced trust boundary.

---

## Decision

### VLAN 110 for storage isolation

DRBD/LINSTOR replication traffic is isolated onto a dedicated tagged **VLAN 110** sub-interface
(`enp0s31f6.110`), bound directly to the physical NIC without a bridge. Static addresses
`192.168.110.X/24` are assigned per storage node in `talos/nodes/node-XX.yaml`.

**Storage node set**: Determined by NFD label
`feature.node.kubernetes.io/storage-nvme.present=true` (pre-flight Spike #1). Not a
hand-maintained list. The GPU node (`node-gpu-01`) is structurally excluded by absence of the
NFD label and by the `worker-gpu.yaml` patch chain.

**Interface binding**: VLAN sub-interface `enp0s31f6.110`, **no bridge** (`br-storage` was
considered and rejected — one fewer moving part, avoids kernel routing complexity).

### DRBD transport_tls as the primary (and sole) crypto layer

DRBD `transport_tls` (kTLS, AES-NI software offload) is enabled as the **only** cryptographic
protection layer for VLAN 110 replication payload. This is a deliberate, empirically validated
decision — see §Layered-Defense below.

Enabled via **two** control points (verified against Piraeus v2.10.4 + LINSTOR v1.33.1
upstream sources, 2026-04-25):

1. **`LinstorSatelliteConfiguration.spec.internalTLS.tlsHandshakeDaemon: true`** —
   adds a privileged `ktls-utils` sidecar container into the `linstor-satellite`
   DaemonSet pod, mounting the existing `internalTLS` cert at `/etc/tlshd.d`.
   The sidecar runs `tlshd` userspace, which performs the TLS handshake on behalf
   of the kernel TLS ULP that DRBD ≥ 9.2.6 opens.
   Source: `pkg/resources/satellite/patches/tlshd.yaml` in piraeusdatastore/piraeus-operator @ v2.10.4.
2. **`LinstorCluster.spec.properties[]: {name: DrbdOptions/Net/tls, value: "yes"}`** —
   tells LINSTOR to render `net { tls yes; }` into the generated DRBD `.res` files,
   so DRBD opens TLS-ULP sockets that the in-pod tlshd then handshakes for.
   Source: piraeusdatastore/piraeus-operator @ v2.10.4 — `docs/how-to/drbd-tls.md`
   "Configure TLS for DRBD" section.

> **Important — API surface**: `DrbdOptions/Net/tls` MUST be set via the `LinstorCluster`
> CR, not via `linstor controller set-property` / `linstor node set-property` on the CLI.
> The operator's reconciler routes the property correctly; the LINSTOR CLI on v1.33.1
> rejects it as `Not a valid key` at controller and node scope (this was the false
> negative observed during PR #2a). Resource-definition scope may also accept it
> directly via CLI, but the documented and operator-supported path is the CR.

Certificates minted from the existing `linstor-internal-ca` namespaced Issuer in
`piraeus-datastore` — **not** a new ClusterIssuer. The `tlshd` sidecar reuses the
same Secret as the controller↔satellite gRPC/TLS path; no separate Secret naming
convention or per-satellite cert is required.

**Talos prerequisites** (no system extension needed — tlshd is a sidecar, not a host service):
- Linux kernel ≥ 4.19 with `CONFIG_TLS=y` (Talos 1.x ships this in-tree; verify
  on pinned version with `talos_read_file /proc/config.gz | gunzip | grep TLS`)
- DRBD ≥ 9.2.6 in satellite image — verify with `head -1 /proc/drbd` inside satellite
  pods before merging PR #2b
- NICs in this cluster (Intel I219 on M910q/M920q, RTL r8152 on node-gpu-01) do **not**
  support kernel TLS device offload — expect software TLS only (`TlsRxSw`/`TlsTxSw`
  in `/proc/net/tls_stat`); minor CPU cost at 1 GbE line rate, acceptable

**Rollout discipline** (DRBD does not support online TLS reconfiguration):
1. Apply both control-point changes; satellite pods rolling-restart with the
   sidecar attached. DRBD detaches/reattaches per node as the satellite pod
   restarts — storage stays online elsewhere via replica redundancy.
2. Per-node, sequential (never parallel across replicas of the same resource):
   `kubectl exec` the satellite pod and run
   `drbdadm suspend-io all && drbdadm disconnect --force all && drbdadm adjust all`
   to flip live connections to TLS. Brief I/O suspension per node — order it
   like a rolling drain, leverage existing `pre-drain-check.sh` hook.
3. Verify TLS active: nonzero `TlsRxSw`/`TlsTxSw` in `/proc/net/tls_stat` AND
   `ktls-utils` sidecar log line `Handshake with <peer> was successful`.

Bandwidth cap: `DrbdOptions/Disk/c-max-rate: 60M` (~50% of 1 Gbps) reserves headroom for
etcd heartbeats and Cilium WireGuard overhead.

> **Note (PR #2a)**: The correct LINSTOR path is `DrbdOptions/Disk/c-max-rate` (peer-device
> option). `DrbdOptions/Net/c-max-rate` is not a valid path — `c-max-rate` is a disk/peer-device
> property, not a net option.

---

## Three-Channel TLS Reality

LINSTOR/DRBD has three distinct TLS channels. Only the third is new work.

| Channel | Protocol | Port(s) | Current state | Change |
|---|---|---|---|---|
| LINSTOR API (client → controller) | gRPC/TLS via `apiTLS` | 3371 | ✅ TLS today — `linstor-cluster.yaml` Issuer `linstor-api-ca` | None |
| LINSTOR internal (controller ↔ satellite) | gRPC/TLS via `internalTLS` | 3370 | ✅ TLS today — `linstor-satellite-configuration.yaml` Issuer `linstor-internal-ca` | None |
| DRBD replication payload (satellite ↔ satellite) | DRBD protocol, optional `transport_tls` via kTLS | 7000–7999 | ❌ Plaintext today | **Enable** |

---

## Layered-Defense: Single-Layer (DRBD TLS Only)

**Pre-flight Spike #3** (empirical test, 2026-04-11) confirmed that Cilium's eBPF host program
**drops VLAN 110 frames** when DRBD binds directly to a bridge-less sub-interface.

### Spike #3 findings

Test setup: node-04 (`192.168.110.4`) → node-05 (`192.168.110.5`) via `enp0s31f6.110`
(no bridge), Cilium hostNetwork pod routing forced onto `enp0s31f6.110` via `/32` host route.

Result: **12 × "VLAN traffic disallowed by VLAN filter"** at `bpf_host.c:1546` (ifindex 8,
`enp0s31f6`) for ARP broadcasts on VLAN 110. Ping = 100% packet loss.

Cause: Cilium's BPF host program enforces an allowlist (`bpf.vlanBypass`) for VLAN-tagged
frames arriving on the physical NIC. VLAN 110 was not in the allowlist, so all frames were
dropped. This is expected and documented behavior in `bpf_host.c`.

### Consequence

VLAN 110 **must** be added to `bpf.vlanBypass` for DRBD to function. Once added, Cilium is
**bypassed** for VLAN 110 traffic — its eBPF program does not process or encrypt those frames.
`nodeEncryption: true` provides no protection for storage replication traffic.

**Defense architecture**:
- Layer 1 (enforced): **SG3428 ACL** — denies VLAN 110 ↔ all other VLANs at the switch
- Layer 2 (enforced): **DRBD `transport_tls`** — encrypts replication payload end-to-end

Cilium WireGuard (`nodeEncryption`) is **not** a layer for VLAN 110 traffic. It remains
beneficial for node-to-node traffic on the management VLAN (pod-to-pod WireGuard is
unaffected by this decision).

This is a two-layer system at L2 (ACL isolation) + L7 (DRBD TLS), not three layers.
The original "three-layer" framing in the design rationale is rejected.

---

## VLAN Schema (storage-relevant subset)

| VLAN ID | Purpose | Subnet | Interface | Bridge | `bpf.vlanBypass` |
|---|---|---|---|---|---|
| 1 (native) | Management / control plane | `192.168.2.0/24` | `enp0s31f6` | — | n/a (untagged) |
| 100 | KubeVirt VM network (existing) | VM-provided | `br-vm` | `br-vm` | yes (already) |
| **110** | **Storage (DRBD/LINSTOR)** | `192.168.110.0/24` | `enp0s31f6.110` | **no** | **yes (Spike #3: required)** |

---

## SG3428 Threat Model

The SG3428 is a **real trust boundary** for traffic classes it sees at L2.

| Feature | Status | Enforcement |
|---|---|---|
| 802.1Q VLAN isolation | ✅ | 5-VLAN schema (1/100/110/120/130) |
| L2/L3/L4 ACLs | ✅ (PR #6) | `deny VLAN 110 ↔ {1,100,120,130}`; `permit VLAN 110 ↔ VLAN 110` first |
| IP Source Guard + DAI | ✅ (PR #6) | Bound to tenant VLANs 120/130 |
| DHCP Snooping | ✅ (PR #6) | Trust only router port on VLAN 1 |
| BPDU Guard | ✅ (PR #6) | All node-facing ports |
| Storm Control | ✅ (PR #6) | Broadcast/multicast rate limit on node ports |
| Static L3 routing | ❌ (intentional) | VLAN routing stays at upstream router |
| Jumbo frames | ❌ (deferred) | MTU 1500 end-to-end; evaluate post-storage-VLAN stabilization |

**Accepted risk**: In-host bridge traffic (`br-vm`) is not visible to the switch. A VM on a
KubeVirt worker that compromises its hypervisor can send frames on other VLANs via `br-vm`.
`bpf.vlanBypass` means Cilium does not enforce policy on VLANs 100/120/130 for in-host traffic.
Mitigated by KubeVirt hypervisor isolation and Kyverno pod-admission policy.

---

## MTU

1500 end-to-end. The SG3428 supports jumbo frames (≤10K), but MTU > 1500 interacts with Cilium
WireGuard (80-byte overhead) and DRBD framing in non-obvious ways. Deferred to a separate
benchmark-driven PR after storage VLAN is stable. Do not bump silently in a non-benchmark PR.

---

## Caveats

1. **DRBD TLS is not online-reconfigurable**: enablement and rollback both require per-node
   `suspend-io` / `resume-io` via satellite pod restart. Budget the same time for rollback as
   for forward rollout.
2. **`bpf.vlanBypass` on VLAN 110 = Cilium does not see storage frames**: Hubble has no
   visibility into DRBD flows. Troubleshoot via `talosctl read /proc/net/tcp` or satellite pod
   `netstat`, not Hubble.
3. **Cert rotation**: cert-manager rotates per Issuer policy. Rotation triggers per-satellite
   restart (not automatic). Schedule in maintenance windows. Use per-satellite certs from
   `linstor-internal-ca` (same pattern as existing `internalTLS`).
4. **CP satellite presence**: If Spike #1 confirms control-plane nodes do NOT run LINSTOR
   satellites, the VLAN 110 config block moves from `talos/patches/drbd.yaml` (CP + worker) to
   `talos/patches/worker-kubevirt.yaml` (worker-only). Decision documented in Spike #1 findings.
5. **Spike #2 resolved**: DRBD `transport_tls` via `tlsHandshakeDaemon: true` is confirmed in
   the CRD schema at Piraeus Operator v2.10.4. The field is under `spec.internalTLS` in
   `LinstorSatelliteConfiguration`. The `tlshd` sidecar is added automatically by the operator
   when the flag is set. DRBD TLS rollout is unblocked.
6. **MAC-spreading via `deviceSelector` without `driver:` filter**: On KubeVirt worker nodes,
   `br-vm` (bridge, same MAC as `enp0s31f6`) matches any `deviceSelector: {hardwareAddr: X}`
   without a `driver:` constraint. When `VLANConfig` creates `enp0s31f6.110`, Talos also creates
   `br-vm.110` as a phantom sub-interface — DRBD sees two competing ARP responders for
   `192.168.110.X` and connections remain in Connecting state. Fix: add `driver: e1000e` to all
   worker `deviceSelector` blocks in `talos/nodes/node-0{4,5,6}.yaml`. Ref: siderolabs/talos#8709.
7. **LINSTOR shared-secret inconsistency for diskless clients**: When a diskless DRBD client
   resource is added to an existing resource (e.g., for a CSI PVC), LINSTOR v1.33.1 may generate
   the `.res` file on the diskless node with `cram-hmac-alg sha1` + `shared-secret` in the global
   `net {}` block while the existing server nodes receive no auth in their `net {}` block. This
   auth asymmetry causes `Authentication of peer failed` and keeps the diskless client in
   `StandAlone` indefinitely. Fix: set `DrbdOptions/Net/shared-secret` and
   `DrbdOptions/Net/cram-hmac-alg` explicitly on the resource-definition — LINSTOR will propagate
   to all nodes consistently. Example: `kubectl linstor resource-definition set-property <rname>
   DrbdOptions/Net/shared-secret "<secret-from-node-res-file>"`.

---

## Pre-flight Spike Results Summary

| Spike | Question | Result | ADR Impact |
|---|---|---|---|
| #1 | Storage node enumeration (NFD label) | **PASS** — node-01..06 all carry label; CPs included | VLAN 110 config → `talos/patches/drbd.yaml` (CP + worker Makefile rules) |
| #2 | Piraeus `tlsHandshakeDaemon` upstream validation | **PASS** — field present in CRD at v2.10.4; description confirms `tlshd` sidecar | `spec.internalTLS.tlsHandshakeDaemon: true` in `linstor-satellite-configuration.yaml` |
| #3 | Does Cilium drop VLAN 110 frames on bridge-less sub-interface? | **DROPS CONFIRMED** — 12× `bpf_host.c:1546` | Single-layer defense; VLAN 110 → `bpf.vlanBypass` |
| #4 | AES-NI + kernel CONFIG_TLS on storage nodes | **PASS** — `aes`/`avx`/`avx2` flags confirmed; `CONFIG_TLS=m`, module live (`tls 131072 0`) | kTLS operates in software (AES-NI accelerated); no `machine.kernel.modules` entry needed |
| #5 | Prometheus baselines (etcd P99, DRBD state) | **CONFIRMED** — `monitoring-kube-prometheus-kube-etcd` ServiceMonitor active in `monitoring` ns | Baseline capture: `histogram_quantile(0.99, rate(etcd_disk_wal_fsync_duration_seconds_bucket[5m]))` |
| #6 | GPU node r8152 `rx_dropped` baseline (T0) | T0 captured: 288,314 drops / 4,462,921 packets (~6.4% cumulative) | Delta budget: <1% of `rx_packets` over 1h post-PR #3 |
| #7 | Cilium L2 IPAM + L2 announcements feasibility | **FINDING** — `l2announcements.enabled` and `loadBalancer.l2.enabled` absent from `values.yaml` | Both flags must be added in PR #3 alongside `bpf.vlanBypass` update |

---

## Alternatives Considered

| Alternative | Reason rejected |
|---|---|
| Cilium WireGuard as sole crypto layer on VLAN 110 | Spike #3 proves Cilium is bypassed when `bpf.vlanBypass` includes VLAN 110 — cannot encrypt what it doesn't see |
| `br-storage` bridge on VLAN 110 | Adds a moving part; kernel routing complexity (multiple `/24` owners on different ifindices); rejected in talos-sre review |
| IPsec/Strongswan at host level | Requires significant additional configuration; DRBD TLS achieves the same goal at the replication layer with existing Piraeus Operator support |
| Jumping frames to VLAN 1 (no isolation) | Rejected — mixes storage replication with etcd/control-plane; SG3428 ACL enforcement would be impossible |

---

## Consequences

- DRBD replication traffic is isolated to VLAN 110 and ACL-blocked from reaching other VLANs
- Storage payloads are encrypted in transit via DRBD `transport_tls` (kTLS)
- Cilium has no visibility into VLAN 110 traffic (acceptable — storage is not a Kubernetes
  network-policy target; policy enforcement happens at L2 via SG3428 ACL)
- `bpf.vlanBypass` in `kubernetes/bootstrap/cilium/values.yaml` updated to `[100, 110]` in
  PR #2a (VLAN 110 prerequisite — empirically required by Spike #3 findings). VLANs 120/130
  to be added in their respective PRs when those VLANs are actively used.
- The "two-layer defense-in-depth" narrative used in the initial design is **corrected** to
  two independent layers: L2 ACL isolation (switch) + L7 encryption (DRBD TLS)
