# Fritzbox ↔ macvlan-Pod Port-Forward Exhaustion Report

**Date:** 2026-04-15
**Scope:** Public reachability of `*.homelab.ntbc.io`
**Outcome:** Phase 0 (macvlan-layer workarounds) exhausted. Structural fix required in a separate plan.
**Related plan:** `Plans/async-juggling-rossum.md` (gitignored)

---

## Executive Summary

The `ingress-front` macvlan Pod has been unreachable from the WAN since commit `93bc011` (2026-03-04) removed the Raspberry Pi edge node. Over the course of this session three plan-approved experiments (Test A: ARP-suppression revert, Test B: non-VRRP locally-administered MAC, Test C: `udhcpc` init container) were executed in sequence and later combined. Each run left the Fritzbox host table in the "expected correct" shape (active=True, proper IP↔MAC binding via DHCP reservation, clean port-forward rule) — yet **inbound TCP/443 SYN never reached the pod** in any configuration.

A diagnostic port-forward pointed at a real cluster node (`node-04`, hostNetwork Envoy) succeeded immediately from five external vantage points, proving the Fritzbox WAN chain, ISP path, and port-forward mechanism itself are intact. The failure is specific to the combination "Fritzbox port-forward → macvlan-pod VIP", empirically confirming the community consensus (*"MACVLAN und FritzBox: Besser NICHT machen!"*) that this intersection is structurally unsupported by FRITZ!OS 8.25.

Phase 0 is declared exhausted. A separate plan must pick a structural fix (port-forward to a gateway node, Cilium L2 announcements, hardware edge, OPNsense Exposed Host, or inlets PRO). Cloudflare is excluded by user policy.

---

## Environment Snapshot

| Component | Detail |
|---|---|
| Cluster | Talos Linux 1.12.6 / Kubernetes 1.35 / Cilium 1.19 (WireGuard strict, kube-proxy replacement, hostNetwork Envoy for Gateway API) |
| Router | FRITZ!Box 7590 AX, FRITZ!OS 8.25 |
| WAN | `91.106.144.38` (non-CGNAT, confirmed via TR-064 + external IP checker) |
| DNS | Google CloudDNS wildcard `*.homelab.ntbc.io` → WAN IP |
| Cert | cert-manager, Let's Encrypt Wildcard via DNS-01 (CloudDNS), `external-wildcard-tls` READY |
| Gateway | `homelab-gateway` with listeners `https` (no hostname, internal `*.homelab.local`) and `external-https` (hostname `*.homelab.ntbc.io`, selector-gated via `platform.io/consume.external-gateway-routes=true`) |
| `ingress-front` | Multus macvlan Pod, nginx:1.27-alpine, L4 SNI proxy, two VIPs on `enp0s31f6`: `net1`=`<internal-vip>` (internal listener), `net2`=`<public-vip>` (public listener, allow-map SNI `*.homelab.ntbc.io`) |
| DHCP range | `<dhcp-range>` (200–249) |
| LAN test host | `<lan-probe-host>` (macOS) accessible via `ssh thomaskrahn@<lan-probe-host>` |

---

## Problem Statement

Fritzbox accepts a port-forward rule `TCP/443 → <public-vip>:443` and shows it enabled + green. `GetSpecificHostEntryByIP(<public-vip>)` reports `NewActive=True` with the correct MAC binding. ICMP to the WAN IP succeeds from external. But inbound TCP/443 from any external node times out. `kubectl logs` on the pod shows zero new lines during external probes — the SYN never arrives.

---

## Pre-Work Research Findings

| Finding | Source |
|---|---|
| FRITZ!OS 8.25 changelog literal: *"Aktive Geräte mit statischen IP-Adressen wurden unter Umständen als inaktiv angezeigt und umgekehrt"* — identical to 8.20 | `download.avm.de/fritzbox/fritzbox-7590-ax/deutschland/fritz.os/info_de.txt` |
| TR-064 Hosts1 has no write action to pre-populate a host entry | AVM TR-064 Hosts spec |
| macvlan + Fritzbox + public port-forward is consistently flagged as fragile by the community, across firmware versions | Synology-Forum ("MACVLAN und FritzBox: Besser NICHT machen!"), ip-phone-forum.de, r/homelab |
| No Tier-1/Tier-2 documented workaround for this exact intersection | vendor + community search |
| VRRP OUI `00:00:5E:00:01:xx` handling by FRITZ!OS is officially undocumented (neither confirmed correct nor confirmed filtered) | AVM docs, forum threads |
| Commit `84650b0` introduced the `arp_ignore=1 / arp_announce=2` tuning-plugin sysctls; prior `dbf1f20` attempted the same via init-container but was reverted in `9813f5f` due to PSA `baseline` blocking `NET_ADMIN` | Git history |

