# Runbook: DRBD VLAN 110 Binding (PR #2a)

**Executed**: 2026-04-12  
**Cluster**: homelab  
**Scope**: All 6 NVMe storage nodes (node-01..06), DRBD replication migrated from pod IPs
to VLAN 110 storage addresses (see `cluster.yaml` for IP map).

---

## Summary

DRBD/LINSTOR replication traffic was migrated from Cilium WireGuard pod IPs to dedicated
VLAN 110 addresses. This required resolving two unexpected blockers: MAC-spreading via `br-vm`
phantom sub-interfaces, and a LINSTOR-generated auth mismatch for diskless client resources.

**Outcome**: All 6 storage nodes bound to VLAN 110. All DRBD connections `Connected`,
`quorum: yes`, `blocked: no`, peer addresses on `enp0s31f6.110` subnet.

---

## Phase 1 — Pre-flight

| Step | Command | Expected result | Tag |
|------|---------|-----------------|-----|
| VLAN 110 link state on all nodes | `talos_read_file /sys/class/net/enp0s31f6.110/operstate` | `up` on all 6 | `[AUTOMATE]` |
| VLAN 110 addresses assigned | `talos_get NodeAddress` | storage VLAN address on each node | `[AUTOMATE]` |
| ARP table VLAN 110 peers | `talos_read_file /proc/net/arp` | 5 peer entries via `enp0s31f6.110` on each node | `[AUTOMATE]` |
| Piraeus operator health | Pod Running, lease held | Operator healthy | `[AUTOMATE]` |
| Current DRBD peer addresses | `drbdsetup show` in satellite pod | Pod IPs before migration | `[AUTOMATE]` |
| etcd snapshot | `talos_etcd_snapshot` on first CP node | Completed | `[MANUAL]` |

---

## Phase 2 — Register VLAN 110 Net Interfaces in LINSTOR

**[SEMI-AUTO]** — deterministic commands, one per node, requires LINSTOR controller pod name.

For each storage node, exec into the LINSTOR controller pod:

```bash
CTRL=$(kubectl get pod -n piraeus-datastore -l app.kubernetes.io/component=linstor-controller \
  -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n piraeus-datastore "$CTRL" -- \
  linstor node interface create <node-name> storage-vlan110 <node-vlan110-address>
```

Node name → VLAN 110 address mapping is in `cluster.yaml` under `nodes[].vlan110_ip`.

**Verify**: `kubectl linstor node interface list` → both `default-ipv4` and `storage-vlan110`
per node.

**Why imperative**: The Piraeus Operator CRD does not expose a declarative way to register
LINSTOR net interfaces. The operator will NOT delete interfaces whose name is absent from
`Aux/piraeus.io/configured-interfaces` (currently `["default-ipv4"]`). Source:
`pkg/linstorhelper/client.go`.

**Gap**: Interfaces are lost on etcd restore or new node addition — must re-register. DRBD
silently falls back to `default-ipv4` (pod IPs) if `storage-vlan110` is absent.

---

## Phase 3 — LinstorNodeConnection CR

**[AUTOMATE]** — GitOps-managed, idempotent.

File: `kubernetes/overlays/homelab/infrastructure/piraeus-operator/resources/linstor-node-connection.yaml`

Declares DRBD paths using the `storage-vlan110` net interface for all NVMe nodes
(matched via `feature.node.kubernetes.io/storage-nvme.present: Exists`).

---

## Phase 4 — PrefNic on LinstorSatelliteConfiguration

**[AUTOMATE]** — GitOps-managed.

Add `spec.properties: [{name: PrefNic, value: storage-vlan110}]` to
`linstor-satellite-configuration.yaml`. Instructs LINSTOR to prefer the `storage-vlan110`
interface for all DRBD connections from matching satellites.

---

## Phase 5 — PrefNic on StorageClasses

**[AUTOMATE]** — GitOps-managed. Applied to `storage-class.yaml` and `storage-class-vm.yaml`.
Not `storage-class-noreplica.yaml` (single-replica, PrefNic is no-op).

CSI passthrough property: `property.linstor.csi.linbit.com/PrefNic: storage-vlan110`.

---

## Blocker #1: hostNetwork Required for Satellite

**Symptom**: After PrefNic was set, DRBD reported `EADDRNOTAVAIL (err=-99)` on all nodes.
`drbdsetup show` showed VLAN 110 addresses but all connections stayed in `Connecting`.

**Root cause**: DRBD creates TCP sockets in the network namespace of the calling process
(satellite container). Without `hostNetwork: true`, the satellite pod runs in its own netns
which only has the pod IP — the VLAN 110 host addresses are invisible to it.

