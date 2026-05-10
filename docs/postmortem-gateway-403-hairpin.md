# Postmortem: Gateway API 403 "Access Denied" — The Full Story

**Date:** 2026-03-28 to 2026-03-29
**Duration:** ~10 hours of investigation and implementation
**Impact:** All external ingress via Gateway API returned HTTP 403
**Resolution:** Embedded Envoy hostNetwork mode + macvlan L2 proxy bypass

---

> **Update 2026-04-17.** The **WAN path described in this postmortem is
> superseded**. Since 2026-04-17, WAN ingress arrives at `node-pi-01`
> (hostNetwork nginx stream), not through the `ingress-front` macvlan pod —
> see [docs/adr-pi-sole-public-ingress.md](adr-pi-sole-public-ingress.md) and
> [docs/2026-04-15-fritzbox-macvlan-port-forward-exhaustion.md](2026-04-15-fritzbox-macvlan-port-forward-exhaustion.md).
> The **internal reasoning remains valid**: the `cilium.l7policy` filter
> behaviour, embedded Envoy architecture, `NET_BIND_SERVICE` requirement,
> extraManifests-no-GC, and macvlan bridge-isolation findings are all still
> correct and still apply to the LAN path (ingress-front macvlan → gateway
> nodes) and to anyone reading this for Cilium Gateway API internals. Only
> the specific "Final Architecture" diagram below and the FritzBox port-forward
> target are now historical — inline markers below call out the specific
> paragraphs.

---

## The Problem

After introducing an `ingress-front` nginx L4 proxy with Multus macvlan (stable MAC for router port forwarding), all external traffic through the Cilium Gateway API returned **HTTP 403 "Access denied"**. Every single service — ArgoCD, Grafana, Prometheus, Alertmanager, Vault, Dex — was unreachable from outside the cluster.

The traffic path was:

```
FritzBox (port forward 443 -> MAC 02:42:c0:a8:02:46 / IP 192.168.2.70)
  -> macvlan net1 on ingress-front pod
    -> nginx L4 stream proxy (via pod eth0, Cilium CNI)
      -> Gateway Service ClusterIP (10.109.250.84)
        -> eBPF TPROXY redirect -> embedded cilium-envoy
          -> cilium.l7policy filter -> DENIED (403)
```

The `cilium-dbg monitor -t l7` output confirmed:

```
-> Request http from 3237 ([reserved:ingress]) to 0 ([cidr:10.0.0.0/8 reserved:world]),
   identity 8->16777220, verdict Denied
   GET https://kb.homelab.local/healthz => 0
```

---

## Why It Happened

### The Identity Transformation

Cilium's Gateway API implementation uses an L7 Load Balancer proxy for all traffic destined to a Gateway Service ClusterIP. The eBPF datapath marks the service entry with an `l7-load-balancer` flag and redirects traffic via TPROXY to the local cilium-envoy process.