Tunnel-alternative matrix evaluated (Cloudflare Tunnel, Tailscale Funnel, inlets PRO, frp, VPS+WireGuard+HAProxy): Cloudflare Tunnel would have been top recommendation but **excluded by user policy** — recorded as memory `feedback_no_cloudflare.md`.

---

## Phase 0 Timeline

### Pre-flight

- Nginx SNI-deny map on internal VIP listener confirmed: `*.homelab.ntbc.io` → `""` → L4 close. Regression gate usable.
- Pre-operation reviewers executed: `platform-reliability-reviewer` (verdict: APPROVE-WITH-CHANGES) and `talos-sre` (verdict: APPROVE-WITH-CHANGES). Both integrated into plan. No AGENTS.md §Hard Constraint violations.

### Test A — ARP suppression revert on both NADs

**Commit:** `d3ca9ae`
**Change:** removed `sysctl` stanza on both `net-attach-def.yaml` and `net-attach-def-public.yaml`, added `kubectl.kubernetes.io/restartedAt` to force Multus NAD re-read.

| Gate | Result |
|---|---|
| Pod Running after rollout | ✓ (~7 s) |
| ARP-distinct MACs from LAN host | ✓ (internal VIP ↔ MAC1, public VIP ↔ MAC2) |
| TR-064 `GetSpecificHostEntryByIP(<public-vip>).NewActive` | **True** (previously `False`) |
| LAN SNI matrix (4 combinations) | ✓ (internal/internal=200, internal/public=exit 35, public/public=404 Envoy, public/internal=exit 35) |
| External TCP/443 (5 nodes) | **Timeout** |
| Nginx log during external probes | No new entries — SYN never arrives |

**Partial success:** ARP suppression was a real blocker on the TR-064 active-flag promotion. **But the WAN path remained broken**, so Test A alone was insufficient.

### Diagnostic port-forward → node-04

Port-forward target temporarily switched in Fritzbox UI from `<public-vip>` to `<gateway-node-ip>` (node-04, hostNetwork Envoy on `:443`).

**External TCP/443 from 5 nodes:** CA 144 ms, CN 233 ms, MD 46 ms, RU 42 ms, UA 48 ms — **all successful TCP + TLS handshakes**.

**Conclusion:** Fritzbox WAN chain, ISP routing, NAT mechanism, and port-forward logic are 100% intact. The failure is specific to the Fritzbox ↔ macvlan-pod combination.

### Fritzbox state-corruption events and reboot

Between tests, multiple times the Fritzbox host table entered an inconsistent state:
- Duplicate entries for the same IP with different MACs (residue of ARP-flux windows during experiments)
- Ghost entries with MAC present but IP field empty, persistent with `active=True` even after pod removal
- UI save of filter-profile change failed with *"transaction fail"* — consistent with AVM-acknowledged state-table corruption in 8.25
- Deleted host entries re-populated within 1–2 minutes from Fritzbox internal MAC-learning cache while the pod kept announcing

**Resolution:** Fritzbox reboot to wipe the host cache. After reboot the host table was clean and the subsequent tests proceeded from a known baseline.

### Test A + C combined — udhcpc DHCP registration

**Commits:** `c02d11f` (initial, rejected by PSA), `f05df79` (PSA fix: removed explicit `NET_RAW` add, relies on runtime-default cap set), `211426d` (symmetric udhcpc for both interfaces).

**Intermediate problem:** first Test C variant set `securityContext.capabilities.add: ["NET_RAW"]` per talos-sre review suggestion. PSA baseline refuses admission with this — even though `NET_RAW` is in the runtime default cap set, explicit add is forbidden at baseline. Fix: omit `capabilities.add` entirely, preserve default caps via absence of `drop: ["ALL"]`.

**DHCP-reservation dance in Fritzbox UI:**
- MAC `00:00:5E:00:01:63` → IP `<public-vip>` with "always assign the same IPv4 address"
- MAC `02:42:C0:A8:02:46` → IP `<internal-vip>` (same)

**Scale-dance executed** (replicas 1 → 0 → 1) to give the operator ARP-silence windows for Fritzbox UI cleanup without re-learning flooding the state.

