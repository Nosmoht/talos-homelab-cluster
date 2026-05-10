# KubeVirt VLAN Networking on Talos Linux -- Research Report

**Researcher**: Ava Sterling | **Date**: 2026-03-29
**Context**: Talos Linux cluster, Cilium CNI, Multus deployed, single Intel e1000e NIC per node, flat 192.168.2.0/24

---

## Query Decomposition

The core question: *What is the best way to give KubeVirt VMs dedicated VLAN network access on a single-NIC Talos Linux homelab?*

Sub-questions researched:
1. Can Talos create VLAN sub-interfaces + Linux bridges declaratively?
2. Does OVS run on Talos? Is it worth the complexity?
3. Does Cilium have native VLAN/secondary-network support that replaces Multus?
4. Can Kube-OVN provide VLAN networks alongside Cilium?
5. Does Intel e1000e support SR-IOV?
6. How does macvtap compare to bridge for KubeVirt?
7. Is IPVLAN L3 relevant for VLAN use cases?
8. Does kubernetes-nmstate work on Talos?

---

## Approach 1: Linux Bridge + VLAN Sub-Interface (The Traditional Approach)

### How It Works
1. Talos machine config creates a VLAN sub-interface (e.g., `eth0.100`) on the physical NIC
2. A Linux bridge (e.g., `br-vlan100`) is created with the VLAN interface as a member
3. Multus + bridge CNI attach VM secondary interfaces to this bridge
4. VMs send/receive untagged traffic on the bridge; the host handles 802.1Q tagging

### Talos v1.9+ Compatibility: GOOD

