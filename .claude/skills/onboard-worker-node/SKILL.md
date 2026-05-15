---
name: onboard-worker-node
description: End-to-end onboarding of a new Talos standard worker — from physical install through Kubernetes Ready and bundled commit. Standard-worker scope only (CP / GPU / Pi out of scope). Resumable after session interrupt.
argument-hint: <node-name>
disable-model-invocation: true
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Grep
  - AskUserQuestion
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

End-to-end onboarding of a fresh standard-worker into the homelab Talos cluster. The skill orchestrates Discovery → Render → Apply → Verify → Commit, with rollback handled as a state (not a phase) and explicit resume detection on entry.

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
- `.claude/rules/kubernetes-mcp-first.md` — MCP-vs-CLI policy + Watch/Wait Contract (bounded poll).

## Checkpoint state

The skill writes phase-transition state to `.work/onboard-<node>/state.json` after each successful phase. This file is the resume source-of-truth when a session is interrupted. Schema:

```json
{
  "node": "node-XX",
  "phase_completed": "P5",
  "branch": "feat/onboard-node-XX",
  "files_to_commit": ["cluster.yaml", "talos/nodes/node-XX.yaml"],
  "lan_ip": "<ip>",
  "drbd_ip": "<ip>",
  "mac": "<mac>",
  "install_disk": "<by-path>",
  "started_at": "ISO-8601",
  "last_update": "ISO-8601"
}
```

The `.work/onboard-<node>/` directory is **gitignored** but must be preserved across restarts of the agent. If `git clean -fdx` is run, resume capability is lost — the operator must reconstruct from the live cluster.

## P-1 Resume detection (run FIRST on every invocation)

Before P0, determine entry phase. Execute in order:

1. **Check checkpoint file:**
   ```bash
   test -f .work/onboard-<node>/state.json && cat .work/onboard-<node>/state.json
   ```
   If present, read `phase_completed` and skip to the next phase. Show the operator the checkpoint contents and ask confirmation to resume (single `AskUserQuestion` Y/N).

2. **Check git state:**
   ```bash
   grep -q "name: <node>" cluster.yaml && echo "P1 done"
   test -f talos/nodes/<node>.yaml && echo "P2 done"
   ```

3. **Check live cluster state (single MCP call, no kubectl):**
   ```
   mcp__kubernetes-mcp-server__resources_get apiVersion=v1 kind=Node name=<node>
   ```
   - `NotFound` → node has not joined yet → resume from P3 or earlier
   - `Ready=True` → node is operational → resume at P7 verification + P9 commit (skipping P5/P6)
   - `Ready=False` / `Ready` absent → P6 likely incomplete; resume at P6

4. **Resume matrix:**

   | cluster.yaml entry | `talos/nodes/<node>.yaml` | Node API state | Resume at |
   |---|---|---|---|
   | absent | absent | n/a | P0 (fresh) |
   | present | absent | n/a | P2 (re-render) |
   | present | present | NotFound | P4 (gen-configs + apply) |
   | present | present | Ready=False | P6 (CSR / poll) |
   | present | present | Ready=True | P7 verify + P9 commit |

   If the matrix is ambiguous, stop and ask the operator before mutating.

## Phases

### P0 Preflight

Run **four** preflight checks. Use `AskUserQuestion` for each — do not accept prose acknowledgement.

**Q1 (multi-select):** Hardware & BIOS confirmed?
- SecureBoot disabled in BIOS (per AGENTS.md §Hard Constraints)
- IOMMU / VT-d enabled in BIOS
- No `debugfs=off` kernel arg planned (per AGENTS.md §Hard Constraints)
- Talos Factory USB with **standard** schematic (`SCHEMATIC_ID` from `talos/.schematic-ids.mk`) booted into maintenance mode

**Q2 (single-select):** LAN-IP & MAC binding confirmed out-of-band?
- Operator has read the MAC from the **physical hardware** (BIOS screen, NIC sticker, or printed label) and will compare against P2's probe result before applying.

  *Rationale (team-red §2-A):* the LAN-IP alone has no identity binding — flashing the wrong machine via `apply-config --insecure` is undoable. The operator must independently verify hardware identity.