| Gate | Result |
|---|---|
| Pod Running after rollout | ✓ |
| `net1-dhcp-register` log | `udhcpc: lease of <internal-vip> obtained` ✓ |
| `net2-dhcp-register` log | `udhcpc: lease of <public-vip> obtained` ✓ |
| Fritzbox Hosts1: both IPs bound to correct MACs, `active=True`, clean names (`gateway-api-internal`, `gateway-api-external`) | ✓ |
| Port-forward rule enabled, targeting correct device | ✓ |
| External TCP/443 (5 nodes) | **Timeout** |
| Nginx log during external probes | No new entries |

**Conclusion:** Host registration mechanism (DHCP vs. manual UI) does not change the outcome. Even a "perfectly registered" macvlan-pod host is not a valid port-forward target.

### Test B — locally-administered MAC

**Commits:** `90c3074` (scale to 0), `06fb5ea` (MAC swap + scale to 1).

**Hypothesis:** IANA VRRP OUI `00:00:5E:00:01:xx` is specially filtered by FRITZ!OS NAT path.

**Setup:** swap `net2` MAC from `00:00:5E:00:01:63` to `02:42:C0:A8:02:63` (U/L bit set, Docker-style IP-derived suffix). Fritzbox old reservation deleted, new reservation for `02:42:C0:A8:02:63` → `<public-vip>` created, port-forward rule retargeted. All other Test A+C mechanisms (ARP suppression, udhcpc, DHCP reservation) unchanged.

| Gate | Result |
|---|---|
| Pod Running with new MAC | ✓ |
| Pod NAD status: `net2` MAC = `02:42:c0:a8:02:63` | ✓ |
| udhcpc lease `<public-vip>` obtained with new MAC | ✓ |
| Fritzbox Hosts1 active=True with new MAC | ✓ |
| Port-forward rule active | ✓ |
| External TCP/443 (5 nodes: IT, KZ, US, US, VN) | **Timeout** |
| Nginx log during external probes | No new entries |

**Conclusion:** VRRP OUI is NOT the cause. The Fritzbox treats both MAC classes identically — and identically fails to deliver to a macvlan-pod VIP.

---

## Proven-Working Reference Paths

| Path | Result |
|---|---|
| External → Fritzbox → `<gateway-node-ip>` (hostNetwork Envoy, real NIC, DHCP-learned) | ✅ 5/5 external nodes reach Envoy, SYN + TLS handshake complete |
| LAN host → pod `<public-vip>:443` (public SNI) | ✅ HTTP 404 from Envoy |
| LAN host → pod `<internal-vip>:443` (internal SNI) | ✅ HTTP 200 from ArgoCD |
| LAN host → pod `<public-vip>:443` with internal SNI | ✅ exit 35 (L4 SNI-deny by nginx allow-map) |
| LAN host → pod `<internal-vip>:443` with public SNI | ✅ exit 35 (L4 SNI-deny by nginx deny-map) |
| External → Fritzbox ICMP echo to WAN IP | ✅ AE 129 ms, FR 18 ms |

The internal LAN path and the real-NIC WAN path are both fully healthy. Only the macvlan WAN path fails.

---

## Root-Cause Verdict

**Fritzbox FRITZ!OS 8.25 does not deliver NAT'd inbound traffic to a macvlan-Pod VIP target, regardless of:**

- MAC OUI (IANA VRRP `00:00:5E` or locally-administered `02:42`)
- ARP discipline (`arp_ignore` / `arp_announce` sysctls on/off)
- Host registration path (manual "Gerät hinzufügen" UI entry, ARP-learning, or real DHCPv4 exchange via udhcpc)
- Fritzbox host-table state (`active=True`, correct IP↔MAC binding via DHCP reservation, unique non-duplicate entry, clean names)
- Port-forward target selection (targeting the correctly-registered device by name in UI)
- Fritzbox cache state (clean after reboot, no ghosts)

**This confirms the community consensus** that macvlan + Fritzbox + inbound port-forward is an unsupported intersection. AVM does not document a reason, and no Tier-1 / Tier-2 source describes a working configuration of this exact stack. Continuing to patch the macvlan-layer has negative ROI.

---

## Session Commit Log (main branch)

