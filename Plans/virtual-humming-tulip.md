# Plan: Consolidate UI Services Behind Single Gateway IP with Stable MAC

## Context

**Problem:** All UI services (ArgoCD, Grafana, Prometheus, Alertmanager, Vault, Dex) need external access from the internet via FritzBox port forwarding. Since FritzOS 8.20, the FritzBox binds port forwarding rules to a device's MAC address. Currently:

- The gateway VIP (192.168.2.70) is announced via Cilium L2 — the responding MAC changes on node failover, which can confuse the FritzBox (stale ARP cache ~15-20min, potential duplicate device entries, orphaned port forwarding rules).
- Three services (Dex, Prometheus oauth2-proxy, Alertmanager oauth2-proxy) still use separate LoadBalancer IPs (192.168.2.131/133/134) despite already having HTTPRoutes through the gateway — unnecessary complexity.

**Goal:** Single IP (192.168.2.70) with a **stable, predictable MAC address** for all UI services, so FritzBox port forwarding is reliable and survives pod/node failovers.

## Architecture

```
Internet → FritzBox (port forward 443 → MAC 02:42:c0:a8:02:46 / 192.168.2.70)
    → macvlan net1 on "ingress-front" pod (stable MAC + IP)
    → nginx L4 proxy → pod's eth0 (Cilium) → Gateway ClusterIP
    → Cilium envoy → HTTPRoutes → backend services
```

A lightweight L4 proxy pod ("ingress-front") with a Multus macvlan secondary interface provides the stable MAC. External traffic arrives on the macvlan net1 interface; nginx forwards it via the pod's primary eth0 (Cilium) to the gateway service. The FritzBox always sees the same MAC for 192.168.2.70.

**Security model:** Macvlan traffic bypasses Cilium's eBPF datapath entirely (Cilium only attaches to the primary lxc veth). The nginx config is the sole access control for macvlan-ingress traffic. CNP covers only eth0 egress (DNS + gateway service). This is explicitly accepted — the ingress-front pod is a dumb L4 forwarder with no backend logic.

## Implementation Steps

### Phase A: Infrastructure Prerequisites

#### ~~Step 0: Normalize NIC names~~ — DROPPED

`net.ifnames=0` was considered but rejected after deep research:
- node-gpu-01 has an **inactive** PCIe NIC (RTL8136, `enp4s0`, link down) and an **active** USB NIC (RTL8153, `enp0s20f0u2`). With `net.ifnames=0`, the inactive PCIe NIC would claim `eth0` (PCI probes synchronously before USB hub enumeration), making `master: eth0` point to the wrong interface.
- Legacy `ethX` naming is non-deterministic — the kernel docs explicitly state it's a timing artifact, not a spec.
- No Talos mechanism exists to rename interfaces (udev rules apply too late).

**Solution:** Omit the `master` field from the macvlan CNI config entirely. Per the containernetworking/plugins specification, macvlan defaults to the **default route interface** when `master` is not specified. This automatically picks the active NIC on every node regardless of naming convention — `enp0s31f6` on standard nodes, `enp0s20f0u2` on GPU node.

#### Step 1: Install `tuning` and `static` CNI plugins
**File:** `kubernetes/overlays/homelab/infrastructure/multus-cni/resources/daemonset.yaml`

The macvlan plugin alone cannot set a static MAC or static IP. Two additional plugins needed:
- **`tuning`** — sets static MAC address via plugin chain
- **`static`** — IPAM plugin for fixed IP assignment

```diff
- | tar xzf - -C /host/opt/cni/bin ./macvlan ./ipvlan
+ | tar xzf - -C /host/opt/cni/bin ./macvlan ./ipvlan ./tuning ./static
```

Update idempotency check:
```diff
- if [ ! -f /host/opt/cni/bin/macvlan ]; then
+ if [ ! -f /host/opt/cni/bin/macvlan ] || [ ! -f /host/opt/cni/bin/tuning ] || [ ! -f /host/opt/cni/bin/static ]; then
```