**Q3 (single-select):** LAN-IP unique?
- Run `arp -na | grep <ip>` and confirm result is empty.

  *Caveat:* `arp -na` only sees cached entries. A never-ARPed-from-this-workstation IP returns empty even if used by another device. The OOB-MAC check in Q2 is the structural defense; arp is a weak supplementary check.

**Q4 (free-text):** Hostname slot?
- Operator types `node-XX` (e.g. `node-07`). Skill validates: matches `^node-[0-9]+$`, does not collide with existing `cluster.yaml.nodes.workers[].name` or `cluster.yaml.nodes.control_plane[].name` or `cluster.yaml.nodes.gpu_workers[].name` or `cluster.yaml.nodes.pi_nodes[].name`.

Branch hygiene — ALWAYS execute:
```bash
git fetch origin && git pull origin main --ff-only
git checkout -b feat/onboard-<node>
```

Refusing to branch from stale main avoids the team-red §3 "branch stale mid-session" trap. Skill must abort if `git pull --ff-only` fails (uncommitted changes, non-ff main divergence) — operator resolves manually.

After preflight passes: write `.work/onboard-<node>/state.json` with `phase_completed: "P0"`.

### P1 cluster.yaml — register node identity

Add a new entry under `.nodes.workers[]`:

```yaml
- name: node-XX
  ip: <lan-ip>
  nic: enp0s31f6
```

This is the minimum that `make` needs to auto-generate `install-node-XX`, `apply-node-XX`, `dry-run-node-XX`, `upgrade-node-XX` targets via the `$(foreach) $(eval)` expansion (Makefile lines 282-336).

Verify atomically (any failure restores cluster.yaml from HEAD):
```bash
yq -e ".nodes.workers[] | select(.name == \"<node>\")" cluster.yaml \
  && make -C talos -n install-<node> 2>&1 | head -1 \
  || { git checkout -- cluster.yaml; echo "P1 ROLLED BACK"; exit 1; }
```

After success: update `state.json` with `phase_completed: "P1"`.

### P2 Discovery + Template-Render

Precondition: P1 completed (verify in `state.json`). Refuse to start if cluster.yaml entry is missing.

Invoke `/discover-maintenance-node <node>` (see `.claude/skills/discover-maintenance-node/SKILL.md`). That skill:

1. Reads `cluster.yaml` for name/ip/nic/gateway.
2. Probes the maintenance API for MAC, install-disk by-path, NIC driver.
3. Computes DRBD-IP via the §DRBD Replication VLAN scheme (LAN host-octet − 60).
4. Renders `talos/nodes/<node>.yaml` from `talos/nodes/_template.yaml.tmpl`.
5. Shows the diff for user confirmation.

(The discover-skill owns the role-separation invariant: it does not write to `cluster.yaml`. The parent skill — this one — writes cluster.yaml in P1 only. The two are decoupled.)

**Identity-binding gate (CRITICAL):** before accepting the probe MAC, compare it against the MAC the operator confirmed in P0 Q2 (out-of-band). If they differ, **abort** — the wrong physical machine is at the LAN-IP. Do NOT proceed to P3.

After success: update `state.json` with `phase_completed: "P2"`, `mac`, `install_disk`, `drbd_ip`.

### P3 Sanity-check the rendered file

```bash
yq eval-all '.' "talos/nodes/<node>.yaml" >/dev/null  # YAML syntax
# Document count: 3 (HostnameConfig + VLANConfig + machine patch)
test "$(yq eval-all '. | documentIndex' "talos/nodes/<node>.yaml" | awk 'END {print NR}')" -eq 3
```

`awk 'END {print NR}'` replaces `wc -l` for shell-portability (BSD vs GNU; bash vs zsh whitespace handling).

The full Talos-validation (`talosctl validate --mode metal`) happens against the **generated** file in P4, not against the patch.

After success: update `state.json` with `phase_completed: "P3"`.

### P4 gen-configs + validate

```bash
SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt" make -C talos gen-configs
SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt" make -C talos validate-generated
```

If `validate-generated` fails for the new node, **on-failure → Rollback procedure (below)**. Common causes: malformed envsubst placeholder, MAC collision, install-disk by-path doesn't match any block device.

After success: update `state.json` with `phase_completed: "P4"`.