**Fix**: Set `hostNetwork: true` + `dnsPolicy: ClusterFirstWithHostNet` on
`LinstorSatelliteConfiguration`. All satellite pods restarted. `[AUTOMATE]` — add to
`linstor-satellite-configuration.yaml` before applying PrefNic.

**Secondary effect**: With `hostNetwork: true`, Cilium classifies satellite traffic as
`remote-node`/`kube-apiserver`/`host` entities instead of pod endpoints. The existing
`toEndpoints: linstor-satellite` rule in `cnp-linstor-controller.yaml` no longer matches.
Fix: add `toEntities: [remote-node, kube-apiserver, host]` egress on port 3367. `[AUTOMATE]`.

---

## Blocker #2: MAC-Spreading via `br-vm` on KubeVirt Worker Nodes

**Symptom**: After hostNetwork fix, node-06 DRBD connected immediately. Nodes 04 and 05
stayed in `Connecting` state. ARP entries for VLAN 110 addresses showed `INCOMPLETE`.

**Root cause**: KubeVirt's `br-vm` bridge inherits the MAC of `enp0s31f6.100`, which
inherits from `enp0s31f6`. A `deviceSelector: {hardwareAddr: X}` without a `driver:` filter
matches `br-vm` (same MAC as the physical NIC, driver: bridge). When `VLANConfig` creates
`enp0s31f6.110`, Talos also creates `br-vm.110` as a phantom VLAN sub-interface.

Result: two interfaces (`enp0s31f6.110` and `br-vm.110`) both claimed the VLAN 110 address,
causing duplicate ARP responses. DRBD connections failed because the kernel could not
determine the correct path for the VLAN 110 peer address.

**Why node-06 worked**: `br-vm.110` phantom interface was absent on node-06 at the time of
VLAN 110 config application (timing difference at bridge startup). The fix prevents recurrence
on all three workers.

**Evidence**:
- `talos_get AddressStatus`: both `enp0s31f6.110/<storage-addr>` and `br-vm.110/<mgmt-addr>`
  present on node-04 and node-05
- `/proc/net/arp`: peer VLAN 110 address appeared twice — via `enp0s31f6.110` AND `br-vm.110`
- `drbdsetup show` showed VLAN 110 addresses correctly — config was right, ARP was wrong

**Fix**: Add `driver: e1000e` to `deviceSelector` in `talos/nodes/node-0{4,5,6}.yaml`:
```yaml
deviceSelector:
  hardwareAddr: <mac>
  driver: e1000e   # excludes br-vm (driver: bridge) from MAC match
```

Apply with `talos_apply_config dry_run=false` (no reboot required — net config change only).
Talos reconciler immediately removed phantom IPs. `[AUTOMATE]`.

**Reference**: siderolabs/talos#8709 (MAC-spreading via deviceSelector, closed `not_planned`).

---

## Blocker #3: DRBD Auth Mismatch for Diskless Client Resources

**Symptom**: After ARP fix, all DRBD resources connected except one (`data-loki-backend-1`
PVC on node-04). Both connections showed `StandAlone`. `dmesg` in satellite pod showed:
```
drbd <resource> node-05: Authentication of peer failed
drbd <resource> node-05: expected AuthChallenge packet, received: P_PROTOCOL (0x000b)
```

**Root cause**: LINSTOR v1.33.1 inconsistently generated `.res` files for this resource:
- The diskless client node had `cram-hmac-alg sha1; shared-secret "<X>"` in global `net {}`
- The server nodes had NO auth in their `net {}` block

This auth asymmetry occurs when a diskless client resource is added to an existing replicated
resource — LINSTOR regenerates the diskless node's config with the resource's internal
shared-secret, but does NOT back-propagate the secret to existing server nodes' configs.
This is a LINSTOR v1.33.1 bug.