### Phase B: Deploy ingress-front (parallel path, keep existing L2 active)

#### Step 2: Create ingress-front as child Application
**New directory:** `kubernetes/overlays/homelab/infrastructure/ingress-front/`

The `root-bootstrap` AppProject only whitelists `argoproj.io`, `gateway.networking.k8s.io`, `cert-manager.io`, and `cilium.io/CiliumGatewayClassConfig`. Adding Deployments/ConfigMaps/NetworkAttachmentDefinitions to gateway-api would be blocked. Instead, create a proper child Application under the `infrastructure` project (which allows `group: "*", kind: "*"`).

Structure:
```
kubernetes/overlays/homelab/infrastructure/ingress-front/
├── kustomization.yaml          # references resources/
├── application.yaml            # ArgoCD Application CR, sync-wave: "9"
└── resources/
    ├── kustomization.yaml
    ├── net-attach-def.yaml     # NetworkAttachmentDefinition
    ├── deployment.yaml         # ingress-front Deployment + ConfigMap
    └── cnp.yaml                # CiliumNetworkPolicy (egress-only)
```

**Sync-wave 9** (after gateway-api at wave 8) ensures the Cilium gateway Service exists before nginx tries to resolve it.

Add `ingress-front` to `kubernetes/overlays/homelab/infrastructure/kustomization.yaml`.

#### Step 3: NetworkAttachmentDefinition
**File:** `resources/net-attach-def.yaml`

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: homelab-gateway-macvlan
  namespace: default
spec:
  config: |
    {
      "cniVersion": "1.0.0",
      "plugins": [
        {
          "type": "macvlan",
          "mode": "bridge",
          "ipam": {
            "type": "static",
            "addresses": [
              { "address": "192.168.2.70/24", "gateway": "192.168.2.1" }
            ]
          }
        },
        {
          "type": "tuning",
          "capabilities": { "mac": true }
        }
      ]
    }
```

`master` is intentionally omitted — macvlan defaults to the default route interface, which is always the active NIC on any node.
```

#### Step 4: ingress-front Deployment
**File:** `resources/deployment.yaml`

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: ingress-front-config
  namespace: default
