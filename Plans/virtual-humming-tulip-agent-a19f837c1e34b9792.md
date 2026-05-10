# Research: FritzBox 8.20 Port Forwarding, Cilium L2, and Macvlan Static MAC

## 1. FritzBox OS 8.20 Port Forwarding and MAC Address Requirements

### What Changed in Fritz!OS 8.20

The official Fritz!OS 8.20 release notes and feature pages do **not document any changes to port forwarding or MAC-based device binding**. The release focuses on Fritz! Failsafe (internet failover), Mesh WiFi improvements, parental controls, online monitor enhancements, and smart home features.

There is no evidence of a new "MAC address requirement" for port forwarding in Fritz!OS 8.20 specifically.

### How FritzBox Port Forwarding Has Always Worked

FritzBox port forwarding is fundamentally **device-based**, but that maps to IP addresses at the forwarding layer:

1. **Select a known device** from a dropdown -- the FritzBox shows devices it has seen via DHCP/ARP, identified by MAC address. Selecting a device auto-populates its IP.
2. **Manually enter an IP address** -- you can type any IP in the 192.168.x.0/24 range. The FritzBox will auto-create a "phantom" device entry (e.g., `PC-192-168-178-15`).

The actual NAT rule operates at Layer 3 (IP). The FritzBox does **not** enforce MAC matching at forwarding time -- it just uses the IP to DNAT incoming packets.

### The Device/MAC Tracking Complication

Where MAC addresses matter is in the FritzBox's **device registry**:
- The FritzBox tracks devices by MAC address internally
- Port forwarding rules are **bound to a device entry**, not directly to an IP
- If a device's MAC changes, the FritzBox sees it as a **new device** and the old device entry (with its port forwarding rules) becomes orphaned
- Over successive firmware versions, AVM has tightened validation -- making it harder to create "phantom" devices or edit config files directly

### Can You Forward to an IP Without a Known MAC?

**Yes**, but with caveats:
- You can manually enter an IP when creating the port forwarding rule
- The FritzBox will create a device entry for that IP
- If the IP later answers ARP with a different MAC than what the FritzBox initially recorded, the FritzBox may create a duplicate device entry and the forwarding rule stays bound to the old one
- Firmware 7.29+ added additional validation that can reject manual entries in some circumstances