**Detection**:
```bash
for node in node-01 node-02 node-03 node-04 node-05 node-06; do
  pod="linstor-satellite.${node}-*"
  secret=$(kubectl exec -n piraeus-datastore -l app.kubernetes.io/component=linstor-satellite \
    --field-selector spec.nodeName=$node -- \
    grep -o 'shared-secret.*' /var/lib/linstor.d/<resource-name>.res 2>/dev/null || echo "none")
  echo "$node: $secret"
done
```
If output is inconsistent (some nodes have secret, some don't) → apply the fix.

**Fix**: Set the secret explicitly on the resource-definition — LINSTOR propagates to all nodes:
```bash
SECRET=$(kubectl exec -n piraeus-datastore <satellite-pod-with-secret> -- \
  grep 'shared-secret' /var/lib/linstor.d/<resource-name>.res | awk '{print $2}' | tr -d '"')
kubectl linstor resource-definition set-property <resource-name> \
  DrbdOptions/Net/shared-secret "$SECRET"
kubectl linstor resource-definition set-property <resource-name> \
  DrbdOptions/Net/cram-hmac-alg "sha1"
```

LINSTOR immediately adjusts all nodes. DRBD reconnects within seconds. `[SEMI-AUTO]`.

---

## Phase 6 — Post-Fix Verification

| Check | Command | Expected |
|-------|---------|----------|
| DRBD peer addresses | `drbdsetup show` in satellite pod | `_this_host ipv4 <vlan110-addr>:700N` |
| All connections | `drbdsetup status --verbose` | `connection:Connected, quorum:yes, blocked:no` |
| LINSTOR resource state | `kubectl linstor resource list --all` | All `Ok`, all `UpToDate/Diskless/TieBreaker` |
| ARP table | `talos_read_file /proc/net/arp` | All VLAN 110 entries `0x2` (COMPLETE) via `enp0s31f6.110` only |
| RX traffic on VLAN interface | `/sys/class/net/enp0s31f6.110/statistics/rx_bytes` | Non-zero on all nodes |

---

## Timing Data

| Phase | Duration | Notes |
|-------|----------|-------|
| Phase 1 (pre-flight) | ~10 min | etcd snapshot included |
| Phase 2 (LINSTOR net interface registration) | ~5 min | 6 nodes × 1 command |
| Phase 3-5 (GitOps: LinstorNodeConnection + PrefNic) | ~15 min | ArgoCD sync included |
| Blocker #1 diagnosis + fix | ~30 min | netns / EADDRNOTAVAIL root cause |
| Blocker #2 diagnosis + fix | ~45 min | Multi-session; MAC-spreading root cause |
| Blocker #3 diagnosis + fix | ~20 min | DRBD auth mismatch via .res file comparison |
| Total (wall clock) | ~2-3h | Multiple sessions over 2026-04-11 and 2026-04-12 |

---

## Rollback Procedure (strict reverse order)

1. Remove `PrefNic` from StorageClasses (`storage-class.yaml`, `storage-class-vm.yaml`)
2. Remove `PrefNic` from `LinstorSatelliteConfiguration`
3. Delete `LinstorNodeConnection` CR (`storage-vlan110`)
4. Wait for DRBD connections to re-establish on `default-ipv4` — verify via `drbdsetup status`
5. Imperative cleanup (last — don't remove interface while connections may reference it):
   ```bash
   CTRL=$(kubectl get pod -n piraeus-datastore -l app.kubernetes.io/component=linstor-controller \
     -o jsonpath='{.items[0].metadata.name}')
   for node in node-01 node-02 node-03 node-04 node-05 node-06; do
     kubectl exec -n piraeus-datastore "$CTRL" -- \
       linstor node interface delete "$node" storage-vlan110
   done
   ```

**Note**: `storage-vlan110` LINSTOR interfaces are NOT GitOps-managed. They survive rollback
of the GitOps resources but are lost on etcd restore or new node addition — must re-register.

---

## Follow-up Items

| Item | Priority | Notes |
|------|----------|-------|
| **PR #2b**: DRBD TLS (`transport_tls`) | High | `DrbdOptions/Net/tls` does not exist in LINSTOR v1.33.1; research `tlshd` property path |
| **PR #3**: `bpf.vlanBypass` for VLANs 120/130 + L2 announcements | Medium | Add when tenant VLANs activated |
| **Automate auth-mismatch detection** | Low | Run after any new diskless resource creation on new nodes |
| **Declarative LINSTOR net interfaces** | Low | Operator enhancement; current gap — interfaces lost on etcd restore |

---

## Automation Classification Summary

| Step | Tag | Reason |
|------|-----|--------|
| VLAN 110 link/address/ARP pre-flight | `[AUTOMATE]` | Fully deterministic MCP queries |
| LINSTOR net interface registration | `[SEMI-AUTO]` | Deterministic commands, requires IP map lookup |
| LinstorNodeConnection + PrefNic (GitOps) | `[AUTOMATE]` | Already GitOps-managed |
| DRBD auth mismatch detection and fix | `[SEMI-AUTO]` | Detection needs per-resource scan; fix deterministic once identified |
| `driver: e1000e` in deviceSelector | `[AUTOMATE]` | One-time config fix; already in node YAMLs |
| Post-fix verification | `[AUTOMATE]` | All checks are deterministic MCP/kubectl queries |
