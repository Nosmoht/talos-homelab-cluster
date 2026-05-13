---
name: onboard-worker-node
description: End-to-end onboarding of a new Talos standard worker — from physical install through Kubernetes Ready and bundled commit. Standard-worker scope only (CP / GPU / Pi out of scope).
argument-hint: <node-name>
disable-model-invocation: true
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Grep
  - mcp__talos__talos_version
  - mcp__talos__talos_health
  - mcp__talos__talos_reset
  - mcp__kubernetes-mcp-server__resources_list
  - mcp__kubernetes-mcp-server__resources_get
  - mcp__kubernetes-mcp-server__pods_list_in_namespace
  - mcp__kubernetes-mcp-server__events_list
  - mcp__kubernetes-mcp-server__nodes_top
---

# Onboard Worker Node

End-to-end onboarding of a fresh standard-worker into the homelab Talos cluster. The skill orchestrates Discovery → Render → Apply → Verify → Commit, with an explicit Rollback gate before Commit.

## Scope guard (per `.claude/rules/talos-config.md §Patch Inheritance Matrix`)

This skill is **standard-worker only**. Stop and redirect if the user passes a node-name that resolves under any of:

- `cluster.yaml.nodes.control_plane[]` → CP-Node: different patch stack (controlplane, VIP, etcd); not onboarded the same way.
- `cluster.yaml.nodes.gpu_workers[]` → GPU-Node: GPU schematic + USB-NIC, no DRBD VLAN, NVIDIA modules.
- `cluster.yaml.nodes.pi_nodes[]` → Pi-Node: ARM, USB boot, firewall patch, sole-WAN-entrypoint role.

For those roles, document a role-specific onboarding runbook separately. This skill rejects.

## Reference files

Read before proceeding:
- `references/runbook.md` — Troubleshooting, rollback details, LINSTOR/Cilium failure modes.
- `.claude/rules/talos-config.md §DRBD Replication VLAN` — IP scheme.
- `.claude/rules/talos-config.md §Patch Inheritance Matrix` — which patches the new node will inherit.
- `.claude/rules/kubernetes-mcp-first.md` — MCP-vs-CLI policy for post-join verification.

## Phases

### P0 Preflight

Confirm with the user:

- Hardware physically installed, BIOS settings: **no SecureBoot** (homelab Hard Constraint), IOMMU enabled, **no `debugfs=off`** (homelab Hard Constraint).
- Talos Factory USB with **standard schematic** (`SCHEMATIC_ID` from `talos/.schematic-ids.mk`) booted.
- The planned LAN-IP is reachable on the LAN and is not in use by anything else (`arp -na | grep <ip>` empty).
- Hostname slot `node-XX` decided.

If any preflight item is unknown, stop and ask.

### P1 cluster.yaml — register node identity

Add a new entry under `.nodes.workers[]`:

```yaml
- name: node-XX
  ip: <lan-ip>
  nic: enp0s31f6
```

This is the minimum that `make` needs to auto-generate `install-node-XX`, `apply-node-XX`, `dry-run-node-XX`, `upgrade-node-XX` targets via the `$(foreach) $(eval)` expansion (Makefile lines 282-336).

Verify:
```bash
yq -e ".nodes.workers[] | select(.name == \"<node>\")" cluster.yaml
make -C talos -n install-<node> 2>&1 | head -1   # confirms target exists
```

### P2 Discovery + Template-Render

Invoke `/discover-maintenance-node <node>` (see `.claude/skills/discover-maintenance-node/SKILL.md`). That skill:

1. Reads `cluster.yaml` for name/ip/nic/gateway.
2. Probes the maintenance API for MAC, install-disk by-path, NIC driver.
3. Computes DRBD-IP via the §DRBD Replication VLAN scheme (LAN host-octet − 60).
4. Renders `talos/nodes/<node>.yaml` from `talos/nodes/_template.yaml.tmpl`.
5. Shows the diff for user confirmation.

This skill does NOT write to `cluster.yaml` (per A1 rollen-trennung).

### P3 Sanity-check the rendered file

