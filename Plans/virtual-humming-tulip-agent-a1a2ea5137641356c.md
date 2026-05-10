# Review: Revised Plan virtual-humming-tulip.md

## Scope

Reviewing the macvlan `master` omission, bridge mode isolation, previously-identified blockers, and new risks from dropping `net.ifnames=0`.

---

## 1. macvlan without `master` field — Safety Analysis

### How it works

When the macvlan CNI plugin is invoked without a `master` field, the plugin resolves the default route interface by reading the kernel routing table at **pod creation time** (specifically, it calls `netlink.RouteList` for the default `0.0.0.0/0` route and uses the `LinkIndex` from that route entry). This is a one-time resolution — the macvlan sub-interface is bound to a specific parent at creation and does not re-evaluate if the routing table changes later.

Reference: `containernetworking/plugins/plugins/main/macvlan/macvlan.go` — the `getMasterName()` function resolves at `cmdAdd` time.

### Risk assessment

**Normal operations (pod scheduling, rescheduling, node reboot):** SAFE. On all 7 nodes, there is exactly one NIC with a default route (`0.0.0.0/0 via 192.168.2.1`), configured via Talos node patches with `hardwareAddr` device selectors. The default route interface is deterministic and stable:
- node-01 through node-06: `enp0s31f6` (Intel e1000e)
- node-gpu-01: `enp0s20f0u2` (USB Realtek RTL8153)

The inactive PCIe NIC on node-gpu-01 (`enp4s0`, RTL8136) has no IP address and no route — it will never be the default route interface.

**During Talos upgrade:** The pod is evicted before the node reboots, so macvlan teardown happens before any routing table changes. On the new node, a fresh `cmdAdd` resolves the correct interface. SAFE.

**During kubelet restart:** The macvlan interface persists in the pod's network namespace — it is not re-created. The parent binding survives kubelet restarts. SAFE.

**Edge case — multiple equal-cost default routes:** Not applicable here. Talos node configs define exactly one default route per node.

### Verdict on master omission: **PASS**

The omission is the correct design choice given the heterogeneous NIC naming. It is safer than hardcoding any interface name.

---

## 2. macvlan bridge mode isolation

### Host-to-pod isolation

macvlan bridge mode isolation is a property of the macvlan kernel module itself, not of the interface name. The rule is: **the parent interface (host) and all macvlan sub-interfaces are in separate broadcast domains at L2 — the host cannot communicate with its own macvlan children via the parent interface.** This applies regardless of which physical NIC is the parent.

With `master` omitted, the macvlan attaches to whichever NIC the default route uses. The bridge mode isolation still applies to that NIC. The plan correctly documents this in "Decisions to Confirm" item 5.

**Practical impact:** The node running ingress-front cannot reach `192.168.2.70` from its host network stack. This means:
- `talosctl` commands from that node to the gateway VIP will fail (but you use direct node IPs per operational rules).
- Pods on the same node that use the Cilium primary network (eth0) can still reach the gateway ClusterIP — only the host network namespace is affected.

### Non-determinism risk

The interface selection is deterministic as analyzed above (single default route per node). There is no risk of macvlan attaching to a random or wrong interface.

### Verdict on bridge mode isolation: **PASS**

---

## 3. Previously Identified Blockers

### ARP race during transition

The original concern was that during cutover, both Cilium L2 and macvlan would respond to ARP for `192.168.2.70`, causing MAC flapping on the LAN switch.

**Plan's mitigation (Phase B before Phase C):** The plan deploys ingress-front in Phase B while Cilium L2 is still active. During this overlap period, both respond to ARP. However:
- The ingress-front macvlan has a **static MAC** (`02:42:c0:a8:02:46`), while Cilium L2 responds with the announcing node's physical NIC MAC.
- The plan instructs verifying ingress-front works (Step 6 prerequisite) before removing Cilium L2 in a **single atomic commit**.
- The overlap window is brief (verification only, not a long-running state).

**Remaining risk:** During the Phase B overlap, ARP responses from both sources may cause brief MAC flapping on the switch. This is a transient condition during a manual cutover, not a steady-state risk.

**Assessment:** Adequately addressed. The phased approach with explicit verification before cutover is correct.

### CNP egress-only

The plan's CNP (Step 5, `resources/cnp.yaml`) is egress-only as required, covering:
1. DNS to kube-dns (UDP + TCP port 53) — correct
2. Gateway service access via `toServices` — **needs scrutiny** (see finding below)

---

## 4. New Risks from Dropping `net.ifnames=0` and Omitting `master`

### No new architectural risks

Dropping `net.ifnames=0` eliminates the real risk of the PCIe NIC claiming `eth0` on node-gpu-01. This was the correct decision.

Omitting `master` introduces no new risks beyond those analyzed in section 1. It is actually more robust than any hardcoded name would be.

### One operational consideration

If a future node is added with multiple NICs that both have default routes (e.g., a bonded interface setup), the macvlan `master` omission would become ambiguous. This is not a current risk but should be noted in the ADR.