| SHA | Subject | Effect |
|---|---|---|
| `d3ca9ae` | `test(ingress-front): drop CNI tuning ARP sysctls on net1+net2 to expose Fritzbox host-table` | Test A executed |
| `00047f6` | `test(ingress-front): scale deployment to 0 to quiesce LAN ARP before Fritzbox state cleanup` | ARP silence |
| `c02d11f` | `fix(ingress-front): DHCP-register net2 MAC with Fritzbox + restore ARP suppression` | Test A+C initial (rejected by PSA) |
| `f05df79` | `fix(ingress-front): drop explicit NET_RAW add to pass PSA baseline admission` | PSA fix |
| `211426d` | `fix(ingress-front): DHCP-register both net1 and net2 MACs symmetrically` | Symmetric udhcpc |
| `04a122e` | `test(ingress-front): scale to 0 again to quiesce ARP for Fritzbox cleanup` | ARP silence |
| `90c3074` | `test(ingress-front): scale to 0 for Test B (VRRP vMAC swap to locally-administered MAC)` | Pre-Test-B ARP silence |
| `06fb5ea` | `test(ingress-front): swap net2 MAC from IANA VRRP OUI to locally-administered` | Test B executed |

All commits scoped-conventional per AGENTS.md.

---

## Reviewer Evidence

| Reviewer | Verdict | Key Findings (integrated) |
|---|---|---|
| `platform-reliability-reviewer` (pre-operation) | APPROVE-WITH-CHANGES | Multus-on-init initially unverified (confirmed later); SNI-deny pre-flight; replace `ports.yougetsignal.com` with `curl -v` + check-host.net; Test B rollback must include old-device-entry deletion; `Recreate` gap acknowledgement; Phase 0 exhaustion needs evidence capture; A↔B attribution caveat |
| `talos-sre` | APPROVE-WITH-CHANGES | Attribution correction (sysctls from `84650b0`, not `dbf1f20`); Test A must revert both NADs symmetrically; Test B must also update pod annotation MAC not only NAD; Test C must use `udhcpc -s /bin/true -n -q -f` with NET_RAW only (PSA); Multus doesn't hot-reload NADs → `restartedAt` bump required on every NAD edit |

No AGENTS.md §Hard Constraint violations across the session.

---

## Current Post-Session State

- Pod running with **Test B configuration**: locally-administered MAC `02:42:C0:A8:02:63` on `net2`, DHCP-reservation-registered, udhcpc active, ARP-suppression on both NADs.
- Fritzbox has two permanent DHCP reservations for the pod's MACs.
- Port-forward `TCP/443 → <public-vip>` exists and is enabled, but functionally dead.
- **Internal LAN path via `<internal-vip>` is fully healthy** — `*.homelab.local` traffic is unaffected throughout.
- Cert `external-wildcard-tls` remains READY (no external traffic = no real use yet, but chain is production-valid).
- Memory entry `feedback_no_cloudflare.md` saved to durable memory.
- Plan `Plans/async-juggling-rossum.md` approved and executed; handoff criteria met (TR-064 transcripts, pod logs, external probe output, nginx log absence captured in this report).

---

## Structural Fix Options (for a separate plan)

**Excluded by user policy:** Cloudflare Tunnel, Cloudflare Access, Cloudflare Load Balancer.

| Option | Cost | HA | Effort | Notes |
|---|---|---|---|---|
| Port-forward → one gateway node (e.g., `<gateway-node-ip>`) | €0 | No — single-node failure = WAN down | Minimal (UI change) | Empirically proven today. Zero new infrastructure |
| Cilium L2 announcements for `<public-vip>` across gateway nodes | €0 | Yes (leader election + GARP) | Small (Helm values + policy) | Unclear whether Fritzbox NAT accepts leader-MAC GARP updates — must be tested to de-risk |
| Used Lenovo M920q or N100 mini-PC as standalone edge (outside cluster) | ~€180–220 one-time | Single edge, but blast-radius-isolated | Medium (Talos/Debian setup + HAProxy/nginx config in git) | Best blast-radius profile. Community-documented pattern |
| OPNsense as Fritzbox "Exposed Host" (DMZ) | ~€150 used hardware | Depends on OPNsense deployment | Medium–high | Eliminates Fritzbox NAT-delivery bug class entirely |
| inlets PRO | $5/month VPS + commercial license (~$20/month) | Yes (redundant tunnel clients) | Small | Preserves E2E TLS. Operational VPS overhead |

