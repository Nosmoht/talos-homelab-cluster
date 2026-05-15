# Onboarding Runbook — Troubleshooting & Failure Modes

Companion to `SKILL.md`. Read when a phase fails.

## P-1 Resume detection — common scenarios

| Symptom on re-entry | Resume phase | Notes |
|---|---|---|
| `state.json` present, `phase_completed: PX` | PX+1 | After AskUserQuestion confirmation |
| `state.json` absent, cluster.yaml has entry, no `talos/nodes/<node>.yaml` | P2 | Discover-skill output was lost (untracked + workstation cleaned) |
| `state.json` absent, both source files present, Node `NotFound` in cluster | P4 | gen-configs + apply not yet executed |
| `state.json` absent, both source files present, Node `Ready=True` in cluster | P7 verify + P8 commit | Most common after session interrupt mid-onboarding |
| `cluster.yaml` ahead of HEAD AND `talos/nodes/<node>.yaml` untracked AND node Ready=True | P8 atomic commit | The node-07 (2026-05-14) failure mode |

## Failure mode → diagnostic table

| Symptom | Likely cause | Probe | Fix |
|---|---|---|---|
| **P0 fail:** `git pull --ff-only` errors | Uncommitted changes or non-ff main divergence | `git status --porcelain` | Resolve manually; do NOT proceed with stale main |
| **P0 fail:** OOB-MAC doesn't match probe MAC (P2 will catch) | Operator reading wrong MAC, or wrong device at LAN-IP | Re-read MAC from BIOS / NIC sticker | If still mismatch: abort, physically confirm correct hardware at the LAN-IP |
| **P1 fail:** `make -C talos -n install-<node>` says "No rule" | cluster.yaml entry not parsed by Makefile | `yq -e '.nodes.workers[] | select(.name == "<node>")' cluster.yaml` | Check indentation under `nodes.workers:` — must be a list item with leading `-`; cluster.yaml auto-restored from HEAD via P1 atomicity |
| **P2 fail:** `/discover-maintenance-node` probe 1 returns TLS error | Node is NOT in maintenance mode (already configured) | `talosctl version --nodes <ip>` (without `--insecure`) — if THIS works, node is configured | If node is configured for THIS cluster: skip to P7 verify + P8 commit. If for a DIFFERENT cluster: STOP — wrong physical machine, do not reset |
| **P2 fail:** Probe MAC ≠ P0 OOB-MAC | Wrong physical device at LAN-IP | Operator re-verifies hardware identity | Abort and physically confirm; do NOT proceed |
| **P2 fail:** Probe 2 returns no disks | Boot media not visible / hardware fault | Check BIOS storage detection, USB connection if applicable | Replace boot media or fix BIOS storage settings |
| **P2 warning:** Probe 3 reports unexpected driver | New hardware class (e.g. igc instead of e1000e) | Cross-check via `lspci` from a live-USB boot if possible | Document the driver in `docs/hardware-analysis-<node>.md` BEFORE rendering — confirms hardware identity |
| **P3 fail:** yq parse error | envsubst left placeholder | `grep -n '\${NODE_' talos/nodes/<node>.yaml` (use single-quotes to avoid shell-expansion of `${`) | Re-render — likely a Probe value was empty |
| **P4 fail:** SOPS decryption errors | `SOPS_AGE_KEY_FILE` env unset | `ls $HOME/.config/sops/age/keys.txt` | Set env: `export SOPS_AGE_KEY_FILE=$HOME/.config/sops/age/keys.txt` |
| **P4 fail:** `validate-generated` complains about MAC collision | Same MAC twice in two nodes/*.yaml | `grep -rn "<mac>" talos/nodes/` | Re-probe Probe 3; one of the two existing nodes has stale MAC |
| **P4 fail:** install-disk by-path doesn't exist on node | by-path mapping changed (e.g. SATA controller reseated) | Reboot node, re-Probe 2 | Update install_disk |
| **P5 install hangs > 2 min** (talos_version poll fail) | Apply succeeded but reboot loop (mostly: SecureBoot enabled, debugfs=off, bad kernel arg) | `talosctl dmesg --nodes <ip>` (after node back in maintenance) | Disable SecureBoot in BIOS, re-render with correct args |
| **P6 CSR not appearing** | Node didn't boot to Kubernetes layer, or wrong cluster identity | `mcp__kubernetes-mcp-server__events_list fieldSelector=involvedObject.kind=Node` — look for kubelet bootstrap events | If absent: rollback + re-probe; confirm cluster.api_vip in cluster.yaml is reachable from new node |
| **P6 CSR rejected by cert-approver** | Hostname mismatch — kubelet presents SAN `node-XX` but CSR template expects `node-XX.<domain>` | `kubectl describe csr <name>` shows the rejection reason | Verify HostnameConfig.hostname in talos/nodes/<node>.yaml matches `<node>` exactly |
| **P7 Node Ready but no Cilium pod** | New node hasn't been picked up by cilium DaemonSet tolerations | `kubectl -n kube-system describe ds cilium` | Check DaemonSet tolerations / nodeSelector |
| **P7 Cilium agent crashloop** | WireGuard key generation race, or stale BPF state on rapid re-onboard | `kubectl -n kube-system logs <cilium-pod>` | Restart cilium pod; if persists, see `.claude/rules/cilium-service-sync.md` |
| **P7 LINSTOR satellite not registering** | Piraeus operator hasn't enrolled the new node yet (1-2 min normal) | `kubectl linstor node list` (requires linstor plugin — `kubectl-linstor` binary in PATH) | Wait 2 min; if still missing, check piraeus-operator logs |
| **P7 NFD storage-nvme label absent on NVMe node** | NFD takes ~60 s to discover hardware after node Ready | `mcp__kubernetes-mcp-server__resources_get apiVersion=v1 kind=Node name=<node>` — check `.metadata.labels` | Bounded poll 12×10s in skill; if still absent after 2 min: WARNING in commit body, not failure |
| **P8 fail:** `git diff --cached --name-only | wc -l != 2` | Either cluster.yaml or talos/nodes/<node>.yaml missing from index | `git status --short cluster.yaml talos/nodes/<node>.yaml` | `git add` the missing file; bundle must be atomic |

## Rollback procedure (entered as a state from P4/P5/P6/P7 failure)

A failed onboarding leaves three potential states:
1. Node booted, joined Kubernetes, but missing required labels/agents → soft state, fix forward if possible.
2. Node booted with bad config → reset and re-onboard.
3. Node never booted past install → BIOS / boot-media issue, not a Talos-config issue.

**For state 2 (full reset):**

```
mcp__talos__talos_reset confirm=true nodes=[<ip>] system_labels_to_wipe=["EPHEMERAL"]
```

This wipes the EPHEMERAL partition (kubelet state, container runtime data) and reboots into maintenance mode. STATE partition (Talos secrets) is preserved unless explicitly wiped. After reset, the node is back in maintenance mode and ready for a re-probe.

After reset:
```bash
git checkout -- cluster.yaml talos/nodes/<node>.yaml
# Or if node yaml was untracked:
rm -f talos/nodes/<node>.yaml
```

Investigate root cause before re-running the skill — re-run with same inputs reproduces the same failure.

## Common pitfalls (observed in homelab history)

- **Swapped MACs**: copying a previous node's file as a template and forgetting to update MAC → two nodes claim same NIC identity, both kubelet certs reject. The A0 template's `${NODE_MAC}` is parametrized to prevent this; do NOT cp old files.
- **Wrong install-disk by-path**: SATA enclosure shifted (e.g. drive reseated, USB stick inserted at install time) → `by-path` changes. Always re-Probe 2 against the **physically-installed-as-it-will-stay** boot disk.
- **Missing VLAN tagging on switch port**: switch port not configured for VLAN 110 trunking → DRBD interface has IP but no L2 reachability → LINSTOR satellite fails. Confirm with network admin that the new switchport carries VLAN 110.
- **IP collision in DRBD subnet**: another node already uses the computed DRBD host-octet (rare, but possible if cluster grew non-sequentially). The discover-skill grep-checks; manually verify with `grep -rn "192.168.110\." talos/nodes/` if in doubt.
- **Pi LAN host-octet edge case**: if a future LAN range pushes host-octet ≥ 120, the DRBD scheme (LAN−60) produces ≥ 60 — fine. But if LAN starts at ≤ 60, DRBD-octet goes ≤ 0 — scheme is broken; reassign LAN-octet or evolve the scheme.

## See also

- `.claude/rules/talos-config.md §Node Recovery` — etcd-member reset for CP nodes
- `.claude/rules/linstor-storage-guardrails.md` — DRBD-specific recovery
- `.claude/rules/cilium-service-sync.md` — Cilium agent / service desync
- `.claude/skills/discover-maintenance-node/references/maintenance-api.md` — Maintenance API constraints
