# Networking & Cilium Reliability Review: virtual-humming-tulip

**Reviewer**: platform-reliability-reviewer
**Date**: 2026-03-28
**Plan under review**: `/Users/ntbc/workspace/Talos-Homelab/Plans/virtual-humming-tulip.md`

---

## 1. Macvlan + Cilium Interaction

### Does Cilium see/track macvlan traffic?

**No. Macvlan traffic bypasses Cilium's eBPF datapath entirely.**

Cilium attaches its eBPF programs to the `lxc*` veth pair (the pod's primary `eth0` interface, created by the Cilium CNI). The macvlan `net1` interface is created by Multus as a secondary interface -- Cilium has no awareness of it. Traffic arriving on the macvlan interface enters the pod's network namespace directly via the macvlan device on the host, never touching any `lxc*` or `cilium_host` device.

This means:
- Cilium's BPF programs will NOT interfere with macvlan ingress/egress.
- Cilium will NOT apply network policy to macvlan traffic (see finding CNP-1 below).
- Cilium's conntrack and NAT tables will NOT track macvlan connections.
- Hubble will NOT observe traffic on the macvlan interface.

**Risk**: This is simultaneously a feature and a gap. The ingress-front pod's macvlan interface is essentially an unmonitored, unpolicied network path directly into the pod. The only protection is whatever nginx itself enforces.

### Could Cilium's eBPF interfere?

No. `external-envoy-proxy: "true"` (line 329 of `cilium.yaml`) means Cilium's gateway Envoy runs as a separate Deployment (`cilium-gateway-homelab-gateway` in `default` namespace), not inside the Cilium agent. This Deployment's traffic goes through normal pod networking (Cilium veth), completely independent of the macvlan path. No conflict.

---

## 2. IP Conflict: ARP Race During Transition

**This is the highest-risk part of the plan.**

### Current state
- `192.168.2.70` is assigned to the `cilium-gateway-homelab-gateway` LoadBalancer Service
- Cilium L2 agent on one node responds to ARP for this IP with that node's physical NIC MAC
- `cilium-ip-pool.yaml` reserves `192.168.2.70/32` for the gateway Service

### Proposed state
- `192.168.2.70` is assigned to the macvlan interface on the ingress-front pod with static MAC `02:42:c0:a8:02:46`
- The L2 announcement and IP pool are deleted

### The danger: dual-ARP responders

If the macvlan pod starts BEFORE the L2 announcement is removed, **both** the Cilium L2 agent and the macvlan interface will respond to ARP for `192.168.2.70`. The FritzBox and other LAN devices will receive two ARP replies with different MACs. Which one wins is nondeterministic and depends on timing. This causes:

1. **Intermittent connectivity loss** -- some packets go to the Cilium L2 responder (correct for now), some go to the macvlan pod (which may not be fully wired up yet).
2. **FritzBox MAC table flapping** -- exactly the problem the plan is trying to solve.

### Safe migration order

The plan's Step 4 says "Remove Cilium L2 announcement for gateway VIP" but does not specify the precise sequencing relative to Step 3 (deploying ingress-front). The safe order is:

1. Deploy ingress-front pod (Step 3) but do NOT assign `192.168.2.70` to its macvlan yet -- use a **temporary staging IP** (e.g., `192.168.2.71`) to validate the proxy path works.
2. Verify end-to-end via the staging IP: `curl -k https://192.168.2.71 -H "Host: argocd.homelab.local"`.
3. In a **single git commit**: delete the L2 announcement + IP pool AND switch the macvlan IP from staging to `192.168.2.70`. Push and sync.
4. After ArgoCD syncs and Cilium releases the IP, send a gratuitous ARP from the macvlan pod: `arping -c 3 -A -I net1 192.168.2.70`.

Alternatively, if staging IP is not desired: delete the L2 announcement and IP pool FIRST (Step 4 before Step 3), accept a brief outage window while Cilium releases the IP and the macvlan pod starts.

---

## 3. nginx `listen 0.0.0.0` -- Routing Loop Risk

### The concern is valid but the loop does not occur in practice. Here's why:

**Traffic path analysis:**

1. **External (macvlan) path**: FritzBox -> macvlan `net1` (192.168.2.70) -> nginx -> `cilium-gateway-homelab-gateway.default.svc` ClusterIP -> Cilium Envoy pod -> backend.

2. **Internal (eth0) path**: Any pod on the cluster can reach nginx on its Cilium-assigned pod IP (e.g., `10.244.x.y:443`) via eth0. However, **nothing routes traffic to this path** because:
   - The `cilium-gateway-homelab-gateway` Service (now ClusterIP after Step 4) has its own Envoy pods as endpoints -- it does NOT point to ingress-front.
   - No Service exposes ingress-front's eth0 ports to the cluster.
   - HTTPRoutes route to backend Services, not to ingress-front.

3. **Could the Cilium gateway Envoy send traffic to ingress-front's eth0?** Only if an HTTPRoute's `backendRef` pointed at ingress-front, which none do. The Envoy proxy resolves routes to the actual backend Services (argocd-server, grafana, etc.).

**However**, there is a subtler risk: if something on the cluster tries to connect to `192.168.2.70:443` (e.g., a pod using the external IP directly), Cilium's `kube-proxy-replacement: "true"` with `bpf-lb-sock: "false"` means socket-level LB is disabled. The connection would go out the node's physical NIC, hit the macvlan pod via L2, enter nginx on net1, and nginx would proxy back into the cluster via eth0. This is not a loop but it IS an unnecessary hairpin. With `bpf-lb-sock: "false"` and the Service being ClusterIP (post-migration), there's no DNAT shortcut for this external IP.

**Recommendation**: Add `listen 192.168.2.70:80` and `listen 192.168.2.70:443` to the nginx config instead of `0.0.0.0`. This binds nginx exclusively to the macvlan interface, eliminating any accidental exposure on the Cilium eth0 interface.

```nginx
server { listen 192.168.2.70:80; proxy_pass gateway_http; }
server { listen 192.168.2.70:443; proxy_pass gateway_https; }
```

---

## 4. Single Replica Resilience

### Can you run 2 replicas with the same macvlan IP+MAC on different nodes?

**No. This is fundamentally impossible and would cause network corruption.**

- Two macvlan interfaces on different physical hosts with the same MAC would cause **MAC address collision at the switch/FritzBox level**. The switch would flap between ports, delivering frames to the wrong host.
- Two interfaces with the same IP would cause **ARP conflicts** -- both would respond, identical to the L2 announcement problem being solved.
- macvlan is a Layer 2 construct -- there is no arbitration or leader election like Cilium L2 has.

### Resilience options

1. **Accept the tradeoff**. The pod restarts in ~5-10 seconds (nginx-alpine is tiny). During restart, the macvlan IP is unreachable. The FritzBox will retry TCP connections. For a homelab, this may be acceptable.

2. **Use a static node assignment** via `nodeName` or `nodeAffinity` to keep the pod on a specific node, reducing reschedule time (no scheduling decision needed). This does NOT help if that node goes down.

3. **Use `terminationGracePeriodSeconds: 0`** and `preStop` lifecycle hook to speed up pod replacement during rolling updates.

4. **Consider keepalived/VRRP sidecar** in a later iteration -- two pods on different nodes, only one holds the VIP via VRRP. This is significantly more complex but provides true HA. However, this reintroduces MAC changes on failover, partially defeating the purpose.

5. **PROXY protocol + hostNetwork fallback**: Instead of macvlan, run the ingress-front with `hostNetwork: true` on a dedicated node with a static ARP entry on the FritzBox. The FritzBox would bind to the node's real MAC. But this ties the service to one node permanently.

**Bottom line**: For the stated goal (stable MAC for FritzBox), single replica with fast restart is the correct tradeoff. The only way to have both stable MAC and HA is VRRP, which is a significant complexity increase.

---

## 5. `net.ifnames=0` Safety on Talos

### Does Talos reference interface names internally?

**Talos uses `deviceSelector` (not interface names) for network configuration in machine config.** Checking the actual patches:

- `/Users/ntbc/workspace/Talos-Homelab/talos/patches/common.yaml` -- no interface name references
- No node-specific patches (`talos/patches/node-*.yaml`) exist
- Talos's DHCP configuration uses `deviceSelector` predicates (bus path, MAC, driver), not interface names

The grep across all Talos patches shows zero references to `enp0s*` or `eth0` or `deviceSelector`. This means Talos is using its default behavior: configure the first interface with DHCP. Talos enumerates interfaces by kernel order regardless of naming scheme.

### Known risks with `net.ifnames=0`

1. **Multi-NIC nodes**: If a node has multiple physical NICs, `net.ifnames=0` names them `eth0`, `eth1`, etc., based on kernel enumeration order. Kernel enumeration order is NOT guaranteed stable across reboots on some hardware. **However**, the GPU node's USB NIC (`r8152`) will always enumerate after the onboard NIC due to USB subsystem initialization order, so this is safe for the current hardware.

2. **Future hardware changes**: Adding a second NIC (e.g., a USB NIC to a standard node) could cause naming ambiguity. This is a low risk given the stable hardware inventory.

3. **Talos upgrades**: Talos itself does not depend on `net.ifnames=0` or predictable naming. The kernel boot param is applied before Talos networking starts. No conflict.

4. **DRBD replication**: DRBD references pod IPs (via LINSTOR), not host interface names. No impact.

**Verdict**: `net.ifnames=0` is safe for this cluster's current hardware. The only references to NIC names in the repo are in `.claude/environment.yaml` (metadata, not operational config) and the Multus NetworkAttachmentDefinition `master` field (which is the entire reason for this change).

---

## 6. CNP Gaps: Macvlan Traffic vs Cilium Policy

### Cilium does NOT evaluate policy on macvlan traffic.

This is the critical point the plan underestimates. The plan's Step 6 proposes a CNP for ingress-front, but:

- **Ingress on macvlan (`net1`)**: Traffic from the FritzBox/internet arrives on the macvlan interface. Cilium's eBPF is not attached to this interface. **No CNP, CCNP, or KNP can filter this traffic.** The pod is exposed to the entire L2 network on its macvlan interface with zero network policy enforcement.

- **Egress from eth0 (Cilium)**: When nginx proxies to the gateway ClusterIP, this egress goes through the pod's primary `eth0` interface, which IS managed by Cilium. A CNP CAN and SHOULD restrict this egress to only the gateway Service ports.

- **The `fromEntities: ["world"]` rule in the proposed CNP**: This would apply to traffic arriving on the Cilium eth0 interface, NOT macvlan traffic. It is functionally useless for the intended purpose (allowing FritzBox traffic). It does, however, open the pod to any cluster-external traffic arriving via eth0 (e.g., if someone routes traffic to the pod IP from outside).

### What the CNP should actually look like

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: cnp-ingress-front
  namespace: default
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: ingress-front
  # Ingress: only allow what's needed on eth0 (Cilium interface)
  # Macvlan traffic is invisible to Cilium -- no rule needed or possible
  ingress:
    # Prometheus scraping if ServiceMonitor exists
    - fromEndpoints:
        - matchLabels:
            app.kubernetes.io/name: prometheus
      toPorts:
        - ports:
            - port: "9113"  # nginx prometheus exporter, if added
              protocol: TCP
  egress:
    # DNS resolution
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: UDP
    # Gateway Service (post-DNAT: Envoy container port)
    - toEndpoints:
        - matchLabels:
            app.kubernetes.io/name: cilium-gateway-homelab-gateway
      toPorts:
        - ports:
            - port: "8080"   # Envoy HTTP
              protocol: TCP
            - port: "8443"   # Envoy HTTPS
              protocol: TCP
```

**Do NOT include `fromEntities: ["world"]`** -- it would open the pod's eth0 to arbitrary external traffic for no benefit (macvlan traffic doesn't traverse eth0).

---

## Findings Summary

### BLOCKING

```
[BLOCKING] Plans/virtual-humming-tulip.md:160-166 — No defined sequencing between
ingress-front deployment (Step 3) and L2 announcement removal (Step 4). Simultaneous
ARP responders for 192.168.2.70 will cause MAC flapping and intermittent connectivity loss.
Fix: Either (a) deploy ingress-front with a staging IP first, validate, then atomically
swap IP + remove L2 in one commit; or (b) remove L2 announcement FIRST, accept brief
outage, THEN deploy ingress-front.
```

```
[BLOCKING] Plans/virtual-humming-tulip.md:191-196 — CNP design assumes Cilium evaluates
policy on macvlan traffic. It does not. The `fromEntities: ["world"]` ingress rule provides
zero protection on the macvlan interface and unnecessarily opens eth0 to external traffic.
Fix: Remove `fromEntities: ["world"]` ingress rule. Accept that macvlan ingress is
unpolicied by Cilium. Restrict the CNP to egress-only (DNS + gateway Service).
Document the macvlan security model explicitly: nginx itself is the only access control
on the macvlan path.
```

### WARNING

```
[WARNING] Plans/virtual-humming-tulip.md:153-154 — nginx `listen 0.0.0.0` binds to both
eth0 (Cilium) and net1 (macvlan). While no routing loop occurs, this unnecessarily exposes
ports 80/443 on the pod's Cilium-assigned IP to the cluster.
Fix: Bind nginx to macvlan IP only: `listen 192.168.2.70:80;` and `listen 192.168.2.70:443;`
```

```
[WARNING] Plans/virtual-humming-tulip.md:98-99 — Single replica means any pod restart
causes complete ingress outage (5-15 seconds). No mitigation strategy documented.
Fix: Add `terminationGracePeriodSeconds: 0` to the pod spec, document the expected outage
window, and consider a liveness probe with short failure threshold to speed up restart on
hang.
```

```
[WARNING] Plans/virtual-humming-tulip.md:212 — PROXY protocol consideration is deferred
but client IP preservation is critical for security. Without PROXY protocol, all backend
Services see the nginx pod IP as the client, making rate limiting, fail2ban, and audit
logging ineffective.
Fix: Decide on PROXY protocol before implementation. If enabled later, it requires
coordinated changes to both nginx config AND Cilium config
(`enable-gateway-api-proxy-protocol: "true"` in cilium-config ConfigMap), which means
a Cilium bootstrap manifest update + `make -C talos upgrade-k8s`.
```

```
[WARNING] Plans/virtual-humming-tulip.md:63-91 — NetworkAttachmentDefinition is in
namespace `default` but Step 3's Deployment annotation references it without a namespace
qualifier. Multus resolves NADs relative to the pod's namespace. Since the Deployment is
also in `default`, this works -- but if the pod is ever moved to another namespace, the
NAD reference breaks silently.
Fix: Use fully-qualified annotation: `default/homelab-gateway-macvlan` in the Multus
annotation, or document this coupling.
```

### INFO

```
[INFO] Plans/virtual-humming-tulip.md:30 — net.ifnames=0 is safe for current hardware
(verified: no NIC name references in Talos patches, only in .claude/environment.yaml
metadata). However, the 7-node rolling upgrade for a boot param change is a significant
operational effort. Consider batching with any other pending schematic changes.
```

```
[INFO] Plans/virtual-humming-tulip.md:100 — The nginx upstream uses DNS name
`cilium-gateway-homelab-gateway.default.svc` which relies on DNS resolution at stream
proxy time. nginx stream module resolves upstreams at config load, not per-connection
(unlike http module with `resolver` directive). If the gateway Service ClusterIP changes
(unlikely but possible during Cilium upgrade), nginx needs a reload. Consider using the
ClusterIP directly and adding a comment noting this, or use the `resolver` directive
with re-resolve interval.
```

```
[INFO] Plans/virtual-humming-tulip.md:14-19 — Macvlan in bridge mode allows the pod to
communicate with other macvlan pods on the same host but NOT with the host itself (macvlan
isolation). This means the node running ingress-front cannot reach 192.168.2.70 from host
network. This is unlikely to matter but worth noting for debugging.
```

```
[INFO] — Hubble observability gap: traffic arriving on macvlan is invisible to Hubble.
Any debugging of external traffic issues requires `tcpdump` inside the pod on net1.
Consider adding tcpdump to the container image or using an ephemeral debug container.
```

---

## Verdict: BLOCKED

Two BLOCKING findings must be resolved before implementation:

1. **ARP race during transition** -- the plan needs an explicit, ordered migration sequence that prevents dual ARP responders for 192.168.2.70.

2. **CNP security model is incorrect** -- the plan assumes Cilium can policy macvlan traffic. It cannot. The CNP must be redesigned for egress-only on the Cilium interface, and the security model for the macvlan path must be explicitly documented as "nginx is the only control."
