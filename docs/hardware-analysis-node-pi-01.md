# Hardware Analysis: node-pi-01

> **Date:** 2026-05-14
> **Talos:** v1.12.6 | **Kubernetes:** v1.35.0 | **Architecture:** arm64
> **Node IP:** see `cluster.yaml.nodes.pi_nodes[].ip` | **Role:** WAN edge / sole public ingress
> **Status:** Stub — taint-isolated (`homelab.io/pi-reserved=true:NoSchedule`); live-probe via talos-mcp pending. Update when probe possible.

---

## 1. System Overview

| Property | Value | Source |
|----------|-------|--------|
| Model | Raspberry Pi 4B | AGENTS.md §Cluster Overview |
| Architecture | arm64 (aarch64) | `talos-factory-schematic-pi.yaml` overlay `rpi_generic` |
| Talos image | `siderolabs/sbc-raspberrypi` | `talos-factory-schematic-pi.yaml:4` |
| Boot Disk | USB SSD — EDILOCA EN605 256 GB | `talos/nodes/node-pi-01.yaml:3` (`/dev/disk/by-id/usb-EDILOCA_EN605_256GB_…`) |
| Primary NIC MAC | dc:a6:32:c4:57:e8 (Raspberry Pi Foundation OUI) | `talos/nodes/node-pi-01.yaml:7` |
| Primary NIC IF | end0 (built-in 1G Ethernet) | inferred from `talos/patches/pi-firewall.yaml` interface refs |
| RAM | 4 GB or 8 GB (Pi 4B variants) | hardware-specific — verify on live probe |
| CPU | Broadcom BCM2711 (4× Cortex-A72, ARMv8) | Raspberry Pi 4B reference hardware |
| Storage interface | USB 3.0 → SSD | by-id path confirms USB-attached EDILOCA NVMe-in-USB-enclosure |

---

## 2. Role & Operational Context

- **Sole WAN entrypoint** since 2026-04-17 — replaces prior macvlan-on-pod ingress that became structurally unsupported on FRITZ!OS ≥ 8.25. See `docs/adr-pi-sole-public-ingress.md` and `docs/2026-04-15-fritzbox-macvlan-port-forward-exhaustion.md`.
- **hostNetwork nginx stream pod** (`pi-public-ingress`) performs SNI allowlist filtering against `*.homelab.ntbc.io` and L4-proxies to gateway worker nodes.
- **FritzBox port-forward**: TCP/443 directly to `end0` NIC (no macvlan).
- **Taint isolation**: `homelab.io/pi-reserved=true:NoSchedule` (applied via `talos/patches/worker-pi.yaml`) ensures only WAN-edge workloads schedule here.
- **Talos firewall**: default-deny ingress, with rules for TCP/443 WAN (world-open) and TCP/UDP LAN trusted (`talos/patches/pi-firewall.yaml`).
- **Host sysctl**: `net.ipv4.ip_unprivileged_port_start: 443` lets nginx run as uid 101 instead of root.
- **Per-interface rp_filter**: `end0.rp_filter=2` (loose mode) for WAN.

---

## 3. Patch Inheritance (per `.claude/rules/talos-config.md §Patch Inheritance Matrix`)

Pattern-rule `worker/node-pi-%.yaml` applies (Makefile line 165):

1. `talos/patches/common.yaml` — sysctls, kubePrism, kubelet args
2. `_out/homelab/cluster.yaml` (rendered from `cluster.yaml.tmpl`) — NTP server
3. `talos/patches/worker-pi.yaml` — taint, gVisor runtime class
4. `talos/patches/pi-firewall.yaml` — Talos firewall rules, host sysctl, per-iface rp_filter
5. `talos/nodes/node-pi-01.yaml` — install disk, MAC, IP, hostname

Schematic: `PI_SCHEMATIC_ID` (`talos/.schematic-ids.mk`) — ARM-specific kernel args, no NVIDIA / x86 extensions.

---

## 4. Notes

- **No DRBD, no KubeVirt**: Pi is not a storage replication peer and does not host VMs. The `talos/patches/drbd.yaml` and `talos/patches/worker-kubevirt.yaml` are NOT applied to this node by the pattern-rule.
- **No NFD storage labels expected**: USB-attached SSD is not NVMe; LINSTOR satellite would not register usable replication volumes here even if not taint-isolated.
- **Live-probe TODO**: when `talos-mcp` access to taint-isolated nodes is set up (or via direct `talosctl --nodes <ip-from-cluster-yaml> ...`), refresh CPU/RAM details, PCI inventory, and kernel-version snapshot from this stub to a full live analysis.
