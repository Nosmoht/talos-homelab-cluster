# ADR: Pi as Sole Public-Ingress (WAN Entrypoint)

- **Status:** Accepted
- **Date:** 2026-04-17
- **Deciders:** Thomas
- **Supersedes:** [docs/adr-ingress-front-stable-mac.md](adr-ingress-front-stable-mac.md)
  (the macvlan-on-pod WAN path, scoped down to LAN-only)

## Context

The homelab exposes multiple publicly-accessible services (`*.homelab.ntbc.io`)
through a single WAN entrypoint. Until 2026-04-15, WAN ingress was attempted
via the `ingress-front` macvlan pod bound to a stable MAC + LAN VIP, with a
FritzBox port-forward aimed at that VIP.

On 2026-04-15 the macvlan WAN path was declared **structurally unsupported**
under FRITZ!OS ≥ 8.25. The exhaustion investigation
([docs/2026-04-15-fritzbox-macvlan-port-forward-exhaustion.md](2026-04-15-fritzbox-macvlan-port-forward-exhaustion.md))
cycled through three approved experiments (ARP suppression revert, non-VRRP
locally-administered MAC, `udhcpc` DHCP registration) — none of them delivered
inbound TCP/443 SYNs to the macvlan-pod VIP, while a diagnostic port-forward
pointed at a regular cluster node (`node-04`, hostNetwork Envoy) succeeded from
five external vantages immediately. The failure is specific to the combination
"FritzBox port-forward → macvlan-pod VIP", and is empirically unsolvable at the
macvlan layer. Community consensus predicted exactly this outcome.

Cloudflare-based alternatives (Tunnel / Access / Load Balancer) are excluded
by standing user policy (`feedback_no_cloudflare` memory). Sidero Metal / inlets
PRO / OPNsense DMZ were considered but rejected on cost/complexity grounds.

## Decision

Use **`node-pi-01`** (Raspberry Pi 4B, arm64) as the sole public-ingress
entrypoint. The FritzBox port-forwards TCP/443 directly to the Pi's primary NIC
(DHCP-reserved on a regular physical interface — no macvlan). A hostNetwork
nginx stream pod runs on the Pi, performs SNI allowlist filtering against
`*.homelab.ntbc.io`, and L4-proxies accepted connections to the Cilium Gateway
(hostNetwork Envoy) on the three gateway worker nodes via LAN.

### Architecture

```
Internet (TCP 443 only)
  -> FritzBox (port-forward TCP/443 → node-pi-01 NIC IP)
    -> node-pi-01 (hostNetwork nginx stream pod)
      -> SNI allowlist: *.homelab.ntbc.io
        -> L4 proxy → gateway nodes (hostNetwork Envoy on node-04/05/06)
          -> external-https listener (SNI = *.homelab.ntbc.io)
            -> HTTPRoutes from labelled namespaces (PNI capability
               `external-gateway-routes`)
```

The `ingress-front` macvlan pod continues to serve the LAN VIP for
`*.homelab.local` and `*.lan.homelab.ntbc.io` from trusted clients. WAN traffic
does not flow through it.

### Node Isolation

`node-pi-01` is dedicated to public-ingress. Scheduling is prevented by a
`homelab.io/pi-reserved=true:NoSchedule` taint; only DaemonSets with an
explicit toleration (Cilium, kube-multus-ds, alloy, loki-canary, node-exporter,
nfd-worker, tetragon) plus the `pi-public-ingress` pod itself may land on the
Pi. Kyverno ClusterPolicy `pi-reserved-daemonset-toleration` injects the
toleration into approved DaemonSets by name; wildcard-tolerating DaemonSets
(cilium, kube-multus-ds) bypass the policy by design.

### Hardened Security Posture (WAN-facing node)

The 5-commit hardening plan applied on 2026-04-17 locked down the Pi's WAN
posture before the FritzBox switch:

1. **Image digest pin**: `nginx:1.29.8-alpine@sha256:8aa63af0…` — fixes 3
   open stream-module CVEs.
2. **Non-root nginx + zero caps**: `runAsUser: 101`, `runAsGroup: 101`,
   `drop: [ALL]`. Binds :443 via Talos per-netns sysctl
   `net.ipv4.ip_unprivileged_port_start=443` (scoped to the Pi only, hostNet
   pods share the host netns).
3. **Talos `NetworkRuleConfig` default-deny ingress**: WAN-only lock — TCP/443
   from `0.0.0.0/0` + `::/0`; full TCP+UDP 1–65535 from the LAN CIDR only; all
   other ports (apid 50000, kubelet 10250, node-exporter 9100, Cilium random
   ports) are unreachable from outside the LAN subnet.
4. **Per-interface `net.ipv4.conf.<wan-nic>.rp_filter=2`** on the Pi's WAN NIC;
   global `default=0` preserved (Cilium BPF bypasses the kernel FIB and requires
   `default=0`).
5. **Gateway listener hostname filter**: `hostname: *.homelab.local` on the
   `https` listener (structural catch-all closed without breaking OIDC
   callbacks).

Gateway listener `external-https` remains hostname-bound to
`*.homelab.ntbc.io` with `from: Selector` gating via the PNI capability label
`platform.io/consume.external-gateway-routes=true`.