---

## Findings

```
[WARNING] Plans/virtual-humming-tulip.md:219-228 — CNP toServices + toPorts may not work as expected for Cilium-generated gateway service
```

The CNP uses `toServices` with `toPorts` targeting ports 80 and 443. Per the CLAUDE.md constraint: "Gateway-backend toPorts must use container ports (post-DNAT)." The Cilium-generated `cilium-gateway-homelab-gateway` Service forwards to Envoy pods. After kube-proxy DNAT, the actual destination port depends on how Cilium configures its Envoy proxy pods.

However, this is a forward-to-Service scenario (not a backend-behind-Service scenario), and the `toServices` matcher in Cilium CNP translates to matching the Service's ClusterIP directly, not the backend endpoints. The ports 80/443 are the Service ports, which is what `toServices` expects.

**Actually, re-reading Cilium docs more carefully:** `toServices` with `toPorts` is valid — `toServices` selects traffic to the Service VIP, and `toPorts` filters on the destination port of the packet before DNAT (i.e., the Service port). This is correct usage.

Retracted — this is not a finding.

```
[WARNING] Plans/virtual-humming-tulip.md:167 — NetworkAttachmentDefinition in namespace 'default' but Deployment also in 'default'
```

The NetworkAttachmentDefinition is in `default` namespace and the pod annotation references it by name only (`homelab-gateway-macvlan`). This works because both are in the same namespace. However, placing infrastructure workloads in the `default` namespace is atypical. The plan does not create a dedicated namespace.

This is acceptable for a single-purpose L4 proxy pod, but worth noting: if the `default` namespace ever gets a restrictive PodSecurityStandard or CiliumNetworkPolicy default-deny, ingress-front would be affected.

```
[WARNING] Plans/virtual-humming-tulip.md:192 — Single replica with no PodDisruptionBudget means voluntary evictions (drain, upgrade) cause downtime
```

The plan acknowledges single replica and ~10s restart. However, there is no PDB. During `kubectl drain` (which the CLAUDE.md mandates before Talos upgrades on DRBD nodes), the pod will be evicted immediately. Combined with macvlan setup time + nginx startup, downtime could be 15-30 seconds during planned maintenance.

This is acceptable for a homelab but should be documented.

```
[INFO] Plans/virtual-humming-tulip.md:127-139 — nginx stream resolver uses kube-dns FQDN, not ClusterIP
```

The nginx config uses `resolver kube-dns.kube-system.svc.cluster.local`. This requires the pod to first resolve this DNS name to get the kube-dns ClusterIP, which creates a chicken-and-egg: nginx needs DNS to find the DNS server. In practice, this works because:
- The pod's `/etc/resolv.conf` (set by Cilium/kubelet) contains the kube-dns ClusterIP directly.
- nginx's `resolver` directive resolves the FQDN using the system resolver first.

However, using the kube-dns ClusterIP directly (typically `10.96.0.10`) would be more resilient. This is a minor robustness improvement, not a blocker.

```
[INFO] Plans/virtual-humming-tulip.md:244 — Cilium gateway Service losing LoadBalancer IP after pool deletion
```

The plan correctly notes the gateway Service will lose its LoadBalancer IP. Worth confirming: the `cilium-gateway-homelab-gateway` Service will still have a ClusterIP, which is what ingress-front proxies to via DNS resolution. The Service type may change from `LoadBalancer` to effectively just `ClusterIP` (or remain `LoadBalancer` with no external IP). Either way, the ClusterIP is stable and the proxy will work.

```
[INFO] Plans/virtual-humming-tulip.md:46-53 — Multus daemonset idempotency check only gates on macvlan presence
```

The current daemonset (line 63) checks `if [ ! -f /host/opt/cni/bin/macvlan ]`. The plan correctly updates this to also check for `tuning` and `static`. Good.

---

## Summary

| # | Severity | Description |
|---|----------|-------------|
| 1 | WARNING | Single replica + no PDB = downtime during planned node drains |
| 2 | WARNING | Infrastructure workload in `default` namespace — no namespace isolation |
| 3 | INFO | nginx resolver could use ClusterIP directly for resilience |
| 4 | INFO | Document that future multi-NIC nodes with multiple default routes would break master-omission assumption |
| 5 | INFO | Gateway Service losing LoadBalancer type after pool removal — confirm ClusterIP stability |

No BLOCKING findings. The macvlan `master` omission is correct and safe. Bridge mode isolation applies regardless of parent interface name. Previous blockers (ARP race, CNP scope) are adequately addressed. Dropping `net.ifnames=0` eliminates a real risk with no new risks introduced.

---

## Verdict: **PASS WITH WARNINGS**

The two warnings are operational hygiene items, not correctness issues. The core design — omitting `master` to let macvlan auto-select the default route interface — is the right call for this heterogeneous NIC environment. The phased cutover with explicit verification gates is sound.