Talos supports both VLAN sub-interfaces and bridges natively in machine config. As of Talos v1.8+ (PR #8950, merged July 2024), `vlan_filtering` is supported on bridge interfaces.

**Machine config pattern:**
```yaml
machine:
  network:
    interfaces:
      # Physical NIC - trunk port carrying tagged VLANs
      - interface: eth0
        dhcp: false
        addresses:
          - 192.168.2.X/24  # Management on native VLAN
        routes:
          - network: 0.0.0.0/0
            gateway: 192.168.2.1
      # VLAN sub-interface
      - interface: eth0.100
        dhcp: false
      # Bridge for the VLAN
      - interface: br-vlan100
        dhcp: false
        bridge:
          stp:
            enabled: true
          interfaces:
            - eth0.100
```

**NetworkAttachmentDefinition:**
```json
{
  "cniVersion": "0.3.1",
  "name": "vlan100-net",
  "type": "bridge",
  "bridge": "br-vlan100",
  "ipam": { "type": "host-local", "subnet": "10.100.0.0/24" }
}
```

### Known Limitation: Bridge Port VLAN Management (Issue #9117)

While `vlan_filtering` on the bridge itself is supported since v1.8, **configuring which VLANs are allowed on bridge ports** (the `bridge vlan add dev eth0 vid X master` equivalent) is still an open issue (#9117, as of Jan 2026). The WIP branch `jnohlgard/talos/bridge-port-vlan` exists but has not been merged.

**Workaround**: The VLAN sub-interface approach (creating `eth0.100` explicitly) sidesteps this entirely -- you do not need bridge port VLAN filtering when each VLAN has its own dedicated sub-interface and bridge. The `vlan_filtering` approach is only needed when you want a single trunk bridge that handles multiple VLANs.

### Evaluation

| Criterion | Rating | Notes |
|---|---|---|
| Talos compatibility | Excellent | Native machine config, no extensions needed |
| Complexity | Low | Standard Linux networking, well-documented |
| VM-to-VM same-host | Works | Bridge provides L2 switching between VMs |
| VM-to-external VLAN | Works | Tagged traffic exits via physical NIC |
| Performance | Good | Kernel bridge, some overhead vs. macvtap |
| Extensions required | None | Bridge and VLAN modules in Talos kernel |
| KubeVirt support | Official | Bridge binding is the recommended approach |

---

## Approach 2: Open vSwitch (OVS)

### How It Works
OVS is a production-grade programmable virtual switch. It can handle VLAN trunking, QoS, mirroring, and OpenFlow rules -- far more capable than a Linux bridge.

### Talos Compatibility: VIABLE BUT COMPLEX

The OVS kernel module **is compiled into the Talos kernel** (confirmed via Talos GitHub discussion #7793). Users have successfully deployed OVS on Talos via:
- A privileged DaemonSet running `ovs-vswitchd` and `ovsdb-server`
- Host networking + capabilities (`NET_ADMIN`, `SYS_MODULE`, `SYS_NICE`)
- Volume mounts for `/var/run/openvswitch` and `/var/lib/openvswitch`
- The OVS-managed interface must be set to `ignore: true` in Talos machine config

### Evaluation

| Criterion | Rating | Notes |
|---|---|---|
| Talos compatibility | Works | Kernel module present; userspace via DaemonSet |
| Complexity | HIGH | Privileged DaemonSet, OVS management overhead |
| VM-to-VM same-host | Excellent | Full L2 switching with flow rules |
| VM-to-external VLAN | Excellent | Native trunk/access port support |
| Performance | Good-Excellent | Optimized datapath, but complexity cost |
| Extensions required | None | Kernel module already compiled in |
| KubeVirt support | Works | Via ovs-cni plugin + Multus |

### Strategic Assessment

OVS is **overkill for a homelab**. It shines in multi-tenant, multi-hundred-VLAN environments (think OpenStack). For a homelab with a handful of VLANs, the Linux bridge approach delivers the same result with 1/10th the operational complexity. The privileged DaemonSet management, OVS database lifecycle, and debugging complexity (ovs-ofctl, ovs-vsctl) add significant toil without proportional benefit.

**Recommendation**: Skip unless you need OpenFlow-level traffic engineering.

---

## Approach 3: Cilium VLAN-Aware Networking

### What Cilium Actually Provides

Cilium's "VLAN 802.1q support" (documented in `docs.cilium.io/en/stable/configuration/vlan-802.1q/`) is **not a secondary network feature**. It is an eBPF bypass mechanism:

- By default, Cilium's eBPF programs on the native device (e.g., `eth0`) will **drop** VLAN-tagged packets that arrive on VLAN sub-interfaces
- The `--vlan-bpf-bypass` flag (or Helm `bpf.vlanBypass`) tells Cilium to **pass through** specific VLAN tags without dropping them
- This allows VLAN sub-interfaces (e.g., `eth0.100`) to function alongside Cilium

**This is essential plumbing for Approaches 1 and 6** but is NOT a replacement for Multus. Cilium does not:
- Create secondary network interfaces for pods/VMs
- Provide NetworkAttachmentDefinition support
- Manage VLAN interfaces or bridges

### Cilium Multi-Network Roadmap

- **Cilium Enterprise (Isovalent) 1.14+**: Has a "Multi-Network" feature for secondary pod interfaces. This is an enterprise/paid feature.
- **Open-source Cilium**: "Cilium-native multi-homing" (issue #20129, opened 2022) remains an open feature request with no merged implementation as of early 2026.
- **Cilium 1.19**: Focused on WireGuard encryption, mutual auth, and large-cluster observability. No secondary network features.

### Evaluation

| Criterion | Rating | Notes |
|---|---|---|
| Replaces Multus? | NO | Not a secondary network solution |
| VLAN bypass needed? | YES | Must configure `bpf.vlanBypass` for VLAN sub-interfaces |
| Future potential | Medium | Enterprise has it; OSS multi-homing is years away |

### Action Required

When implementing any VLAN approach, add to Cilium Helm values:
```yaml
bpf:
  vlanBypass:
    - 100  # Your VLAN IDs
    - 200
```

---

## Approach 4: Kube-OVN

### How It Works
Kube-OVN is a CNCF CNI built on OVN (Open Virtual Network) / OVS. It provides VLAN/underlay networking, IPAM, and subnet management.

### Cilium Integration: CNI CHAINING ONLY

Kube-OVN integrates with Cilium via CNI chaining (`generic-veth` mode), where Kube-OVN handles networking first and Cilium's eBPF programs attach afterward. This means **Kube-OVN replaces Cilium as the network plumber** -- Cilium only provides policy/observability on top.

This is fundamentally incompatible with your setup where Cilium is the primary CNI managing pod networking, Gateway API, and eBPF datapath.

### Talos Installation

Kube-OVN has official Talos installation docs. Key requirements:
- `DISABLE_MODULES_MANAGEMENT=true` (Talos manages kernel modules)
- Physical interfaces for underlay must be `ignore: true` in Talos config
- Logical interfaces (VLAN, Bond, Bridge) **cannot** serve as provider interfaces

### Evaluation

| Criterion | Rating | Notes |
|---|---|---|
| Talos compatibility | Documented | Official install guide exists |
| Cilium coexistence | PROBLEMATIC | Chaining mode = Kube-OVN becomes primary CNI |
| Complexity | HIGH | Full SDN stack (OVN controllers, OVS, databases) |
| As secondary CNI only | Not designed for this | Would need Multus anyway |
| Homelab value | LOW | Massive operational overhead for VLAN access |

### Strategic Assessment

Kube-OVN is a **full CNI replacement**, not a VLAN bolt-on. Using it alongside Cilium requires CNI chaining which fundamentally changes your network architecture. Known issues exist with VLAN tags being dropped in chaining mode (Cilium issue #41371). The operational complexity (OVN northbound/southbound databases, OVS per node, controller HA) far exceeds the benefit for a homelab VLAN use case.

**Recommendation**: Hard pass. This solves the wrong problem at 10x the complexity.

---

## Approach 5: SR-IOV

### Intel e1000e SR-IOV Support: NO

**The Intel I219/I218/I217 family (e1000e driver) does not support SR-IOV.** This is a hardware limitation, not a software one:

- SR-IOV requires dedicated hardware logic for Virtual Functions (VFs) in the NIC silicon
- The I219 is a low-power consumer/business gigabit controller designed for client platforms
- SR-IOV on Intel NICs requires server-class hardware: I350 (igb), X520/X540/X550 (ixgbe), E810 (ice), or newer
- The e1000e driver has no VF driver counterpart (igbvf exists for igb, not e1000e)

### Even If You Had SR-IOV Hardware

On a single-NIC setup, SR-IOV VFs share the physical port. VLAN tags can be assigned per-VF at the PF driver level, which is elegant. But you would lose the physical port for host networking unless you also use a VF for the host -- adding complexity.

### Evaluation

| Criterion | Rating | Notes |
|---|---|---|
| e1000e support | NOT POSSIBLE | Hardware does not support SR-IOV |
| Alternative | Buy a server NIC | Intel X550-T2 or Mellanox ConnectX-4+ |

**Recommendation**: Not viable with current hardware. If you ever add a second NIC (e.g., Intel X550-T2), SR-IOV becomes the performance king for VM networking.

---

## Approach 6: Macvtap

### How It Works
Macvtap creates a virtual network device that combines macvlan (MAC-based sub-interface) with a tap device (for QEMU/KubeVirt). VMs get direct L2 access to the physical network with their own MAC addresses, bypassing any bridge.

### Modes and Same-Host Communication

| Mode | VM-to-External | VM-to-VM (same host) | VM-to-Host |
|---|---|---|---|
| **Bridge** | Yes | Yes | NO (kernel limitation) |
| **VEPA** | Yes | Only with hairpin switch | NO |
| **Private** | Yes | NO | NO |

The `bridge` mode is the only viable option for KubeVirt, and even then, **VM-to-host communication does not work** (same limitation as macvlan in your existing ingress-front setup).

### Performance

Macvtap provides **10-50% better throughput and CPU efficiency** than software bridges in benchmarks. The kernel datapath is shorter -- no bridge forwarding table lookup, no STP.

### KubeVirt Integration

- Macvtap is an official KubeVirt network binding plugin
- Requires `macvtap-cni` + device plugin DaemonSet
- **No live migration support** (major KubeVirt limitation)
- Secondary networks only (cannot be primary pod network)
- No IPAM support

### VLAN with Macvtap

To use macvtap with VLANs, you would create a VLAN sub-interface first (`eth0.100`), then attach macvtap to it. The VM sees untagged traffic on the VLAN.

### Evaluation

| Criterion | Rating | Notes |
|---|---|---|
| Talos compatibility | Good | Kernel support present, CNI plugin via DaemonSet |
| Complexity | Low-Medium | Simpler than bridge, needs device plugin |
| VM-to-VM same-host | YES (bridge mode) | Works in macvtap bridge mode |
| VM-to-external VLAN | YES | Direct L2 access |
| VM-to-host | NO | Kernel limitation (same as macvlan) |
| Performance | Excellent | 10-50% better than bridge |
| Live migration | NO | Major limitation for production |
| KubeVirt support | Official | Binding plugin available |

### Strategic Assessment

Macvtap is the **performance-optimized alternative** to bridge. The trade-offs are: no live migration, no VM-to-host communication, and slightly less ecosystem maturity. For a homelab where live migration is not critical, macvtap is a strong contender -- but the VM-to-host limitation may bite you.

---

## Approach 7: IPVLAN L3

### Relevance to VLAN Use Case: NONE

IPVLAN L3 operates at Layer 3, not Layer 2. It:
- Does not support VLAN tagging (that is an L2 concept)
- Shares the parent interface's MAC address (no unique MAC per VM)
- Is explicitly **not supported by KubeVirt** (GitHub issue #7001 confirms ipvlan CNI is not supported)

### Evaluation

| Criterion | Rating | Notes |
|---|---|---|
| VLAN support | NO | L3 mode has no VLAN concept |
| KubeVirt support | NO | Explicitly unsupported |

**Recommendation**: Not applicable. IPVLAN L3 solves different problems (routing-based multi-tenancy).

---

## Approach 8: kubernetes-nmstate

### Talos Compatibility: INCOMPATIBLE

kubernetes-nmstate provides declarative host network configuration via Kubernetes CRDs. However, it has a **hard dependency on NetworkManager** running on nodes.

Talos Linux:
- Does not run NetworkManager
- Has no package manager to install it
- Manages all networking through its own machine config API and `networkd`
- Is fundamentally immutable -- no way to add system services

### What Talos Provides Instead

Talos's own machine config is already declarative and API-driven. You configure bridges, VLANs, bonds, and routes through `machine.network.interfaces` in the machine config, applied via `talosctl apply-config`. This is functionally equivalent to what kubernetes-nmstate does, just through a different API.

### Evaluation

| Criterion | Rating | Notes |
|---|---|---|
| Talos compatibility | INCOMPATIBLE | Requires NetworkManager |
| Alternative | Talos machine config | Already declarative, API-driven |

**Recommendation**: Use Talos machine config directly. It already provides declarative network configuration.

---

## Strategic Synthesis

### The Competitive Landscape (Viable Options Only)

Only three approaches are genuinely viable for your setup:

| Approach | Complexity | Performance | VM-VM | VM-External | VM-Host | Live Migration | Maturity |
|---|---|---|---|---|---|---|---|
| **1. Linux Bridge + VLAN** | Low | Good | Yes | Yes | Yes | Yes | Highest |
| **2. OVS** | High | Good-Excellent | Yes | Yes | Yes | Yes | High |
| **6. Macvtap** | Low-Medium | Excellent | Yes* | Yes | No | No | Medium |

*Bridge mode only

### Second-Order Effects Analysis

**If you choose Linux Bridge + VLAN (Approach 1):**
- Three moves ahead: This is the same pattern used by Harvester, OpenShift Virtualization, and most KubeVirt production deployments. Community support is maximal.
- When Talos merges #9117 (bridge port VLAN management), you can optionally simplify to a single trunk bridge. But the sub-interface approach works today without it.
- Cilium's `bpf.vlanBypass` is the only Cilium-side change needed.
- The bridge serves as a natural point for future traffic inspection, QoS, or monitoring.

**If you choose Macvtap (Approach 6):**
- The VM-to-host limitation means VMs on VLAN 100 cannot reach services running on the host (including host-networked pods). This is the exact same macvlan limitation you already deal with for ingress-front.
- No live migration means you cannot drain a node for maintenance without VM downtime. For a homelab this may be acceptable, but it constrains future growth.

**If you choose OVS (Approach 2):**
- The operational complexity creates a maintenance burden that scales with your cluster. Every Talos upgrade, every node addition requires verifying the OVS DaemonSet and configuration.
- OVS expertise is a specialized skill. Debugging network issues requires `ovs-vsctl`, `ovs-ofctl`, `ovs-dpctl` -- tools not in most Kubernetes operators' toolbox.

---

## Recommendation

### Primary: Linux Bridge + VLAN Sub-Interface (Approach 1)

**For a single-NIC Talos homelab, Linux Bridge + VLAN sub-interface is the clear winner.**

Rationale:
1. **Zero extensions required** -- everything is in the Talos kernel and machine config
2. **Lowest operational complexity** -- standard Linux networking, massive community knowledge base
3. **Full VM communication matrix** -- VM-to-VM, VM-to-external, and VM-to-host all work
4. **Live migration compatible** -- bridge binding supports KubeVirt live migration
5. **Battle-tested pattern** -- this is how Harvester (SUSE), OpenShift Virtualization (Red Hat), and most bare-metal KubeVirt deployments work
6. **Incremental** -- add one bridge per VLAN as needed; no upfront architectural commitment

### Implementation Sketch

1. **Talos machine config** (per node): Create VLAN sub-interface + bridge
2. **Cilium Helm**: Add `bpf.vlanBypass: [100, 200, ...]` for your VLAN IDs
3. **Multus NAD**: Define `NetworkAttachmentDefinition` per VLAN using bridge CNI
4. **KubeVirt VM spec**: Reference the NAD as a secondary network with bridge binding
5. **Upstream switch**: Configure the switch port as a trunk carrying your VLAN tags

### If Performance Becomes Critical Later

Add an Intel X550-T2 or Mellanox ConnectX-4 as a dedicated VM NIC. Then SR-IOV with per-VF VLAN tags becomes available -- the ultimate performance path. But this is a hardware investment, not a software decision.

---

## Sources

- [KubeVirt Interfaces and Networks](https://kubevirt.io/user-guide/network/interfaces_and_networks/)
- [KubeVirt Multiple Network Attachments with Bridge CNI](https://kubevirt.io/2020/Multiple-Network-Attachments-with-bridge-CNI.html)
- [Talos Multus CNI Guide](https://www.talos.dev/v1.9/kubernetes-guides/network/multus/)
- [Talos Bridge vlan_filtering Support (Issue #8941, MERGED)](https://github.com/siderolabs/talos/issues/8941)
- [Talos Bridge Port VLAN Management (Issue #9117, OPEN)](https://github.com/siderolabs/talos/issues/9117)
- [Talos OVS Discussion (#7793)](https://github.com/siderolabs/talos/discussions/7793)
- [Cilium VLAN 802.1q Documentation](https://docs.cilium.io/en/stable/configuration/vlan-802.1q/)
- [Cilium Native Multi-Homing (Issue #20129)](https://github.com/cilium/cilium/issues/20129)
- [Kube-OVN Talos Installation](https://kubeovn.github.io/docs/v1.14.x/en/start/talos-install/)
- [Kube-OVN + Cilium Integration](https://kubeovn.github.io/docs/stable/en/advance/with-cilium/)
- [KubeVirt Macvtap Binding](https://kubevirt.io/user-guide/network/net_binding_plugins/macvtap/)
- [macvtap-cni GitHub](https://github.com/kubevirt/macvtap-cni)
- [Intel e1000e Linux Base Driver](https://www.intel.com/content/www/us/en/support/articles/000005480/ethernet-products.html)
- [kubernetes-nmstate GitHub](https://github.com/nmstate/kubernetes-nmstate)
- [KubeVirt IPVLAN Not Supported (Issue #7001)](https://github.com/kubevirt/kubevirt/issues/7001)
- [KubeVirt Network Binding Plugins](https://kubevirt.io/user-guide/network/network_binding_plugins/)
- [Harvester Network Deep Dive](https://docs.harvesterhci.io/v1.6/networking/deep-dive/)
- [Macvtap vs Bridge Performance (Proxmox Forum)](https://forum.proxmox.com/threads/macvtap-as-future-replacement-of-classic-nic-bridge-tap-interfaces.72291/)
- [Macvtap Kernel Documentation](https://virt.kernelnewbies.org/MacVTap)
- [Macvtap Host-Guest Communication Limitation (Red Hat)](https://access.redhat.com/solutions/2041163)