### P5 Initial apply (maintenance mode, `--insecure`)

```bash
make -C talos install-<node>
```

CLI-only — the MCP server cannot reach a maintenance-mode node (see `.claude/rules/talos-mcp-first.md`). This command runs `talosctl apply-config --insecure` against the maintenance API and triggers the install + first boot.

Then bounded poll for first-boot completion (per `kubernetes-mcp-first.md §Watch/Wait Contract`, max 12 × 10s = 2 min):

```
for i in $(seq 1 12); do
  mcp__talos__talos_version nodes=[<lan-ip>]   # NO --insecure: post-boot must succeed via TLS
  # success → break; error → sleep 10
done
```

Success → node has booted into normal mode with the cluster's PKI. Failure (12 iterations elapsed) → **on-failure → Rollback procedure**.

After success: update `state.json` with `phase_completed: "P5"`.

### P6 CSR approve (post-boot)

```
mcp__kubernetes-mcp-server__resources_list \
  apiVersion=certificates.k8s.io/v1 \
  kind=CertificateSigningRequest \
  fieldSelector=spec.username=system:node:<node>
```

`fieldSelector` scopes to this node's pending CSRs — never fetch-all-and-filter per `kubernetes-mcp-first.md §Critical Parameter Rules`.

If `cert-approver` is healthy, kubelet CSRs are auto-approved. Bounded poll (up to 5 minutes, consistent with rollback threshold below — max 30 × 10s = 5 min):

```
for i in $(seq 1 30); do
  csr_count=$(resources_list ... | jq '.items | length')
  [ "$csr_count" = "0" ] && break  # all approved
  sleep 10
done
```

If pending CSRs remain after 5 min, approve manually (CLI write op — `--read-only` MCP cannot do this):

```bash
kubectl -n kube-system get csr --field-selector spec.signerName=kubernetes.io/kubelet-serving | grep <node>
kubectl certificate approve <csr-name>
```

If the manual approval step also fails or CSR is rejected by cert-approver → **on-failure → Rollback procedure**. See runbook §Failure mode table for known CSR-rejection causes.

After success: update `state.json` with `phase_completed: "P6"`.

### P7 Verify cluster join (MCP-only)

All MCP calls use field-selectors to scope server-side per `kubernetes-mcp-first.md §Critical Parameter Rules`:

```
mcp__kubernetes-mcp-server__resources_get apiVersion=v1 kind=Node name=<node>
# Expect: status.conditions[type=Ready].status == "True"

mcp__kubernetes-mcp-server__pods_list_in_namespace \
  namespace=kube-system \
  labelSelector=k8s-app=cilium \
  fieldSelector=spec.nodeName=<node>
# Expect: exactly one pod, status.phase=Running, all containers Ready

mcp__kubernetes-mcp-server__events_list \
  fieldSelector=involvedObject.name=<node>,type=Warning
# Expect: empty (or only stale events predating the join)

mcp__talos__talos_health nodes=[<lan-ip>]
# Expect: healthy
```

NFD storage label (if the node has NVMe — verify via Probe 2 output from P2). Bounded poll, 12 × 10s:

```
for i in $(seq 1 12); do
  label=$(resources_get(Node,<node>).metadata.labels["feature.node.kubernetes.io/storage-nvme.present"])
  [ "$label" = "true" ] && break
  sleep 10
done
```

If NVMe was probed in P2 but the label never appears within 2 min: report as WARNING — do not fail outright (NFD pod scheduling latency is variable), but document in P9 commit body.

LINSTOR satellite registration (CLI-only — no MCP for the linstor plugin):
```bash
kubectl linstor node list | grep <node>   # Expect: ONLINE, configured=true
```

Requires `kubectl linstor` plugin installed (see runbook for install). Bounded poll 12 × 10s. On failure → **on-failure → Rollback procedure**.

After all green: update `state.json` with `phase_completed: "P7"`.

### P8 Commit (atomic bundle)

**Precondition** (Hard Rule, mechanically enforced):
```bash
git status --porcelain cluster.yaml talos/nodes/<node>.yaml
# Both files MUST appear with `M` or `A` flag. If either is absent or untracked-only,
# the commit must include `git add` for BOTH or abort.
```