### Sources
- [heimnetz.de - FritzBox Portfreigaben anlegen](https://www.heimnetz.de/anleitungen/router/avm-fritzbox/fritzbox-portfreigaben-anlegen/)
- [ComputerBase Forum - Geraet hinzufuegen ohne MAC](https://www.computerbase.de/forum/threads/fritz-box-7490-geraet-name-ip-hinzufuegen-ohne-mac-adresse.2016713/)
- [Mikrocontroller.net - FritzBox Portforwarding](https://www.mikrocontroller.net/topic/492210)
- [AVM Fritz!OS 8.20 Features](https://fritz.com/en/pages/fritzos-8-20)
- [Fritz!OS 8.20 Release Notes](https://fritz.com/release-notes-fritzos-820/)
- [secure-bits.org - FritzBox Portfreigabe](https://secure-bits.org/en/posts/fritzbox/fritzbox-portfreigabe/)

---

## 2. Cilium L2 Announcement Interaction with FritzBox ARP

### How Cilium L2 Announcements Work

Cilium L2 announcements use ARP to make LoadBalancer VIPs reachable on the LAN:
- One node is elected leader per service VIP via Kubernetes lease
- The leader responds to ARP requests for the VIP using **its own physical NIC's MAC address**
- On failover, the new leader sends **gratuitous ARP** (unsolicited ARP reply) to update all LAN devices with the new MAC-to-IP mapping

### The FritzBox Problem

**FritzBox ARP cache timeout is 15-20 minutes** and is **not configurable** through the web interface. There are two failure modes:

1. **Gratuitous ARP rejection**: The Cilium docs explicitly warn: "Not all clients accept gratuitous ARP replies since they can be used for ARP spoofing. Such clients might experience longer downtime than configured in the leases since they will only re-query via ARP when TTL in their internal tables has been reached." FritzBox behavior regarding gratuitous ARP acceptance is not officially documented, but consumer routers commonly ignore them.

2. **Device registry confusion**: When the VIP's MAC changes (failover), the FritzBox may:
   - See the VIP as a "new device" (different MAC, same IP)
   - Create a duplicate device entry
   - Orphan the port forwarding rule that was bound to the old device entry
   - Require manual intervention to re-bind the port forwarding rule

### Expected Behavior During Failover

| Scenario | What Happens |
|----------|-------------|
| Normal operation | One node answers ARP for VIP with its MAC. FritzBox learns the mapping. Port forwarding works. |
| Failover (GARP accepted) | New node sends GARP. FritzBox updates ARP cache. Port forwarding continues to the new MAC/node. BUT device registry may get confused. |
| Failover (GARP rejected) | FritzBox keeps stale ARP entry for 15-20 minutes. Port forwarding sends packets to the OLD node's MAC (which no longer owns the VIP). **Traffic blackholed for up to 20 minutes.** |
| After ARP cache expires | FritzBox re-ARPs for the VIP. New node responds. Traffic resumes. |

### Bottom Line

Cilium L2 announcements with a FritzBox upstream are **fragile for port forwarding**. The combination of MAC-based device tracking + stale ARP cache + potential GARP rejection creates a reliability problem for any externally-exposed service.

### Sources
- [Cilium L2 Announcements docs](https://docs.cilium.io/en/latest/network/l2-announcements/) (Cloudflare-blocked during fetch, info from search summaries)
- [GitHub cilium/cilium #37959 - L2 not responding to ARP in VLAN](https://github.com/cilium/cilium/issues/37959)
- [GitHub cilium/cilium #37318 - L2Announce + Wifi Mesh ARP failure](https://github.com/cilium/cilium/issues/37318)
- [DEV.to - Complete Guide Cilium L2 Announcements](https://dev.to/azalio/complete-guide-cilium-l2-announcements-for-loadbalancer-services-in-bare-metal-kubernetes-3jl2)
- [IP Phone Forum - ARP Cache modifizieren](https://www.ip-phone-forum.de/threads/arp-cache-modifizieren.275585/)

---

## 3. Macvlan CNI with Static MAC Address

### CNI Configuration Format

The macvlan CNI plugin itself does **not** have a `mac` field. To assign a static MAC, you need the **tuning** CNI plugin chained after macvlan, with `"capabilities": { "mac": true }`.

### NetworkAttachmentDefinition with Static MAC Support

```yaml
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: home-lan
  namespace: <target-namespace>
spec:
  config: '{
    "cniVersion": "0.3.1",
    "plugins": [
      {
        "type": "macvlan",
        "capabilities": { "ips": true },
        "master": "enp0s31f6",
        "mode": "bridge",
        "ipam": {
          "type": "static",
          "routes": [
            {
              "dst": "0.0.0.0/0",
              "gw": "192.168.2.1"
            }
          ]
        }
      },
      {
        "capabilities": { "mac": true },
        "type": "tuning"
      }
    ]
  }'
```

Key points:
- `"type": "macvlan"` -- creates the macvlan interface
- `"capabilities": { "ips": true }` -- enables per-pod IP override via annotation
- `"master": "enp0s31f6"` -- the host NIC (your cluster uses this on all standard nodes)
- `"mode": "bridge"` -- allows macvlan interfaces on the same host to communicate
- `"type": "tuning"` with `"capabilities": { "mac": true }` -- enables per-pod MAC override via annotation
- `"ipam": { "type": "static" }` -- static IP assignment (per-pod via annotation)

### Pod Annotation for Static MAC + IP

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: my-pod
  annotations:
    k8s.v1.cni.cncf.io/networks: '[
      {
        "name": "home-lan",
        "ips": ["192.168.2.80/24"],
        "mac": "c2:b0:57:49:47:f1",
        "gateway": ["192.168.2.1"]
      }
    ]'
```

### Sources
- [CNI macvlan plugin spec](https://www.cni.dev/plugins/current/main/macvlan/)
- [Multus macvlan-pod.yml example](https://github.com/k8snetworkplumbingwg/multus-cni/blob/master/examples/macvlan-pod.yml)
- [OpenShift macvlan configuration docs](https://access.redhat.com/documentation/en-us/openshift_container_platform/4.7/html/networking/multiple-networks)
- [Multus how-to-use.md](https://github.com/k8snetworkplumbingwg/multus-cni/blob/master/docs/how-to-use.md)

---

## 4. Multus + Macvlan for a Pod with Specific MAC and IP on 192.168.2.0/24

### Yes, This Is Fully Supported

You can give a pod a secondary interface on 192.168.2.0/24 with a hardcoded MAC and IP using Multus + macvlan + tuning plugin.

### Prerequisites for This Cluster

1. **Multus is already deployed** (thin plugin, in `kube-system`)
2. **macvlan plugin is already installed** by the `install-cni-plugins` init container
3. **tuning plugin is NOT installed** -- the init container at `kubernetes/overlays/homelab/infrastructure/multus-cni/resources/daemonset.yaml` line 66 only downloads `./macvlan ./ipvlan`. You need to add `./tuning` to the tar extract list.

### Required Change to DaemonSet

In the `install-cni-plugins` init container, change:
```
| tar xzf - -C /host/opt/cni/bin ./macvlan ./ipvlan
```
to:
```
| tar xzf - -C /host/opt/cni/bin ./macvlan ./ipvlan ./tuning
```

### Complete Working Example for 192.168.2.0/24

**NetworkAttachmentDefinition:**
```yaml
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: home-lan
  namespace: default  # or target namespace
  labels:
    app.kubernetes.io/name: home-lan
    app.kubernetes.io/component: network
    app.kubernetes.io/part-of: homelab
    app.kubernetes.io/managed-by: argocd
spec:
  config: '{
    "cniVersion": "0.3.1",
    "plugins": [
      {
        "type": "macvlan",
        "capabilities": { "ips": true },
        "master": "enp0s31f6",
        "mode": "bridge",
        "ipam": {
          "type": "static",
          "routes": [
            {
              "dst": "0.0.0.0/0",
              "gw": "192.168.2.1"
            }
          ]
        }
      },
      {
        "capabilities": { "mac": true },
        "type": "tuning"
      }
    ]
  }'
```

**Pod using it:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: gateway-pod
  annotations:
    k8s.v1.cni.cncf.io/networks: '[
      {
        "name": "home-lan",
        "ips": ["192.168.2.80/24"],
        "mac": "02:42:c0:a8:02:50",
        "gateway": ["192.168.2.1"]
      }
    ]'
spec:
  containers:
    - name: app
      image: nginx:1.27
```

This pod gets:
- **eth0**: normal Cilium-managed cluster network (primary)
- **net1**: macvlan interface on 192.168.2.0/24 with IP 192.168.2.80 and MAC 02:42:c0:a8:02:50

### MAC Address Selection

Use a locally-administered MAC address (bit 1 of first octet set = `x2:xx:xx:xx:xx:xx`, `x6:xx:xx:xx:xx:xx`, `xA:xx:xx:xx:xx:xx`, or `xE:xx:xx:xx:xx:xx`). This avoids collision with real hardware OUIs. Example: `02:42:c0:a8:02:50`.

### Why This Solves the FritzBox Problem

With a **stable MAC address on the macvlan interface**:
1. FritzBox sees a consistent device (same MAC always)
2. Port forwarding rule stays bound to that device entry
3. No ARP cache confusion on failover -- the MAC never changes
4. The pod can be scheduled on any node (macvlan creates the interface wherever the pod lands)
5. FritzBox can assign a static DHCP reservation by MAC (or you use static IP via annotation)

### Caveats

- **Node-local communication**: macvlan in bridge mode prevents the pod from talking to the host it runs on via the macvlan interface (macvlan limitation). Use the primary (eth0/Cilium) interface for cluster-internal traffic.
- **Node affinity**: The `master` interface (`enp0s31f6`) must exist on the node where the pod is scheduled. All standard nodes in this cluster have it. The GPU node uses `enp0s20f0u2` -- if the pod could land there, you would need a separate NetworkAttachmentDefinition or a node selector.
- **IP conflict avoidance**: The static IP (e.g., 192.168.2.80) must be outside the FritzBox DHCP range or reserved in the FritzBox.
- **Single pod per IP/MAC**: Unlike Cilium L2 with leader election, this is a single pod with a fixed identity. No HA failover unless you build it (e.g., via a Deployment with replicas=1 + PDB).

### Sources
- [Multus macvlan-pod.yml example](https://github.com/k8snetworkplumbingwg/multus-cni/blob/master/examples/macvlan-pod.yml)
- [CNI macvlan plugin spec](https://www.cni.dev/plugins/current/main/macvlan/)
- [GitHub multus-cni #266 - set mac address to interface](https://github.com/intel/multus-cni/issues/266)
- [StarlingX macvlan plugin docs](https://docs.starlingx.io/usertasks/kubernetes/macvlan-plugin-e631cca21ffb.html)
