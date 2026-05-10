---
paths:
  - "talos/patches/**"
  - "talos/Makefile"
  - "talos/.schematic-ids.mk"
---

# Talos Config Generation & Makefile

## Patch Files
- `talos/patches/common.yaml` — shared: CNI none, proxy disabled, kubePrism, DRBD modules, kubelet args, NTP, search domain
- `talos/patches/controlplane.yaml` — CP settings, extraManifests (cert-approver, metrics-server, Cilium URL)
  - **extraManifests are URL-cached**: when changing the *content* served at an existing extraManifest URL (e.g., editing the rendered `kubernetes/bootstrap/cilium/cilium.yaml`), bump the `?v=<n>` cache-bust query param on the URL here, regenerate configs, and re-apply to ALL CP nodes BEFORE `upgrade-k8s`. Without the bump, nodes serve the stale cached manifest and admission denials (Kyverno, etc.) reappear unchanged.
- `talos/patches/worker-gpu.yaml` — NVIDIA kernel modules (`NVreg_UsePageAttributeTable=1`), no sysctls (Talos KSPP defaults)
- `rp_filter` and `log_martians` must be `0` in `common.yaml` — Cilium BPF bypasses kernel FIB, causing false-positive martian drops

## Config Generation Flow
- `talos/secrets.yaml` is SOPS-encrypted; `gen-configs` auto-decrypts to `talos/.secrets.dec.yaml` (gitignored)
- Patches applied in order: `common.yaml` → role patch → node patch (later patches override scalars)
- Install images NOT in patch files — injected as inline `--config-patch` from `INSTALL_IMAGE`/`GPU_INSTALL_IMAGE`
- `--config-patch` APPENDS arrays, not replaces — don't duplicate array entries across common and role patches
- HostnameConfig quirk: use `auto: null` in node patches + yq post-processing to remove `auto: stable`
- Strategic merge on interfaces APPENDS arrays — doesn't merge by deviceSelector; keep VIP in per-node patches

## Interface Patches

- **VLAN sub-interfaces on shared-MAC parents: use `kind: VLANConfig` with a named `interface:` entry — never `vlans:` nested under `deviceSelector`.**
  When the parent NIC's MAC is shared with a bridge or tap device (`br-vm`, KubeVirt, libvirt, Docker), `deviceSelector.hardwareAddr` matches every interface sharing that MAC (bridge, taps, and VLAN sub-interfaces themselves). Result: MAC-spreading — addresses assigned to every match, the API VIP duplicated onto VLAN sub-interfaces, phantom `br-vm.N` artifacts. This is a documented design limitation ([siderolabs/talos#8709](https://github.com/siderolabs/talos/issues/8709), closed `not_planned`). `VLANConfig` was added in Talos v1.12 ([#10961](https://github.com/siderolabs/talos/issues/10961)) and is the [recommended v1.12 pattern](https://www.talos.dev/v1.12/talos-guides/network/vlans/).
  ```yaml
  # in talos/nodes/<node>.yaml — named interface entry carries the address
  - interface: enp0s31f6.110
    addresses: [192.168.110.X/24]
  ---
  # in talos/patches/drbd.yaml (or worker patch) — VLANConfig attaches VLAN to parent
  apiVersion: v1alpha1
  kind: VLANConfig
  name: enp0s31f6.110
  vlanID: 110
  vlanMode: 802.1q
  parent: enp0s31f6
  up: true
  ```
  **Alternative**: narrow `deviceSelector` with both `hardwareAddr:` and `driver:` to exclude bridge/tap devices — acceptable but `VLANConfig` is cleaner.

## Makefile Targets (`talos/Makefile`)

Orchestration targets (use `make`):
- `make gen-configs` — decrypt secrets + generate all node configs with patch layering
- `make schematics` — create factory schematics via Image Factory API, write IDs to `.schematic-ids.mk`
- `make cilium-bootstrap` / `make cilium-bootstrap-check` — render and validate Cilium bootstrap manifest
- `make install-<node>` — initial config apply to fresh node (`--insecure`)
- `make bootstrap` — bootstrap etcd on node-01
- `make clean` / `make talosconfig` / `make gen-secrets`

