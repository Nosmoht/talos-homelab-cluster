# ADR: Ingress Front — Stable MAC Address for FritzBox Port Forwarding

- **Status:** Superseded by [docs/adr-pi-sole-public-ingress.md](adr-pi-sole-public-ingress.md) on 2026-04-17
- **Date:** 2026-03-28
- **Deciders:** Thomas

> **Superseded 2026-04-17.** The macvlan-on-pod approach documented below was
> proven **structurally unsupported as a WAN port-forward target** under
> FRITZ!OS ≥ 8.25 during the 2026-04-15 exhaustion investigation
> ([docs/2026-04-15-fritzbox-macvlan-port-forward-exhaustion.md](2026-04-15-fritzbox-macvlan-port-forward-exhaustion.md)).
> Even with a stable MAC, correct DHCP registration, and clean host-table state,
> inbound TCP/443 SYNs never reach a macvlan-pod VIP through the FritzBox NAT
> path — community consensus *"MACVLAN und FritzBox: Besser NICHT machen!"*
> was empirically confirmed.
>
> The current WAN architecture uses `node-pi-01` as a dedicated hostNetwork
> public-ingress node; the FritzBox port-forwards directly to the Pi's regular
> DHCP-reserved NIC, bypassing macvlan entirely. See the superseding ADR for
> details.
>
> **The `ingress-front` macvlan pod itself remains deployed** and still serves
> the LAN ingress VIP (`*.homelab.local` and `*.lan.homelab.ntbc.io` from
> trusted LAN clients). The stable-MAC reasoning, routing constraints, and
> node-portability properties below continue to apply to that LAN-only role.

## Context

All homelab UI services (ArgoCD, Grafana, Prometheus, Alertmanager, Vault, Dex) need external access from the internet via FritzBox port forwarding. Since FritzOS 8.20, the FritzBox binds port forwarding rules to a device identified by its MAC address.

The previous setup used Cilium L2 announcements to advertise the gateway VIP (192.168.2.70). The announcing node responds to ARP requests with its own physical NIC MAC. On node failover, a different node takes over and responds with a different MAC address. This causes:

- **Stale ARP cache:** The FritzBox caches ARP entries for 15-20 minutes (not configurable). During this window, traffic is blackholed to the old node.
- **Duplicate device entries:** The FritzBox may create a new device entry when it sees the same IP with a different MAC, orphaning the port forwarding rule from the original device.
- **Unreliable port forwarding:** Manual re-binding in the FritzBox UI is required after each failover.

Additionally, three services (Dex, Prometheus oauth2-proxy, Alertmanager oauth2-proxy) used separate LoadBalancer IPs (192.168.2.131/133/134) despite already having HTTPRoutes through the gateway — unnecessary complexity and more IPs to manage.

## Decision

Deploy a dedicated "ingress-front" pod with a Multus macvlan secondary network interface carrying a **static MAC address** (`02:42:c0:a8:02:46`) and **static IP** (`192.168.2.70`). This pod runs nginx in L4 stream mode, forwarding TCP traffic on ports 80 and 443 to the Cilium Gateway API service. All UI services are consolidated behind HTTPRoutes on the single gateway.

### Architecture

```
Internet
  → FritzBox (port forward 443 → MAC 02:42:c0:a8:02:46 / IP 192.168.2.70)
    → macvlan net1 interface on ingress-front pod (stable MAC + IP)
      → nginx L4 stream proxy
        → pod eth0 (Cilium CNI) → Cilium Gateway Service (ClusterIP)
          → Cilium Envoy → HTTPRoutes → backend services
```

### NIC Naming

The macvlan CNI `master` field is intentionally omitted. The macvlan plugin defaults to the default route interface, which automatically selects the correct active NIC on any node:
- Standard nodes (node-01..06): `enp0s31f6` (Intel e1000e)
- GPU node (node-gpu-01): `enp0s20f0u2` (Realtek RTL8153 USB)

`net.ifnames=0` was evaluated and rejected — on node-gpu-01, the inactive PCIe NIC (RTL8136, `enp4s0`) would claim `eth0` because PCI bus scanning completes before USB hub enumeration. Legacy `ethX` naming is non-deterministic per kernel documentation.

### MAC Address

`02:42:c0:a8:02:46` is in the locally administered range (`02:xx` prefix). The last four bytes encode the IP address `192.168.2.70` (`c0:a8 = 192.168`, `02:46 = 2.70`).

## Alternatives Considered

1. **Cilium L2 announcements only** — Rejected. The announcing node's MAC changes on failover, breaking FritzBox port forwarding.

2. **Static MAC on Talos node interface** — Rejected. Ties the VIP to a specific node, losing failover capability. If the node goes down, the IP becomes unreachable.

3. **MetalLB with static MAC support** — Rejected. The cluster uses Cilium-native L2 announcements; adding MetalLB introduces redundant complexity and potential conflicts.

4. **`net.ifnames=0` kernel parameter** — Rejected. Would assign `eth0` to the inactive PCIe NIC on node-gpu-01, not the active USB NIC. Non-deterministic across reboots per kernel documentation.

## Consequences

### Accepted Trade-offs

- **Macvlan bypasses Cilium eBPF:** Traffic arriving on the macvlan net1 interface does not traverse Cilium's datapath. No CiliumNetworkPolicy enforcement on ingress, no Hubble visibility. The nginx config is the sole access control. Debugging requires `kubectl exec <pod> -- tcpdump -i net1`.

- **No client IP preservation:** The L4 proxy hop means backend services see the nginx pod IP, not the real client IP. PROXY protocol can be enabled later if needed (requires coordinated change in nginx config + Cilium `enable-gateway-api-proxy-protocol`).

- **Single replica:** Two replicas with the same MAC+IP on different nodes would cause Layer 2 MAC flapping at the switch level. A single replica with fast restart (~10-15s) is the correct trade-off for a homelab.

- **Macvlan bridge mode host isolation:** The node running ingress-front cannot reach `192.168.2.70` from its own host network context. All other LAN clients work fine.

### Benefits

- **Stable MAC for FritzBox:** Port forwarding binds to `02:42:c0:a8:02:46` and survives pod rescheduling across any node.
- **Single IP for all services:** All UI services accessible via `192.168.2.70` through HTTPRoutes — no separate LoadBalancer IPs needed.
- **No kernel/boot changes:** Works with current Talos configuration, no rolling upgrades required.
- **Node-portable:** Pod can schedule on any node; macvlan auto-selects the active NIC via default route.
