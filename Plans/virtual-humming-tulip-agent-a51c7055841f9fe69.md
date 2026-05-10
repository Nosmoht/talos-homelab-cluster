# Talos Operations Review: virtual-humming-tulip (Step 0 — `net.ifnames=0`)

## Scope of Review

This review covers Step 0 of the plan from a Talos SRE perspective: adding `net.ifnames=0` to both schematic YAML files and rolling the upgrade across all 7 nodes. The Kubernetes-layer steps (1-7) are out of scope here.

---

## 1. `net.ifnames=0` and Talos NIC Configuration

### Does Talos internally depend on predictable interface names?

**No. This is safe.** All 7 node patches use `deviceSelector.hardwareAddr` (MAC address) for NIC selection — not interface names. Evidence:

- `node-01.yaml`: `hardwareAddr: 6c:4b:90:79:3e:4c`
- `node-04.yaml`: `hardwareAddr: 6c:4b:90:51:99:c7`
- `node-gpu-01.yaml`: `hardwareAddr: 00:e0:3c:68:46:45`

Talos resolves `deviceSelector.hardwareAddr` at runtime to whatever interface name the kernel assigns. Whether the interface is named `enp0s31f6` or `eth0`, the MAC match still works. There are zero references to `enp*` or `eth*` anywhere in `talos/patches/`, `talos/nodes/`, or the Makefile.

The `common.yaml` patch also has no `machine.network.interfaces` block — all interface config is per-node via hardwareAddr.

### DHCP concerns

**No DHCP is used.** Every node has a static IP assignment in its per-node patch (e.g., `addresses: ["192.168.2.61/24"]` with explicit `routes` and `nameservers`). Talos does support DHCP, but this cluster does not use it. No risk here.

### sd-boot bootloader compatibility

**No issue.** `net.ifnames=0` is a kernel command-line parameter, not a bootloader parameter. sd-boot (systemd-boot) passes kernel args to the kernel at boot time — it does not interpret `net.ifnames=0`. Both schematic files already use `bootloader: sd-boot`, and the existing 16-17 kernel args demonstrate this works fine.

### Verdict: SAFE to add `net.ifnames=0` to kernel args

---

## 2. Rolling Upgrade Safety for 7 Nodes

### Correct upgrade sequence

The plan says "rolling `talosctl upgrade` on all 7 nodes" but does not specify order. The correct order is:

1. **Workers first** (node-04, node-05, node-06) — lowest blast radius, no etcd
2. **GPU worker** (node-gpu-01) — medium risk, verify NVIDIA modules reload + USB NIC reconnects
3. **Control plane nodes** (node-03, node-02, node-01) — highest risk, one at a time
   - Upgrade the **non-leader** etcd members first
   - Verify etcd quorum (2/3 healthy) between each CP node
   - Take an etcd snapshot before the first CP node upgrade

**MISSING from plan:** The plan does not specify this ordering. This is a gap that should be documented.

### DRBD drain requirement

**Critical.** Per CLAUDE.md: "Stuck 'shutting down' nodes (D-state on DRBD): only fixable with physical power cycle" and "DRBD CSI volumes in D-state during `unmountPodMounts` phase deadlock the upgrade."

The mitigation documented in CLAUDE.md is:
```
kubectl drain <node> --delete-emptydir-data --ignore-daemonsets --timeout=120s
```
Run this **before** `talosctl upgrade` on any node that has DRBD volumes.

Which nodes have DRBD? Per the Makefile, DRBD is patched into:
- All control plane nodes (node-01..03) via `patches/drbd.yaml`
- All standard workers (node-04..06) via `patches/drbd.yaml`
- GPU node does **not** get `patches/drbd.yaml` (see GPU worker recipe in Makefile line 91-104)

So drain is needed on 6 of 7 nodes. The plan does not mention draining. **This is a significant gap.**

### Can we verify eth0 works before upgrading the next node?

**Yes, this is verifiable per-node.** After each node upgrade:

1. `talosctl -n <ip> -e <ip> get links` — verify `eth0` appears (confirms the kernel booted with `net.ifnames=0` and the NIC was found)
2. `talosctl -n <ip> -e <ip> read /proc/cmdline` — confirm `net.ifnames=0` is in the kernel command line
3. The node's API responding at all (via its static IP) proves the network came up correctly via hardwareAddr MAC match on the renamed `eth0`

This is NOT all-or-nothing. Each node upgrade is independent — if eth0 causes issues on one node, you stop and rollback that node only.

---

## 3. Schematic Change Impact

### Do ALL nodes need upgrade?

**Yes.** Adding `net.ifnames=0` to `extraKernelArgs` changes the schematic hash. Both schematic files must be updated:

- `talos-factory-schematic.yaml` — used by node-01..06 (6 nodes)
- `talos-factory-schematic-gpu.yaml` — used by node-gpu-01 (1 node)

After `make -C talos schematics`, the `SCHEMATIC_ID` and `GPU_SCHEMATIC_ID` in `.schematic-ids.mk` will both change. The install images change for all 7 nodes. Since boot params are baked into the install image, `talosctl apply-config` alone is insufficient — `talosctl upgrade` is required on every node.