Additionally, the current `ingress-front` pod can either:
- Remain as-is (internal VIP still serves `*.homelab.local` correctly)
- Be trimmed to internal-only (remove `net2`/public NAD + SNI-allow map in `nginx.conf`)
- Be retired entirely if the chosen structural fix covers both public and internal paths

---

## Lessons Captured

1. **Community warnings about unsupported stacks are load-bearing evidence.** The Synology-Forum thread ("MACVLAN und FritzBox: Besser NICHT machen!") predicted exactly this outcome. When a Tier-3 consensus aligns across multiple forums and no Tier-1/Tier-2 source documents a working config, the intersection is probably unsupported.
2. **AVM acknowledges bug classes in changelogs but does not always document severity or scope.** The 8.20/8.25 line about static-IP active-flag inversion described the symptom but hid the downstream effect (port-forward delivery refusal).
3. **Fritzbox host-table state corruption is real, persistent, and often uncurable via UI.** A reboot was the only way to guarantee a clean baseline.
4. **PSA baseline forbids explicit `NET_RAW` add even though NET_RAW is in the runtime default cap set.** For tooling that needs raw sockets (udhcpc, ping, arping) under PSA baseline, omit `capabilities.add` and rely on the runtime default; do not `drop: ["ALL"]` either.
5. **Multus does not hot-reload NetworkAttachmentDefinitions.** Every NAD change requires a pod-template annotation bump (e.g., `kubectl.kubernetes.io/restartedAt`) to trigger rollout; committing only the NAD leaves existing pods on the old config indefinitely.
6. **Four iterations of macvlan ARP/MAC patching prior to this session were negative-ROI.** The root cause was never in the macvlan layer. Earlier escalation to a structural plan would have saved iterations.
7. **Scale-to-0 is the right quiescence primitive** for LAN state cleanup when a running pod is faster at re-announcing than the operator is at UI deletion. Commit-driven scaling through git preserves GitOps discipline.

---

## Epilogue — Chosen Structural Fix (2026-04-17)

**Decision:** `node-pi-01` (Raspberry Pi 4B, arm64) as sole public-ingress
entrypoint. FritzBox port-forward retargeted from the old macvlan VIP to the
Pi's regular DHCP-reserved NIC IP. No macvlan in the WAN path.

This is a hybrid of the "Used Lenovo M920q / N100 mini-PC as standalone edge"
and "Port-forward to one gateway node" options from the §Structural Fix Options
table — the Pi is inside the cluster (so GitOps ops stay uniform) but runs a
dedicated hostNetwork nginx stream pod that is structurally equivalent to a
standalone edge: no macvlan, no shared workload noise, taint-isolated to a
minimal 8-pod set. Diagnostic on 2026-04-15 had empirically confirmed the
hostNetwork-on-cluster-node path works end-to-end through the FritzBox.

**Date live:** 2026-04-17. FritzBox port-forward active immediately after the
5-commit security hardening plan landed (digest pin, non-root nginx, Talos
NetworkRuleConfig default-deny, per-NIC `rp_filter=2`, per-netns
`ip_unprivileged_port_start=443`).

**Verification (WAN-side, non-LAN vantage):**

| Port | Expected | Actual |
|---|---|---|
| TCP/443 | open | ✓ open |
| TCP/6443 | closed (Kubernetes API must not be WAN-reachable) | ✓ closed |
| TCP/50000 | closed (Talos apid must not be WAN-reachable) | ✓ closed |

**State of the `ingress-front` macvlan pod:** Retained for the **LAN path only**.
Serves `*.homelab.local` and `*.lan.homelab.ntbc.io` from trusted LAN clients
via the internal VIP. The public-VIP (`net2`) allow-map in `nginx.conf` and the
`net2` NetworkAttachmentDefinition can be retired in a follow-up change; they
are dormant but harmless today.

**References:**

- [docs/adr-pi-sole-public-ingress.md](adr-pi-sole-public-ingress.md) — ADR
  documenting the decision, alternatives, and consequences in full
- [docs/adr-ingress-front-stable-mac.md](adr-ingress-front-stable-mac.md) —
  the superseded macvlan-WAN ADR (remains valid for the LAN role)
- GitHub commits (all on `main`, 2026-04-17):
  - Gateway listener hostname filter on `https` (structural catch-all closure)
  - nginx image digest pin + version label
  - Talos `pi-firewall.yaml` (sysctls + NetworkRuleConfig documents)
  - pi-public-ingress non-root securityContext + nginx.conf tuning
  - Talos NetworkRuleConfig default-deny ingress + WAN-only lock