data:
  nginx.conf: |
    worker_processes 1;
    events { worker_connections 512; }
    stream {
      resolver 10.96.0.10 valid=30s;
      server {
        listen 192.168.2.70:80;
        set $gw_backend cilium-gateway-homelab-gateway.default.svc.cluster.local;
        proxy_pass $gw_backend:80;
      }
      server {
        listen 192.168.2.70:443;
        set $gw_backend cilium-gateway-homelab-gateway.default.svc.cluster.local;
        proxy_pass $gw_backend:443;
      }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ingress-front
  namespace: default
  labels:
    app.kubernetes.io/name: ingress-front
    app.kubernetes.io/instance: homelab
    app.kubernetes.io/component: l4-proxy
    app.kubernetes.io/part-of: homelab
    app.kubernetes.io/managed-by: argocd
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: ingress-front
      app.kubernetes.io/instance: homelab
  template:
    metadata:
      labels:
        app.kubernetes.io/name: ingress-front
        app.kubernetes.io/instance: homelab
        app.kubernetes.io/component: l4-proxy
        app.kubernetes.io/part-of: homelab
      annotations:
        k8s.v1.cni.cncf.io/networks: |
          [{"name": "homelab-gateway-macvlan", "mac": "02:42:c0:a8:02:46"}]
    spec:
      containers:
        - name: nginx
          image: nginx:1.27-alpine
          volumeMounts:
            - name: config
              mountPath: /etc/nginx/nginx.conf
              subPath: nginx.conf
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              memory: 64Mi
      volumes:
        - name: config
          configMap:
            name: ingress-front-config
```

**Key design decisions:**
- **`listen 192.168.2.70:80/443`** — binds ONLY to macvlan IP, not 0.0.0.0. Prevents unnecessary exposure on the Cilium eth0 interface. Safe because Multus/macvlan creates the net1 interface during pod sandbox setup, before any container starts.
- **`resolver 10.96.0.10`** — uses kube-dns ClusterIP directly, not FQDN (avoids circular DNS dependency).
- **`set $var` + variable `proxy_pass`** — nginx resolves DNS at runtime per connection, not just at config load. If the gateway ClusterIP changes (e.g., Cilium upgrade), nginx picks it up within 30s. The `map` directive was rejected (invalid with empty string source); `set` in `server {}` is the idiomatic nginx stream approach (available since nginx 1.19.3).
- **Single replica** — two replicas with same MAC+IP on different nodes is impossible at L2 (causes switch MAC flapping). Single replica with fast restart is correct. No PDB needed — brief downtime (~10-15s) during drain/reschedule is acceptable for homelab.

#### Step 5: CiliumNetworkPolicy (egress-only)
**File:** `resources/cnp.yaml`

Macvlan traffic bypasses Cilium — CNP only covers eth0:
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
  egress:
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: UDP
            - port: "53"
              protocol: TCP
    - toServices:
        - k8sService:
            serviceName: cilium-gateway-homelab-gateway
            namespace: default
      toPorts:
        - ports:
            - port: "80"
              protocol: TCP
            - port: "443"
              protocol: TCP
```

No ingress rules — macvlan traffic doesn't traverse Cilium, so `fromEntities: ["world"]` would be meaningless and would open eth0 unnecessarily.

### Phase C: Cutover (after Phase B is verified working)

#### Step 6: Remove Cilium L2 announcement for gateway VIP
**PREREQUISITE:** Verify ingress-front is working via `curl -k https://192.168.2.70 -H "Host: argocd.homelab.local"` from a LAN machine BEFORE this step.

**Migration order (single atomic commit to avoid ARP race):**
1. **Delete** `cilium-l2-announcement.yaml` (homelab-l2 policy)
2. **Delete** `cilium-ip-pool.yaml` (homelab-pool, 192.168.2.70/32)

Both removals in one commit → ArgoCD prunes them simultaneously → Cilium stops L2 announcements → only ingress-front responds to ARP for 192.168.2.70. No ARP race because ingress-front already owns the IP via macvlan.

**Note:** The Cilium-generated `cilium-gateway-homelab-gateway` Service remains but loses its LoadBalancer IP (no pool to allocate from). It continues working as a ClusterIP service for ingress-front to proxy to.

#### Step 7: Consolidate UI services — remove separate LoadBalancer IPs
Since all services already have HTTPRoutes through the gateway, remove redundant LoadBalancer IPs:

1. **Dex** (`kubernetes/overlays/homelab/infrastructure/dex/values.yaml`):
   - `service.type: LoadBalancer` → `service.type: ClusterIP`
   - Remove `service.loadBalancerIP: 192.168.2.131`
   - Remove `homelab.local/expose: "true"` label

2. **Prometheus oauth2-proxy** (`resources/oauth2-proxy-prometheus.yaml`):
   - `type: LoadBalancer` → `type: ClusterIP`
   - Remove `loadBalancerIP: 192.168.2.133`
   - Remove `homelab.local/expose: "true"` label

3. **Alertmanager oauth2-proxy** (`resources/oauth2-proxy-alertmanager.yaml`):
   - `type: LoadBalancer` → `type: ClusterIP`
   - Remove `loadBalancerIP: 192.168.2.134`
   - Remove `homelab.local/expose: "true"` label

4. **Delete** `cilium-l2-announcement-ui.yaml` (homelab-ui-l2 policy)
5. **Delete** `cilium-ui-ip-pool.yaml` (homelab-ui-pool, 192.168.2.130-150 range)

#### Step 8: Write ADR and update documentation

**New file:** `docs/adr-ingress-front-stable-mac.md`

Architecture Decision Record documenting:
- **Status:** Accepted
- **Context:** FritzBox (FritzOS 8.20+) binds port forwarding to MAC addresses. Cilium L2 announcements respond to ARP with the announcing node's physical NIC MAC, which changes on failover. This causes the FritzBox to lose the port forwarding binding (stale ARP cache 15-20min, duplicate device entries, orphaned rules). All UI services need stable external access through a single IP.
- **Decision:** Deploy a dedicated "ingress-front" pod with a Multus macvlan secondary interface carrying a static MAC (`02:42:c0:a8:02:46`) and IP (`192.168.2.70`). This pod runs nginx in L4 stream mode, forwarding to the Cilium Gateway API service. All UI services consolidated behind HTTPRoutes on the single gateway.
- **Alternatives considered:**
  1. *Cilium L2 announcements only* — rejected: MAC instability on failover breaks FritzBox
  2. *Static MAC on Talos node interface* — rejected: ties VIP to a specific node, losing failover
  3. *MetalLB with static MAC* — rejected: cluster uses Cilium-native L2, adding MetalLB is redundant complexity
- **Consequences:** Macvlan traffic bypasses Cilium eBPF (no Hubble visibility, no CNP enforcement on ingress). Single replica means brief outage on pod restart (~10s).
- **Trade-offs accepted:** No client IP preservation without PROXY protocol. No Hubble visibility for macvlan path (tcpdump only).
- **NIC naming note:** `net.ifnames=0` was evaluated and rejected — on node-gpu-01 the inactive PCIe NIC would claim `eth0`, breaking macvlan master selection. Instead, macvlan `master` is omitted entirely, defaulting to the default route interface (works on all nodes regardless of NIC naming).

**Also update:**
- `docs/ui-loadbalancer-ip-plan.md` — single-IP architecture, MAC address reference

## Decisions to Confirm

1. **MAC address `02:42:c0:a8:02:46`** — locally administered range (02:xx prefix), encodes 192.168.2.70 in last 4 bytes. Any preference?

2. **Dex callback URLs** — oauth2-proxy redirects use `https://*.homelab.local/oauth2/callback` which resolves through DNS to the gateway. Confirm Dex `issuerURI` doesn't rely on the direct LoadBalancer IP `192.168.2.131`.

3. **Client IP preservation** — ingress-front adds an L4 hop, so backends see nginx pod IP, not real client. Options:
   - **Accept it** (simplest) — client IP only matters for rate limiting/audit, which this homelab may not need
   - **Enable PROXY protocol** — requires coordinated change: nginx sends PROXY header + Cilium `enable-gateway-api-proxy-protocol: "true"` in bootstrap manifest + `talosctl upgrade-k8s` to reconcile. More complex, can be added later.

4. **Observability gap** — Hubble has zero visibility into macvlan traffic. Debugging requires `kubectl exec <pod> -- tcpdump -i net1`. Acceptable for a homelab?

5. **Macvlan host isolation** — the node running ingress-front cannot reach `192.168.2.70` from its own host network (macvlan bridge mode limitation). LAN clients on other devices work fine. Acceptable?

## Verification

1. **Step 1:** Exec into Multus pod: `ls /host/opt/cni/bin/{tuning,static}` — both present
3. **Step 4:** `kubectl get pod -l app.kubernetes.io/name=ingress-front` Running; `kubectl exec <pod> -- ip addr show net1` → MAC `02:42:c0:a8:02:46`, IP `192.168.2.70/24`
4. **Before Step 6:** `curl -k https://192.168.2.70 -H "Host: argocd.homelab.local"` from LAN → ArgoCD UI (while L2 is still active, both paths work)
5. **After Step 6:** Same curl works, `arping 192.168.2.70` → consistent MAC `02:42:c0:a8:02:46`
6. **After Step 7:** `kubectl get svc -A | grep LoadBalancer` → no LoadBalancer services remain
7. **FritzBox:** Device list shows MAC `02:42:c0:a8:02:46` / IP `192.168.2.70` → configure port forward 443
8. **Failover:** `kubectl delete pod -l app.kubernetes.io/name=ingress-front` → pod reschedules, `arping 192.168.2.70` returns same MAC within ~10s
