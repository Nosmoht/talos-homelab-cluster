---
paths:
  - "talos/nodes/**"
---

# Talos Node Configuration

## Node IP Mapping
Node inventory (names, IPs, roles, NICs) is defined in `cluster.yaml` under `nodes`.
Read that file for the authoritative node-to-IP mapping.
The Makefile (`talos/Makefile`) also contains `IP_<node>` variables that must stay consistent.

## Node Endpoint Usage
- Use explicit node endpoint flags for operational `talosctl` commands: `talosctl -n <node-ip> -e <node-ip> ...`. Do not rely on the API VIP for node-targeted operations — the VIP is suitable for cluster-level reads but several `talosctl` operations either fail through VIP forwarding or behave inconsistently when the cluster is degraded.
- (For the specific case of `talos_apply_config dry_run=true` panicking on fresh interface additions, see `.claude/rules/talos-mcp-first.md` §Apply-Config Gotchas.)

## Node File Structure
- Per-node: `talos/nodes/<name>.yaml` — hostname, static IP, install disk (by-path), VIP (CP nodes only)
- **Always use `hardwareAddr: <mac>`** in deviceSelector — `physical: true` matches ALL NICs, breaks multi-NIC nodes
- node-gpu-01 USB NIC (Realtek RTL8153) needs `siderolabs/realtek-firmware` extension; without it: 5% RX drops
- Install disks use stable `/dev/disk/by-path/` (not `/dev/sda` which shifts with USB)
- Install disks use stable `/dev/disk/by-path/` — check per-node YAML for exact paths
- API VIP (from `cluster.api_vip` in `cluster.yaml`) goes in per-node patches (CP only), NOT role patches (strategic merge appends)

## VLAN Sub-Interface Pattern

For VLAN sub-interfaces on `enp0s31f6` or any NIC whose MAC is shared with a bridge/tap: use `kind: VLANConfig` + a named `interface:` entry in this file for the address. Never use `vlans:` nested under `deviceSelector`. See `.claude/rules/talos-config.md §Interface Patches` for the full pattern, rationale, and upstream issue references.

## Node Operations
- CiliumNode CRDs retain stale IPs after IP change — fix: `kubectl delete ciliumnode <node>` + restart Cilium pod
- Approve kubelet CSRs manually if cert-approver is on unreachable node: `kubectl certificate approve <csr>`
- Config apply changing network interfaces triggers reboot — drain DRBD volumes first