```bash
git add cluster.yaml talos/nodes/<node>.yaml
# Verify both staged:
git diff --cached --name-only | grep -E '^(cluster\.yaml|talos/nodes/<node>\.yaml)$' | wc -l   # must equal 2
git commit -m "feat(talos): onboard <node> as standard worker"
```

Commit body should describe: hardware class (from P2 Probe 3 driver), DRBD-IP (placeholder if RFC1918 — see CLAUDE.md sensitive-paths policy), node-role. Include `Refs: <issue-url>` trailer if a tracking issue exists.

Push and open PR. After successful push: clean up checkpoint state:
```bash
rm -rf .work/onboard-<node>/
```

## Rollback procedure (state, not phase — entered from any of P4/P5/P6/P7 failure)

Per-phase entry signatures:

| Phase | Failure signature | Action |
|---|---|---|
| P4 | `validate-generated` non-zero exit on `_out/<cluster>/worker/<node>.yaml` | Restore source-of-truth only; node has not been touched |
| P5 | `talos_version` poll timed out (no TLS response after 2 min) | Node may be in boot loop; `talos_reset` required |
| P6 | CSR pending > 5 min OR `kubectl certificate approve` rejected | Node booted but rejected; `talos_reset` required |
| P7 | Cilium crashloop / LINSTOR not registering / NFD label missing after 5 min | Node joined but degraded; `talos_reset` is the conservative choice |

Sequence:

1. **If P5/P6/P7**: reset the node back to maintenance mode (MCP requires the node to have TLS reachable — if it does not, fall back to physical reboot into maintenance via USB).

   ```
   mcp__talos__talos_reset confirm=true nodes=[<lan-ip>] system_labels_to_wipe=["EPHEMERAL"]
   ```

   Wipes EPHEMERAL partition only (kubelet state, container runtime data). STATE partition (Talos secrets) preserved unless explicitly wiped. Node returns to maintenance mode after reboot.

2. **Always (regardless of phase):**
   ```bash
   git checkout -- cluster.yaml                       # restore from HEAD
   rm -f talos/nodes/<node>.yaml                      # if it was untracked
   git checkout -- talos/nodes/<node>.yaml 2>/dev/null # if it was committed in error
   rm -rf .work/onboard-<node>/                       # clear checkpoint
   ```

3. **Investigate root cause** via runbook §Failure mode table. Do NOT re-run the skill with identical inputs — reproduce the same failure.

## Hard Rules

- **Never apply config to a node that is in maintenance mode via the MCP path.** MCP requires TLS+talosconfig. Use `make install-<node>` (= `talosctl apply-config --insecure`) for first apply only.
- **Never commit `cluster.yaml` AND `talos/nodes/<node>.yaml` separately.** They are a bundle — if one is reverted, the cluster diverges (Hard Rule mechanically enforced in P8 via `git diff --cached --name-only | wc -l = 2` check).
- **Never proceed to P8 commit without all P7 checks green** (the NFD WARNING is the only acceptable amber). Partial onboarding leaves the node Ready-but-empty (no DRBD, no NFD label) and silently degrades cluster capacity.
- **Never branch from stale main.** P0 mandates `git fetch origin && git pull --ff-only` before branch creation. If main has diverged, refuse to proceed.
- **Identity-binding (P2) is mechanical, not advisory.** Probe MAC must match operator's OOB-confirmed MAC byte-for-byte. Mismatch → abort. No "looks close enough" path.
- **Resume detection (P-1) runs FIRST on every invocation.** Never skip P-1 because "I remember where I left off" — the checkpoint file is authoritative, not session memory.

## Anti-patterns

- **"Wait 60-180 seconds"** — replaced everywhere with bounded poll. If a wait condition is not mechanically observable, the skill cannot reach the next phase deterministically.
- **Prose acknowledgement** for go/no-go decisions — replaced with `AskUserQuestion`. Captured as structured input, not chat scrollback.
- **`fetch-all and filter in prose`** for MCP queries — replaced with `fieldSelector` / `labelSelector` scoping per `kubernetes-mcp-first.md`.
- **Untracked-only artifact** — `talos/nodes/<node>.yaml` MUST be `git add`ed before P8 atomicity check or the file is invisible to the bundle commit.