All traffic passing through this proxy gets **identity-transformed** to `reserved:ingress` (identity 8). This is by design (Cilium CFP #24536): Gateway/Ingress listeners should see a unified ingress identity regardless of the traffic source.

The `cilium.l7policy` Envoy filter then evaluates policy based on this identity. The filter denied the request because `reserved:ingress` attempting to reach the backend had no explicit allow — and the filter applies **implicit default-deny** that is completely independent of CiliumNetworkPolicy or CiliumClusterwideNetworkPolicy.

### Why Internal Test Pods Worked But ingress-front Didn't

Test pods (without any CiliumNetworkPolicy) also had their traffic redirected through the L7 LB proxy when targeting the Gateway ClusterIP. However, test pods consistently received 200 OK. The exact mechanism difference was never fully explained — it may relate to how eBPF metadata propagates differently for pods with vs. without CNP egress rules, or to timing/caching of the policy filter state.

---

## What We Tried (All Failed)

### Attempt 1: Remove toPorts from toServices in CNP

**Theory:** The `toPorts` on `toServices` triggers L7 proxy interception.
**Result:** 403. The L7 LB proxy is set by the Gateway Service's BPF flag, not by CNP rules.

### Attempt 2: Remove ALL CNPs and CCNPs

**Theory:** Some network policy is blocking the traffic.
**Result:** 403. The `cilium.l7policy` filter has its own implicit deny, independent of endpoint BPF policy maps.

### Attempt 3: Add CCNP for reserved:ingress Identity

**Theory:** Explicitly allow the `reserved:ingress` identity to reach backends.
**Result:** 403. The L7 filter's policy evaluation is separate from endpoint BPF policy maps. The CCNP was marked as ineffective in Issue.md and later removed.

### Attempt 4: Restart Cilium Agent + Envoy DaemonSet

**Theory:** Stale state causing the denial.
**Result:** 403. Not stale state — the behavior is architectural.

### Attempt 5: Enable gateway-api-hostnetwork-enabled with external-envoy-proxy: true

**Theory:** hostNetwork mode would bypass the TPROXY redirect.
**Result:** Gateway `Programmed: False`. The `gateway-api-hostnetwork-enabled` option is **incompatible with `external-envoy-proxy: true`** (shared DaemonSet mode). With the shared DaemonSet, the Gateway listener disappeared entirely.

---

## The Three-Agent Review

We ran three specialized review agents (platform-reliability-reviewer, gitops-operator, talos-sre) against the last 10 commits. They found 30+ issues across the codebase, but many recommendations were based on incorrect assumptions about the root cause. Key corrections:

- The `reserved:ingress` CCNP was ineffective (agents recommended tightening it)
- Removing/adding `toPorts` doesn't matter (agents thought it did)
- The 403 is architectural, not a policy misconfiguration

However, the reviews identified valid cleanup items: orphaned L2 resources, missing toPorts on monitoring-scrape CCNP, CiliumLoadBalancerIPPool without L2 announcement, and more.

---

## The Solution Journey

### Phase 1: Switch to Embedded Envoy with hostNetwork (Partial Fix)

**Change:** Set `envoy.enabled: false` + `gatewayAPI.hostNetwork.enabled: true` in Cilium Helm values.

**What we learned:**
- "Per-Gateway Deployments" **do not exist** in Cilium 1.19. This was a major misconception in all our planning. The Cilium operator creates exactly three objects per Gateway: a Service, an EndpointSlice, and a CiliumEnvoyConfig. No Deployment.
- With `envoy.enabled: false`, Envoy runs **embedded inside cilium-agent** (not as a separate DaemonSet). The CiliumEnvoyConfig has a `nodeSelector` field populated from the Helm values, and matching agents open Gateway listeners on their embedded Envoy.
- The `gateway-api-hostnetwork-enabled: true` flag tells the operator to set listener addresses to `0.0.0.0:80/443` (hostNetwork binding) and create a ClusterIP Service instead of LoadBalancer.

### Phase 1 — Error 1: ConfigMap Not Updated

After `make -C talos upgrade-k8s`, the Cilium ConfigMap still showed the old values. **Root cause:** We pushed the new `cilium.yaml` to GitHub and bumped the cache-bust URL in `controlplane.yaml`, but forgot to **apply the new Talos config to the control plane nodes** (`talosctl apply-config`). The nodes still had the old URL (`?v=1.19.2-2`).

**Fix:** Apply new configs to all 3 CP nodes first, then re-run `upgrade-k8s`.

### Phase 1 — Error 2: Orphaned cilium-envoy DaemonSet

After removing the shared Envoy DaemonSet from the rendered manifest, `upgrade-k8s` did NOT delete it. **Root cause:** Talos `extraManifests` only applies/updates resources in the manifest — it does **not** garbage-collect resources that were removed.

**Fix:** Manually `kubectl delete` the orphaned DaemonSet, Service, ServiceAccount, and ConfigMap.

### Phase 1 — Error 3: Ports 80/443 Not Bound

After the Cilium ConfigMap was updated correctly, the embedded Envoy still wasn't listening on ports 80/443. The CiliumEnvoyConfig specified `0.0.0.0:80/443`, but no sockets were actually opened.

**Root cause:** Two missing capabilities:
1. `NET_BIND_SERVICE` was not in `securityContext.capabilities.ciliumAgent` — the container couldn't bind privileged ports
2. `envoy-keep-cap-netbindservice` was `"false"` — even if the container had the capability, the embedded Envoy process dropped it

**Fix:** Add `NET_BIND_SERVICE` to ciliumAgent capabilities and set `envoy.securityContext.capabilities.keepCapNetBindService: true`.

**Verification:** `kubectl exec cilium-agent -- ss -tlnp | grep ':80\|:443'` showed Envoy listening on `0.0.0.0:80` and `0.0.0.0:443` inside the agent pod (which runs with hostNetwork).

### Phase 1 Result: Direct Node Access Works

After fixing the capabilities, curling `https://argocd.homelab.local` via any worker node's LAN IP (192.168.2.64-66) returned 200 with the ArgoCD HTML page. **No 403.** The external traffic arrived at the host network socket directly, without going through the eBPF TPROXY path.

---

### Phase 2: Connect ingress-front to the New Envoy (Multiple Failed Attempts)

The ingress-front nginx needed to proxy to the new Envoy on host ports. This turned out to be much harder than expected.

### Phase 2 — Error 4: $HOST_IP via eth0 Hit by L7 Filter

**Attempt:** Change nginx `proxy_pass` from Gateway ClusterIP to `$HOST_IP:443` (the node's LAN IP, injected via `status.hostIP` downward API).

**Problem 1:** The ConfigMap is mounted as a `subPath` volume (read-only). `sed -i` to substitute the placeholder failed with "Permission denied".

**Fix:** Init container + emptyDir pattern — copy ConfigMap template to writable emptyDir, sed there, mount emptyDir in main container.

**Problem 2:** Traffic to `$HOST_IP` (192.168.2.66) from the pod went through **net1 (macvlan)** because the route table had `192.168.2.0/24 dev net1`. Macvlan bridge mode blocks communication between a pod and its own host. Result: "Host is unreachable".

**Attempt to fix:** Add `NET_ADMIN` capability to the nginx container to add a `/32` host route via eth0.

**Problem 3:** `NET_ADMIN` violates the `baseline` Pod Security Admission policy on the `default` namespace. Pod creation forbidden.

**Next attempt:** Use the Cilium host-side endpoint IP (eth0 default gateway, `10.244.x.y`) as the proxy target. This routes via eth0, bypassing the macvlan route.

**Problem 4:** Traffic via eth0 goes through the eBPF datapath. The eBPF marks the traffic with the ingress-front pod's identity. The embedded Envoy receives the traffic and the `cilium.l7policy` filter sees identity-marked traffic — **same 403 as before**.

**Key discovery:** The `cilium.l7policy` filter applies to ALL traffic that arrives with eBPF identity metadata. It doesn't matter if the traffic is TPROXY-redirected or arrives directly at the host socket. Only external LAN traffic (no eBPF identity marking) bypasses the filter. This is why `curl` from a laptop on the LAN works (no identity) but traffic from a pod doesn't (identity-marked by eBPF).

### Phase 2 — The Working Solution: Macvlan to Remote Nodes

**Insight:** Macvlan bridge mode prevents communication with the **same host** but works fine for **remote hosts** on the LAN. If ingress-front sends traffic via net1 (macvlan) to a **different** worker node's LAN IP, the traffic arrives at that node as external LAN traffic — no eBPF, no identity marking, no L7 filter.

**Implementation:**
```nginx
stream {
    upstream gateway_http {
        server 192.168.2.64:80;
        server 192.168.2.65:80;
        server 192.168.2.66:80;
    }
    upstream gateway_https {
        server 192.168.2.64:443;
        server 192.168.2.65:443;
        server 192.168.2.66:443;
    }
    server {
        listen 192.168.2.70:80;
        proxy_pass gateway_http;
    }
    server {
        listen 192.168.2.70:443;
        proxy_pass gateway_https;
    }
}
```

All three worker node LAN IPs are in the upstream. The local node's IP fails silently (macvlan bridge isolation), and nginx upstream automatically fails over to one of the two remote nodes. Result: 2 of 3 nodes always reachable, automatic failover, no eBPF in the path.

**No init container needed** — the config is static (worker IPs don't change).
**No nodeSelector needed** — the pod can run on any node; it always proxies to remote nodes via macvlan.
**No CNP egress rule needed** — macvlan traffic bypasses Cilium entirely; only DNS egress (via eth0) needs a CNP rule.

---

## Final Architecture

> **[SUPERSEDED 2026-04-17 — see [docs/adr-pi-sole-public-ingress.md](adr-pi-sole-public-ingress.md).]**
> The WAN path below no longer applies. Since 2026-04-17 the FritzBox
> port-forwards TCP/443 directly to `node-pi-01` (hostNetwork nginx stream),
> which L4-proxies to the gateway nodes. The inner reasoning (external LAN
> traffic bypasses the `cilium.l7policy` filter) still explains why the
> gateway-node-hostNetwork-Envoy step works regardless of upstream ingress
> choice. For the LAN ingress path (internal clients → `ingress-front`
> macvlan → gateway nodes) the diagram below is still accurate.

```
Internet
  -> Router (port forward 443 -> MAC 02:42:c0:a8:02:46 / IP 192.168.2.70)
    -> macvlan net1 on ingress-front pod (stable L2 identity)
      -> nginx L4 stream proxy
        -> via net1 (macvlan) to remote worker node LAN IP:443
          -> arrives as external LAN traffic (no eBPF identity marking)
            -> embedded Envoy on hostNetwork (cilium-agent)
              -> cilium.l7policy filter PASSES (no identity metadata)
                -> HTTPRoutes -> backend services
```

**Internal traffic** (pod-to-pod via Gateway ClusterIP): Still uses TPROXY via eBPF. The `cilium.l7policy` filter behavior for internal pod traffic was not changed — test pods without CNPs still get 200 OK. Only the external ingress path was fixed.

---

## What We Got Wrong

### 1. "Per-Gateway Deployments" Don't Exist

Every planning document, the Issue.md, the migration plan, and three review agents all assumed Cilium creates per-Gateway Envoy Deployments when switching to hostNetwork mode. **This is wrong.** In Cilium 1.19, the Gateway API operator creates a CiliumEnvoyConfig with nodeSelector. The embedded Envoy in matching cilium-agent pods processes the Gateway listeners. There is no separate Deployment.

This misconception came from Cilium documentation and discussions that mention "per-Gateway" mode as an alternative to the shared DaemonSet. The distinction is real, but it's about which Envoy process handles the listener (shared DaemonSet vs. embedded in agent), not about creating a separate Deployment.

### 2. The L7 Filter Applies to All eBPF-Marked Traffic

We assumed the `cilium.l7policy` filter was specific to TPROXY-redirected traffic. **Wrong.** The filter applies to all traffic that carries Cilium identity metadata in the eBPF socket buffer. Any traffic originating from a pod and going through the Cilium CNI (eth0) gets identity-marked. Only traffic that enters the node via the physical NIC (external LAN traffic) is unmarked.

This is why:
- `curl` from a laptop (LAN) to `node-04:443` → 200 OK (no identity)
- `curl` from a pod (eth0) to `node-04:443` → 403 denied (identity-marked)
- `curl` from a pod (net1/macvlan) to `remote-node:443` → 200 OK (no eBPF on macvlan)

### 3. NET_BIND_SERVICE Is Required for Embedded Envoy

The Cilium Helm chart doesn't include `NET_BIND_SERVICE` in the default ciliumAgent capabilities. When `gatewayAPI.hostNetwork.enabled: true` tells the Envoy to bind on `0.0.0.0:80/443`, the bind silently fails without the capability. Additionally, `envoy.securityContext.capabilities.keepCapNetBindService` must be `true` or the embedded Envoy drops the capability even if the container has it.

### 4. Talos extraManifests Doesn't Garbage-Collect

When resources are removed from the rendered Cilium manifest (e.g., the cilium-envoy DaemonSet), `talosctl upgrade-k8s` does NOT delete them from the cluster. They become orphans. This caught us off guard and required manual cleanup.

### 5. Macvlan Bridge Isolation Blocks Same-Host Traffic

We knew this from the ADR but didn't account for it when designing the `$HOST_IP` proxy approach. The `192.168.2.0/24 dev net1` route in the pod's routing table means all traffic to node LAN IPs goes through macvlan — and macvlan bridge mode cannot reach its own host. Adding routes requires `NET_ADMIN`, which violates baseline PSA.

### 6. Apply Talos Configs Before upgrade-k8s

`talosctl upgrade-k8s` reads extraManifests URLs from the **live node machine config**, not from local files. If you update `controlplane.yaml` and `gen-configs` but don't `talosctl apply-config`, the nodes still have the old URLs.

---

## Key Cilium Internals Learned

### The `cilium.l7policy` Filter

- Injected at runtime by Cilium into all Gateway Envoy listeners (not in CiliumEnvoyConfig spec)
- Communicates with Cilium agent via Unix socket for policy decisions
- Returns HTTP 403 with body `"Access denied\r\n"` when policy check fails
- The filter config only has `access_log_path` — no user-configurable policy overrides
- Cannot be disabled or bypassed via configuration
- Applies to ALL traffic with eBPF identity metadata, regardless of delivery mechanism

### Embedded vs. External Envoy

- `envoy.enabled: true` (default): Separate `cilium-envoy` DaemonSet on hostNetwork. The agent communicates with it via Unix socket. TPROXY redirects service traffic to the DaemonSet's proxy port (14947).
- `envoy.enabled: false`: Envoy runs as a child process inside the cilium-agent pod. Same Unix socket communication, but in-process. TPROXY redirects to ephemeral ports (10000-20000). With `gateway-api-hostnetwork-enabled: true`, the embedded Envoy ALSO binds on the Gateway listener ports (80, 443) directly on the host network — but only if `NET_BIND_SERVICE` capability is present.

### CiliumEnvoyConfig for Gateway API

The Gateway API operator creates a CiliumEnvoyConfig per Gateway with:
- `nodeSelector` matching the `gatewayAPI.hostNetwork.nodes.matchLabels`
- Listener addresses: `0.0.0.0:80` and `0.0.0.0:443` (when hostNetwork enabled)
- Full Envoy filter chain: TLS inspector, HTTP connection manager, route config
- Backend services with port mappings

Only cilium-agent pods on matching nodes process this CEC and open the listeners.

### Known Cilium Bug: Gateway Programmed: False with hostNetwork

[cilium/cilium#42786](https://github.com/cilium/cilium/issues/42786): The Gateway shows `Programmed: False` with `AddressNotAssigned` because with hostNetwork, Cilium creates a ClusterIP Service (not LoadBalancer), and the reconciler checks for LoadBalancer addresses. No fix as of Cilium 1.19.2. The traffic routing still works despite the status.

---

## Stable MAC Requirement

### Why Not Just Use Cilium L2 Announcements?

Consumer and prosumer routers, managed switches, and network devices identify devices by MAC address. When a virtual IP's MAC changes on failover:
- Port forwarding rules are orphaned (rules bound to MAC-keyed device entries)
- ARP cache staleness (1-20+ minutes depending on device)
- DHCP reservations disrupted
- Device tracking confused

This is NOT router-specific — it's a fundamental L2 networking constraint. The macvlan approach (static MAC `02:42:c0:a8:02:46`) solves this at the correct layer.

### Why Not kube-vip?

Researched extensively. kube-vip does **NOT** implement VRRP and does **NOT** provide a virtual MAC. It uses ARP mode (gratuitous ARP with the node's real physical MAC) — identical to Cilium L2 announcements. On failover, the new leader sends a gratuitous ARP with its own different MAC. Only `keepalived` with `use_vmac` provides a true RFC 5798 virtual MAC (`00:00:5e:00:01:{VRID}`), but that adds significant complexity.

---

## Commits (in order)

| Commit | Description | Key Learning |
|--------|-------------|--------------|
| `f12060b` | Switch to per-Gateway Envoy with hostNetwork | ConfigMap wasn't updated — forgot to apply Talos configs first |
| `9259cb3` | Add NET_BIND_SERVICE + keepCapNetBindService | Embedded Envoy can't bind port 80/443 without this |
| `8d0a6cd` | Proxy to $HOST_IP via init container + emptyDir | ConfigMap subPath is read-only; also macvlan route takes precedence |
| `d771db8` | Add nodeSelector for gateway nodes | Pod landed on pi node without Gateway listener |
| `b8d4da6` | Add host route via NET_ADMIN | Violated baseline PSA — NET_ADMIN not allowed |
| `50ca381` | Use Cilium host endpoint IP | Still 403 — eBPF identity marking on eth0 path |
| `392d5cf` | **Proxy via macvlan to remote nodes** | **THE FIX** — external LAN traffic bypasses L7 filter |

---

## Final State

### Cilium Configuration
- `envoy.enabled: false` — embedded Envoy in cilium-agent
- `gatewayAPI.hostNetwork.enabled: true` — Envoy binds on `0.0.0.0:80/443`
- `gateway-api-hostnetwork-nodelabelselector: node-role.kubernetes.io/gateway=`
- `NET_BIND_SERVICE` in ciliumAgent capabilities
- `keepCapNetBindService: true`
- Worker nodes node-04, node-05, node-06 labeled `node-role.kubernetes.io/gateway`

### ingress-front Configuration

> **[SUPERSEDED 2026-04-17 for the WAN role.]** `ingress-front` now serves the
> **LAN path only** (`*.homelab.local`, `*.lan.homelab.ntbc.io` for trusted
> LAN clients). WAN ingress has moved to `pi-public-ingress` on `node-pi-01`
> (hostNetwork nginx, not macvlan). The properties below still describe the
> LAN-side ingress-front pod correctly.

- nginx L4 stream proxy with static upstream (all 3 worker IPs)
- Traffic flows via macvlan (net1) to remote worker nodes
- Macvlan same-host isolation handled by nginx upstream failover
- No init container, no nodeSelector, no NET_ADMIN
- CNP: only DNS egress via eth0; proxy traffic bypasses Cilium entirely via macvlan

### Verified Working
- ArgoCD, Grafana, Prometheus, Alertmanager, Vault, Dex — all accessible via `192.168.2.70`
- Home Assistant macvlan (192.168.2.71, 192.168.2.72) unaffected
- Internal pod-to-pod traffic unaffected
- FritzBox port forwarding unchanged (same MAC/IP) — **[SUPERSEDED 2026-04-17: FritzBox now port-forwards to node-pi-01, not to the ingress-front macvlan VIP]**

---

## Remaining Cleanup (Follow-up)

- Remove ineffective `ccnp-pni-gateway-ingress-identity` CCNP
- Remove `CiliumLoadBalancerIPPool` (no longer needed with hostNetwork)
- Add `toPorts` to monitoring-scrape CCNP
- Clean up AppProject whitelist entries
- Harden Multus CNI plugin download with SHA256 checksum
- Update ADR documentation
- Update CLAUDE.md cluster overview
- Delete the hubble-generate-certs Job that's causing immutable field errors on upgrade-k8s