Direct talosctl (do NOT use make wrappers):
> **MCP-First**: For queries (version, health, get, etcd status, logs, dmesg) and operations (validate, apply_config, patch_config, service_action, upgrade, reboot, rollback, etcd_snapshot), use Talos MCP tools.
> The commands below are listed because they have no MCP equivalent or are CLI-only operations.
> See `.claude/rules/talos-mcp-first.md`.
- Apply config: `talosctl apply-config -n <ip> -e <ip> -f talos/generated/<role>/<node>.yaml`
- Dry-run: `talosctl apply-config -n <ip> -e <ip> -f talos/generated/<role>/<node>.yaml --dry-run`
- Upgrade: `talosctl apply-config ...` then `talosctl upgrade -n <ip> -e <ip> --image <install-image> --preserve --wait --timeout 10m`
- Upgrade K8s: `talosctl upgrade-k8s --to <version> -n <ip> -e <ip>` (run `make -C talos cilium-bootstrap-check` first)
- Validate: `talosctl validate --config <file> --mode metal --strict`

Install image resolution: `factory.talos.dev/metal-installer/<SCHEMATIC_ID>:<TALOS_VERSION>` (read from `.schematic-ids.mk` + `versions.mk`)

## Important Behaviors
- Boot parameter changes require `talosctl upgrade` — `talosctl apply-config` only activates sysctls
- `.schematic-ids.mk` tracks IDs; Factory API only called when schematic YAML modified
- `.versions.stamp` tracks `TALOS_VERSION` + `KUBERNETES_VERSION` — triggers config regeneration
- Changing `TALOS_VERSION` in Makefile is sufficient to update all install image URLs
- Makefile ordering: `config-path` helper MUST be defined before any `$(eval)` template that references it
- `talosctl upgrade-k8s` requires `-n <node-ip> -e <node-ip>` — `--endpoint` is a different flag (proxy endpoint, not node target)
- `talosctl upgrade-k8s` does NOT reliably update existing ConfigMaps shipped via `extraManifests` (e.g. `cilium-config`). For Cilium specifically, see `.claude/rules/cilium-bootstrap.md` §`upgrade-k8s` Does Not Reliably Update Existing ConfigMaps for the SSA workaround.

## Change Classes
- Sysctl/config changes: `talosctl apply-config -n <ip> -e <ip> -f talos/generated/<role>/<node>.yaml`.
- Boot args / extensions / image changes: `talosctl apply-config` then `talosctl upgrade -n <ip> -e <ip> --image <install-image> --preserve --wait --timeout 10m`.
- Cluster-wide config refresh: regenerate first (`make -C talos gen-configs`).
- Install image resolution: read `talos/.schematic-ids.mk` + `talos/versions.mk` to construct `factory.talos.dev/metal-installer/<SCHEMATIC_ID>:<TALOS_VERSION>`.

## Safety Checklist
1. Confirm node role and impact (control plane vs worker vs GPU worker).
2. For reboot/upgrade, verify workload and DRBD placement before action.
3. Validate generated config exists under `talos/generated/` before apply.
4. Use dry-run where possible before apply.

## Node Recovery
- Etcd member removed: `talosctl reset --system-labels-to-wipe EPHEMERAL --reboot --graceful=false`.
- Learner promotion is automatic (~1–2 min) after EPHEMERAL reset.
- For DRBD-specific recovery (D-state deadlock, unmount lock), see `.claude/rules/linstor-storage-guardrails.md` §Known Failure Modes and the cross-linked `.claude/rules/k8s-csi.md` for the general CSI pattern.

## API Behaviour
- `talosctl apply-config` with unchanged config is a no-op.
- `kubectl delete pod` on Talos static pods (control-plane components) only recreates the mirror pod — the real container keeps running. Use `talosctl service <name> restart` instead where supported.
- `kube-apiserver` `$(POD_IP)` env var is frozen at container creation; survives kubelet restarts.
- `talosctl service etcd restart` is NOT supported — etcd cannot be restarted via the Talos API; node reboot is the only path.
- Maintenance mode (`--insecure`) only supports: `version`, `get disks`, `apply-config`.
- `talosctl disks` is deprecated — use `get disks`, `get systemdisk`, or `get discoveredvolumes` instead.