```bash
yq eval-all '.' "talos/nodes/<node>.yaml" >/dev/null  # YAML syntax
test "$(yq eval-all '. | documentIndex' "talos/nodes/<node>.yaml" | wc -l)" -eq 3  # 3 docs
```

The full Talos-validation (`talosctl validate --mode metal`) happens against the **generated** file in P4, not against the patch.

### P4 gen-configs + validate

```bash
make -C talos gen-configs
make -C talos validate-generated
```

If `validate-generated` fails for the new node, stop and inspect `_out/<cluster>/worker/<node>.yaml`. Common causes: malformed envsubst placeholder, MAC collision, install-disk by-path doesn't match any block device.

### P5 Initial apply (maintenance mode, `--insecure`)

```bash
make -C talos install-<node>
```

CLI-only — the MCP server cannot reach a maintenance-mode node (see `.claude/rules/talos-mcp-first.md`). This command runs `talosctl apply-config --insecure` against the maintenance API and triggers the install + first boot. Wait ~60-180 seconds for the node to reboot and re-emerge with the new config.

### P6 CSR approve (post-boot)

```
mcp__kubernetes-mcp-server__resources_list apiVersion=certificates.k8s.io/v1 kind=CertificateSigningRequest
```

If `cert-approver` is healthy, kubelet CSRs are auto-approved. If pending CSRs remain for the new node after 60 seconds, approve manually:

```bash
kubectl -n kube-system get csr | grep <node>
kubectl certificate approve <csr-name>
```

### P7 Verify cluster join (MCP-only)

```
mcp__kubernetes-mcp-server__resources_get apiVersion=v1 kind=Node name=<node>
# Expect: status.conditions[type=Ready].status == "True"

mcp__kubernetes-mcp-server__pods_list_in_namespace namespace=kube-system labelSelector=k8s-app=cilium
# Expect: cilium pod on <node> Ready

mcp__kubernetes-mcp-server__events_list namespace=kube-system
# Expect: no Warning events for <node>

mcp__talos__talos_health nodes=[<ip>]
# Expect: healthy
```

NFD storage label (if the node has NVMe — verify via Probe 2 output from P2 / `feature.node.kubernetes.io/storage-nvme.present=true` may appear after ~1 minute).

LINSTOR satellite registration (the new worker auto-registers as a Piraeus satellite via the LINSTOR cluster — verify with CLI:
```bash
kubectl linstor node list
```

### P8 Rollback gate

If P5-P7 fail (kubelet CSR pending > 5 min, Cilium-Agent crashloop, Talos `talos_health` not healthy, LINSTOR satellite not registering), rollback:

```
mcp__talos__talos_reset confirm=true nodes=[<ip>] system_labels_to_wipe=["EPHEMERAL"]
```

Then:
```bash
git checkout -- cluster.yaml talos/nodes/<node>.yaml
rm -f talos/nodes/<node>.yaml   # if it was untracked
```

Investigate root cause via Probe re-run with `/discover-maintenance-node` and the diagnostic table in `references/runbook.md`. Do NOT commit a partial onboarding.

### P9 Commit

Only after P7 fully green:

```bash
git add cluster.yaml talos/nodes/<node>.yaml
git commit -m "feat(talos): onboard <node> as standard worker"
```

Body should describe: hardware class (from P2 Probe 3 driver), DRBD-IP (derived), node-role. Include `Refs: <issue-url>` trailer if a tracking issue exists (per CLAUDE.md commit policy). No trailer if direct user-prompted onboarding.

## Hard Rules

- Never apply config to a node that is in maintenance mode via the MCP path. MCP requires TLS+talosconfig. Use `make install-<node>` (= `talosctl apply-config --insecure`) for first apply.
- Never commit `cluster.yaml` AND `talos/nodes/<node>.yaml` separately. They are a bundle — if one is reverted, the cluster diverges.
- Never skip P3 sanity-check. A malformed Talos patch can render `make gen-configs` failure across ALL nodes, blocking other work.
- Never proceed to P9 without all P7 checks green. Partial onboarding leaves the node Ready-but-empty (no DRBD, no NFD label) and silently degrades cluster capacity.