The Pi schematic (`talos-factory-schematic-pi.yaml`) is NOT affected — but `node-pi-01` is not in the active cluster (the `PI_NODES` list exists but there is no live Pi node based on environment.yaml).

### Minimum disruption path

There is no way to avoid upgrading all 7 nodes. The schematic change means the install image hash changes. However:

- The upgrade is a **reboot only** — no data loss, no config change, no Kubernetes version change
- Each upgrade takes approximately 3-5 minutes per node (`--wait --timeout 10m`)
- With proper sequencing (workers first, CP last), the cluster remains available throughout
- Total estimated downtime: zero (rolling upgrades), total wall-clock time: ~30-45 minutes for all 7 nodes

**Optimization:** If Multus is only needed on worker nodes, you could theoretically keep the standard schematic unchanged and only add `net.ifnames=0` to the GPU schematic. BUT the plan's goal is to normalize `eth0` across ALL nodes so the NetworkAttachmentDefinition uses `master: "eth0"` universally. This requires all nodes to have `net.ifnames=0`. The plan is correct here.

---

## 4. Rollback Plan

### If `net.ifnames=0` causes issues (network doesn't come up)

**Recovery path exists but requires physical access or IPMI/BMC.**

The problem scenario: a node boots with `net.ifnames=0`, the kernel renames NICs to `eth0`, but Talos somehow fails to match the `hardwareAddr` selector against the renamed interface. The node would be unreachable via network.

**Likelihood: Very low.** The `deviceSelector.hardwareAddr` matches by MAC address at the Linux netlink layer, which is independent of interface naming. The MAC address is a hardware property — it does not change when `net.ifnames=0` renames the interface. Talos uses `hardwareAddr` specifically to avoid name-dependent configuration.

**If it does happen:**

1. **`talosctl rollback`** — requires network access to the node. If the network is down, this is not possible remotely.
2. **Physical power cycle + boot menu** — sd-boot keeps the previous boot entry. On the next boot, you can select the previous image (with the old schematic/kernel args). This requires physical access or a BMC/IPMI interface. The plan does not mention whether these nodes have IPMI.
3. **Maintenance mode** — boot from a Talos ISO/USB, apply the old config with `--insecure`. Requires physical media access.

**Recommended mitigation:** Upgrade ONE worker node first (e.g., node-04). Verify it fully rejoins the cluster with `eth0`. Only then proceed with the remaining nodes. This limits blast radius to a single non-critical worker.

### Reverting the schematic after a problem

1. Remove `net.ifnames=0` from both schematic YAML files
2. `make -C talos schematics` — regenerates the original schematic IDs
3. `make -C talos gen-configs` — regenerates configs with old install images
4. `talosctl upgrade -n <ip> -e <ip> --image <old-install-image> --preserve --wait --timeout 10m` — re-upgrades the node back to the old image

This only works if the node is still reachable. For unreachable nodes, physical access is required.

---

## Summary of Gaps in the Plan

| Gap | Severity | Recommendation |
|-----|----------|----------------|
| No upgrade ordering specified | **High** | Document: workers first (node-04..06), then GPU (node-gpu-01), then CP (node-03, node-02, node-01 — non-leader first) |
| No DRBD drain before upgrade | **High** | Add `kubectl drain <node> --delete-emptydir-data --ignore-daemonsets --timeout=120s` before each upgrade on nodes 01-06 |
| No etcd snapshot before CP upgrades | **Medium** | Add `talosctl -n <cp-ip> -e <cp-ip> etcd snapshot <path>` before first CP upgrade |
| No etcd quorum verification between CP upgrades | **Medium** | Add `talosctl -n <cp-ip> -e <cp-ip> etcd members` check between each CP node |
| No "canary node" strategy | **Medium** | Upgrade node-04 first, fully verify, then proceed |
| No mention of physical access / IPMI for rollback | **Low** | Document whether BMC/IPMI is available on these nodes for emergency recovery |
| `.claude/environment.yaml` NIC names update | **Low** | Plan mentions this but should be explicit about updating `nic: enp0s31f6` to `nic: eth0` for all nodes and `nic: enp0s20f0u2` to `nic: eth0` for GPU |

## Overall Assessment

**Step 0 is fundamentally sound.** The `net.ifnames=0` kernel parameter is safe for this cluster because:

- All node configs use `hardwareAddr` MAC-based NIC selection (no interface name dependencies)
- No DHCP is used (all static IPs)
- sd-boot passes the param transparently
- The change is per-node reversible via `talosctl rollback` (assuming network comes up)

The main risks are operational (DRBD D-state deadlocks during upgrade, etcd quorum loss if CP nodes are upgraded carelessly), not fundamental to the `net.ifnames=0` change itself. These risks exist for ANY `talosctl upgrade` operation and are well-documented in the cluster's operational runbooks.

**Recommendation: Proceed, but amend the plan with the upgrade ordering, DRBD drain steps, and etcd safety checks before execution.**