## Alternatives Considered

| Option | Verdict | Rationale |
|---|---|---|
| Stay on `ingress-front` macvlan WAN | Rejected | Structurally unsupported on FRITZ!OS ≥ 8.25 (see exhaustion report) |
| Cloudflare Tunnel / Access / LB | Excluded | Standing user policy (`feedback_no_cloudflare`) |
| Port-forward directly to a gateway worker node | Rejected as permanent | Empirically works (diagnostic probe on 2026-04-15), but single-node failure = WAN down and ties WAN to a general-purpose worker. Pi dedication gives better blast-radius isolation |
| Cilium L2 announcements for a public VIP across gateway nodes | Rejected | Unclear whether FritzBox NAT accepts leader-MAC GARP updates; would have required L2-announcement testing on the WAN path |
| Standalone mini-PC edge (Lenovo M920q / N100) outside the cluster | Deferred | ~€180–220 hardware plus separate config/GitOps surface. Pi-in-cluster wins on zero extra hardware and GitOps-uniform ops; re-evaluate if Pi capacity becomes a bottleneck |
| OPNsense DMZ / inlets PRO | Rejected | Hardware cost and/or recurring VPS + license cost outweigh benefits for current traffic profile |

## Consequences

### Accepted Trade-offs

- **Single-node WAN edge**: `node-pi-01` down = WAN down. Pi is intentionally
  cordoned to a minimal pod set (8 pods); upstream Cilium and DaemonSet noise
  are accepted operational overhead. Any Pi hardware/power/network event is a
  WAN incident.
- **Pi capacity ceiling**: Raspberry Pi 4B arm64 caps out well below worker-class
  throughput. Current traffic profile (small homelab, few external users,
  UI-first access patterns) is comfortably within Pi envelope; re-evaluate if
  traffic profile changes.
- **Kernel sysctl scoping**: `net.ipv4.ip_unprivileged_port_start=443` applies
  to the Pi's host netns. Any future hostNetwork pod scheduled on the Pi could
  technically bind 443–1023 non-root. Mitigated by the node taint + Kyverno
  scope; documented as a dormant risk in
  `project_pi_sole_public_ingress` memory.
- **Dual-path complexity**: WAN via Pi, LAN via ingress-front macvlan. Two
  parallel ingress paths must stay consistent; Gateway listener configuration
  and SNI semantics are shared, but nginx allow/deny maps live in two places
  (Pi pod + ingress-front pod).

### Benefits

- **Actually works**: empirically verified WAN path on 2026-04-17; FritzBox
  port-forward is live and external probes confirm TCP/443 open, TCP/6443 and
  TCP/50000 closed.
- **Dedicated security surface**: a WAN-facing node should host minimal
  unrelated state. Pi's 8-pod isolation achieves this better than a
  general-purpose worker edge.
- **Hardened by design**: digest pin, zero capabilities, default-deny ingress,
  Tetragon runtime observability co-located with the WAN entrypoint.
- **No new hardware / no recurring cost**: Pi was already in the cluster.
- **Macvlan pattern preserved**: the macvlan + stable-MAC pattern remains a
  valid **LAN-side** option (for other VIPs, tenant-sidecar patterns, or any
  scenario that does not cross the FritzBox NAT path). Only its WAN role is
  superseded.

## Verification

- `talos_read_file` on Pi: `/proc/sys/net/ipv4/ip_unprivileged_port_start` = 443;
  `/proc/sys/net/ipv4/conf/<wan-nic>/rp_filter` = 2.
- `kubectl -n public-ingress exec deploy/pi-public-ingress -- id` → `uid=101(nginx)`.
- `kubectl -n public-ingress exec deploy/pi-public-ingress -- grep CapEff /proc/1/status`
  → `0000000000000000`.
- Talos MachineConfig contains `NetworkDefaultActionConfig ingress: block` +
  three `NetworkRuleConfig` documents (wan-https, lan-tcp-all, lan-udp-all).
- External WAN probe (from a non-LAN vantage): TCP/443 succeeds; TCP/6443 and
  TCP/50000 closed.
- `kubectl get pods --field-selector spec.nodeName=node-pi-01 -A` → exactly the
  allowed 8-pod roster (cilium, kube-multus-ds, alloy, loki-canary,
  node-exporter, nfd-worker, tetragon, pi-public-ingress).

## Related

- [docs/2026-04-15-fritzbox-macvlan-port-forward-exhaustion.md](2026-04-15-fritzbox-macvlan-port-forward-exhaustion.md)
  — the exhaustion investigation that triggered this decision
- [docs/adr-ingress-front-stable-mac.md](adr-ingress-front-stable-mac.md) —
  the superseded ADR; macvlan + stable-MAC for LAN remains valid
- [docs/postmortem-gateway-403-hairpin.md](postmortem-gateway-403-hairpin.md)
  — internal eBPF / L7 filter reasoning remains valid for the LAN path
- GitHub hardening commits (2026-04-17 on `main`): C1 gateway listener hostname
  filter, C2 image digest pin, C4 Talos sysctls (ip_unprivileged_port_start,
  rp_filter), C3 non-root nginx + tuning, C5 NetworkRuleConfig WAN-only lock.
