# Migration Plan — Talos-Homelab `.claude/*` → `kube-agent-harness`

**Status**: Ready for execution
**Created**: 2026-04-29
**Source repo**: `github.com/Nosmoht/Talos-Homelab` (this repo, ref: `main` at commit `c9e8b32`)
**Target repo**: `github.com/devobagmbh/kube-agent-harness` (private, capability-driven Claude Code plugin marketplace)
**Tracking issues**: Talos-Homelab #147 (handed off), kube-agent-harness #TBD (to be opened during execution)

> **This plan is consumed by a separate Claude Code session running with `cwd = ~/workspace/kube-agent-harness`.**
> The session in Talos-Homelab cwd produced this plan and stops here. The harness-cwd session reads this document, opens the tracking issue, and executes the steps below.

---

## 1. Context

`docs/adr-multi-repo-platform-split.md` (PR #154 merged 2026-04-29) decided that `.claude/*` content from `Talos-Homelab` is consumed by `talos-homelab-cluster` via Claude Code plugin install of `kube-agent-harness`. This document plans the *content migration* into the harness — i.e. which skills/agents/hooks/rules ship in the plugin, which stay in the consuming cluster repo, and how collisions with existing harness content resolve.

Architectural intent (verified from harness `README.md`): the harness is a **marketplace with 3 plugins** (Core + 2 providers), capability-driven via consumer-side `.claude/harness.yaml`. New providers may be added (CNI, secrets, OS) but are explicitly out of v0.1 scope. The harness README also notes: *"Next phase — switch. A separate follow-up project will migrate Talos-Homelab from native primitives to consuming this harness."* — this plan IS that switch project.

## 2. Goal

After execution:
1. Generic / portable Talos-Homelab primitives live in `kube-agent-harness` (core or provider plugins).
2. Talos-/Cilium-/PNI-specific primitives stay in the consuming cluster repo (`talos-homelab-cluster`, future `talos-office-lab-cluster`).
3. The 3 known content collisions (skills) and 4 known rule collisions are resolved with the harness version winning by default.
4. `claude plugin install kube-agent-harness` from a clean clone of a future `talos-homelab-cluster` succeeds and exposes the migrated skills.
5. No regression of the operating Talos-Homelab repo — its `.claude/*` is *not modified by this migration*. (Cleanup of Talos-Homelab `.claude/*` happens later, in a follow-up coordinated with the `talos-homelab-cluster` repo creation per ADR Mini-Projekt 3.)

## 3. Source inventory (Talos-Homelab `main` @ `c9e8b32`)

### 3.1 Skills (28 total) — frontmatter excerpted from `.claude/skills/<name>/SKILL.md`

| # | Skill name | Tools | Description (truncated) |
|---|---|---|---|
| 1 | `analyze-node-hardware` | Bash | Analyze hardware of a Talos node using talosctl and NFD. Hardware profile for kernel tuning. |
| 2 | `argocd-app-unstick` | Bash | Unstick an ArgoCD Application stuck in OutOfSync/Degraded/Missing. Decision tree from diagnosis to fix. |
| 3 | `cilium-policy-debug` | Bash, Read, Grep, Glob, Write, k8s-mcp* | Diagnose Cilium and Gateway API traffic drops, map failures to CCNP manifests. |
| 4 | `cluster-health-snapshot` | Bash | Check cluster health across Talos, Kubernetes, Cilium, LINSTOR, and PKI. |
| 5 | `etcd-snapshot-restore` | Bash | Restore etcd from snapshot after quorum loss. Member re-join and full bootstrap-from-snap. |
| 6 | `execute-cilium-upgrade` | Bash, talos-mcp* | Execute reviewed Cilium upgrade (homelab WireGuard-strict). |
| 7 | `execute-talos-upgrade` | Bash | Execute reviewed Talos upgrade. |
| 8 | `gitops-health-triage` | Bash, k8s-mcp* | Triage ArgoCD app sync/health drift; remediation plan. |
| 9 | `hubble-cert-rotate` | Bash | Inspect/rotate Hubble TLS certificates. CronJob trigger + bootstrap re-render. |
| 10 | `irq-affinity-auditor` | talos_read_file | Audit IRQ affinity via Talos MCP. |
| 11 | `kernel-param-auditor` | talos_read_file | Audit kernel sysctl across nodes. Three-layer baseline. |
| 12 | `link-flap-detector` | talos_dmesg | Detect link flaps via Talos MCP dmesg + carrier_changes sysfs. |
| 13 | `linstor-storage-triage` | Bash, Read | Triage LINSTOR/DRBD storage health; sole-replica safety check. |
| 14 | `linstor-volume-repair` | Bash, Read | Repair corrupted XFS on DRBD-backed LINSTOR volume. |
| 15 | `nic-health-audit` | talos_read_file | Audit NIC health (link flaps, CRC, ring drops) via Talos MCP. |
| 16 | `onboard-workload-namespace` | Bash, Read, Grep, Glob, Write, Edit, k8s-mcp* | Onboard new namespace: PNI labels, ArgoCD App CR, Kyverno admission. |
| 17 | `optimize-node-kernel` | Bash, Read, Write, Edit, WebSearch, WebFetch | Research+apply optimized kernel parameters for Talos node. |
| 18 | `plan-cilium-upgrade` | Bash, Read, Grep, Glob, Write, WebSearch, WebFetch, Agent, talos-mcp* | Build Cilium upgrade plan (homelab). **Auto-invocable** (`disable-model-invocation` not set). |
| 19 | `plan-talos-upgrade` | Bash, Read, Grep, Glob, Write, WebSearch, WebFetch, Agent, talos-mcp* | Build Talos upgrade plan (homelab). **Auto-invocable.** |
| 20 | `pni-capability-add` | Bash, Read, Grep, Glob, Write, Edit, k8s-mcp* | Add a PNI capability: CCNP, ConfigMap, Kyverno allowlist, docs. |
| 21 | `sops-key-rotate` | Bash | Rotate AGE encryption key for SOPS-encrypted secrets. |
| 22 | `talos-apply` | Bash | Apply Talos config changes to single node, dry-run + health verify. |
| 23 | `talos-config-diff` | Bash | Diff live Talos node configs against repo-rendered configs. |
| 24 | `talos-node-maintenance` | (none) | **DEPRECATED.** Use /talos-apply or /talos-upgrade. |
| 25 | `talos-upgrade` | Bash | Upgrade single Talos node OS image with drain, DRBD safety, rollback. |
| 26 | `update-schematics` | Bash, Read, Write, Edit, Glob, Grep, WebFetch | Update Talos Image Factory schematics. |
| 27 | `validate-gitops` | Bash, Read, Grep | Full GitOps validation pipeline: kustomize, conftest, kubeconform, kyverno, trivy. |
| 28 | `verify-component-deployment` | Bash, Read, Grep, Glob, k8s-mcp* | Verify deployed ArgoCD infra component is healthy. |

26 manual-only (`disable-model-invocation: true`), 2 auto-invocable (`plan-cilium-upgrade`, `plan-talos-upgrade`).

### 3.2 Agents (6 total) — `.claude/agents/<name>.md`

| # | Agent | Description |
|---|---|---|
| 1 | `builder-evaluator` | Phase-7.5 verifier — judges acceptance criteria, read-only by tool restriction. |
| 2 | `builder-implementer` | Phase-4 implementer — executes approved plan, isolated context. |
| 3 | `gitops-operator` | ArgoCD sync failures, app-of-apps drift, sync-wave deadlocks. |
| 4 | `platform-reliability-reviewer` | Pre-merge / pre-operation adversarial reviewer (with file:line citations). |
| 5 | `researcher` | Upstream research, CVE assessment, version compatibility. Returns Sources/Findings/Confidence. |
| 6 | `talos-sre` | Talos node config gen, apply/upgrade sequencing, control-plane safety. |

All 6 use auto-dispatch via description matching. None list explicit `tools:` (means all tools available).

### 3.3 Hooks (7 total) — `.claude/hooks/<name>.sh`

| # | Hook | Purpose | Trigger |
|---|---|---|---|
| 1 | `check-sops` | Block writes of unencrypted content to `*.sops.yaml` paths | PreToolUse Write\|Edit |
| 2 | `check-sops-bash` | Block Bash commands writing plaintext to `*.sops.yaml` | PreToolUse Bash |
| 3 | `pre-drain-check` | Block `kubectl drain` if DRBD resources degraded or satellites offline | PreToolUse Bash matching `kubectl drain*` |
| 4 | `pre-push-verify` | Print verification checklist before pushing infrastructure changes | PreToolUse Bash matching `git push*` |
| 5 | `require-plan-review` | Block `ExitPlanMode` for infra plans lacking review evidence | PreToolUse ExitPlanMode |
| 6 | `require-probe-evidence` | Validate that reviewer outputs (Plans/*-agent-*.md) contain probe evidence | PostToolUse Write\|Edit |
| 7 | `validate-gitops` | Block `git commit` if staged `kubernetes/` changes fail GitOps validation | PreToolUse Bash matching `git commit*` |

### 3.4 Rules (18 total) — `.claude/rules/<name>.md` with `paths:` frontmatter

`argocd-structure.md`, `argocd-troubleshooting.md`, `cilium-bootstrap.md`, `cilium-gateway-api.md`, `cilium-network-policy.md`, `cilium-service-sync.md`, `k8s-cni.md`, `k8s-csi.md`, `kubernetes-mcp-first.md`, `linstor-storage-guardrails.md`, `manifest-quality.md`, `minio-exit.md`, `monitoring-observability.md`, `search-scope.md`, `talos-config.md`, `talos-image-factory.md`, `talos-mcp-first.md`, `talos-nodes.md`.

(No `.claude/references/` directory exists in source — Q3 spike concern is moot.)

## 4. Target inventory (`devobagmbh/kube-agent-harness` @ `main`)

### 4.1 Marketplace structure (`.claude-plugin/marketplace.json`)

```json
{
  "name": "kube-agent-harness",
  "owner": { "name": "devoba GmbH" },
  "metadata": { "version": "0.1.0" },
  "plugins": [
    { "name": "kube-agent-harness",                  "source": "./core" },
    { "name": "kube-agent-harness-gitops-argocd",    "source": "./providers/gitops-argocd" },
    { "name": "kube-agent-harness-csi-linstor",      "source": "./providers/csi-linstor" }
  ]
}
```

### 4.2 Core plugin (`./core/`)

- `core/skills/`: `verify-component-deployment` (1)
- `core/rules/`: `kubernetes-mcp-first.md`, `manifest-quality.md` (2)
- `core/agents/`: (none)
- `core/hooks/`: (none)

### 4.3 Provider plugin: `./providers/gitops-argocd/`

- `skills/`: `gitops-health-triage` (1)
- `rules/`: `argocd-structure.md` (1)
- `agents/`, `hooks/`: (none)

### 4.4 Provider plugin: `./providers/csi-linstor/`

- `skills/`: `linstor-storage-triage` (1)
- `rules/`: `linstor-storage-guardrails.md` (1)
- `agents/`, `hooks/`: (none)

### 4.5 Activation contract (consumer-side)

Consumer repo writes `.claude/harness.yaml` with `gitops:` and `csi:` fields. Provider plugin rules and skills check these fields and activate accordingly.

## 5. Step 0 — Smoke-test: are rules with `paths:` frontmatter plugin-distributable?

**Why required**: official plugin reference (`code.claude.com/docs/en/plugins-reference`) does not list `rules/` as a first-class plugin component (Section "Standard plugin layout", lines 639–676). However, the existing `kube-agent-harness` ships `core/rules/`, `providers/*/rules/` directories with `paths:`-frontmatter files. Either the docs are incomplete (Beta!) or those files are dormant in the plugin install. **Decisive answer needed before classifying 18 Talos-Homelab rules.**

### Smoke-test procedure

1. Create a sandbox cluster repo:
   ```bash
   mkdir -p /tmp/harness-rules-smoke/.claude/{settings,rules-test-harness}
   cd /tmp/harness-rules-smoke
   git init -q
   echo '{}' > .claude/settings.json
   echo 'harness:\n  version: 1\n  gitops: argocd\n' > .claude/harness.yaml
   ```
2. Install harness from current main:
   ```bash
   # In a Claude Code session with cwd=/tmp/harness-rules-smoke:
   /plugin marketplace add devobagmbh/kube-agent-harness
   /plugin install kube-agent-harness@kube-agent-harness
   /plugin install kube-agent-harness-gitops-argocd@kube-agent-harness
   ```
3. Touch a file matching `argocd-structure.md`'s `paths:` frontmatter (the harness's existing rule file):
   ```bash
   mkdir -p kubernetes/overlays/test
   echo 'apiVersion: argoproj.io/v1alpha1\nkind: Application\nmetadata:\n  name: test\n' > kubernetes/overlays/test/application.yaml
   ```
4. Open the file in Claude Code (Read or Edit). Observe whether the `argocd-structure.md` rule loads automatically (visible as system-reminder in conversation).

### Outcomes and branches

- **A. Rule auto-loads**: `paths:`-frontmatter rules ARE plugin-distributable in practice. Continue with full rule classification (Section 9.4 below).
- **B. Rule does NOT auto-load**: rules in plugin are dormant. All 18 Talos-Homelab rules **stay in the consuming cluster repo**. Skip Section 9.4. Note: this contradicts harness's current shipped `core/rules/` and `providers/*/rules/` content; file an issue against the harness suggesting either (i) remove rules from plugin layout to avoid confusion, or (ii) document that plugin-shipped rules require host-repo manual symlink.
- **C. Loaded but path-resolution against plugin-internal paths**: glob matches against the plugin's installed location, not consumer's working tree. Effectively useless. Treat as outcome B.

Document outcome in the harness tracking issue **before** classification work in Section 9.4 begins.

## 6. Migration classification — Skills (28)

| Skill | Disposition | Target path | Rationale |
|---|---|---|---|
| `analyze-node-hardware` | **stay-in-cluster** | (no migration) | Talos-NFD-bound; could be generalized later as `os-talos` provider |
| `argocd-app-unstick` | **migrate-new** | `providers/gitops-argocd/skills/argocd-app-unstick/` | ArgoCD-bound, no homelab specifics |
| `cilium-policy-debug` | **stay-in-cluster** | (no migration) | Cilium WireGuard-strict-mode + PNI-bound |
| `cluster-health-snapshot` | **stay-in-cluster** | (no migration) | Mixed Talos/Cilium/LINSTOR probes; generalize later |
| `etcd-snapshot-restore` | **migrate-new** | `core/skills/etcd-snapshot-restore/` | etcd is Kubernetes-generic |
| `execute-cilium-upgrade` | **stay-in-cluster** | (no migration) | Cilium-bound (homelab WireGuard mode) |
| `execute-talos-upgrade` | **stay-in-cluster** | (no migration) | Talos-bound |
| `gitops-health-triage` | **collision-resolve** | `providers/gitops-argocd/skills/gitops-health-triage/` (already exists) | Compare contents — harness version wins by default; merge any homelab-only enhancements as PR comment |
| `hubble-cert-rotate` | **stay-in-cluster** | (no migration) | Cilium-Hubble-bound |
| `irq-affinity-auditor` | **stay-in-cluster** (v0.1); generalize later | (no migration) | Uses talos_read_file; generalize when `os-talos` provider exists |
| `kernel-param-auditor` | **stay-in-cluster** (v0.1) | (no migration) | Same as above |
| `link-flap-detector` | **stay-in-cluster** (v0.1) | (no migration) | Same as above |
| `linstor-storage-triage` | **collision-resolve** | `providers/csi-linstor/skills/linstor-storage-triage/` (already exists) | Compare; harness wins by default |
| `linstor-volume-repair` | **migrate-new** | `providers/csi-linstor/skills/linstor-volume-repair/` | LINSTOR/DRBD-bound, fits provider |
| `nic-health-audit` | **stay-in-cluster** (v0.1) | (no migration) | Talos MCP-bound |
| `onboard-workload-namespace` | **stay-in-cluster** | (no migration) | PNI-Labels are homelab convention |
| `optimize-node-kernel` | **stay-in-cluster** | (no migration) | Talos-kernel-tuning specific |
| `plan-cilium-upgrade` | **stay-in-cluster** | (no migration) | Cilium-bound; **note auto-invocable** |
| `plan-talos-upgrade` | **stay-in-cluster** | (no migration) | Talos-bound; **note auto-invocable** |
| `pni-capability-add` | **stay-in-cluster** | (no migration) | PNI = homelab convention |
| `sops-key-rotate` | **stay-in-cluster** (v0.1) | (no migration) | Generic, but uses repo-specific paths; generalize when `secrets-sops-age` provider exists |
| `talos-apply` | **stay-in-cluster** | (no migration) | Talos-bound |
| `talos-config-diff` | **stay-in-cluster** | (no migration) | Talos-bound |
| `talos-node-maintenance` | **DELETE** | (deprecated, do not migrate) | Marked deprecated in source; remove from cluster repo as part of migration cleanup |
| `talos-upgrade` | **stay-in-cluster** | (no migration) | Talos-bound |
| `update-schematics` | **stay-in-cluster** | (no migration) | Talos-Image-Factory-bound |
| `validate-gitops` | **migrate-new** | `providers/gitops-argocd/skills/validate-gitops/` | ArgoCD/Kyverno/conftest validation, fits provider |
| `verify-component-deployment` | **collision-resolve** | `core/skills/verify-component-deployment/` (already exists) | Compare; harness wins by default |

**Summary:**
- Migrate-new: **4** (`etcd-snapshot-restore`, `argocd-app-unstick`, `linstor-volume-repair`, `validate-gitops`)
- Collision-resolve: **3** (`gitops-health-triage`, `linstor-storage-triage`, `verify-component-deployment`)
- Stay-in-cluster: **20**
- Delete: **1** (`talos-node-maintenance`)
- Total: **28** ✓

## 7. Migration classification — Agents (6)

| Agent | Disposition | Target path | Rationale |
|---|---|---|---|
| `builder-evaluator` | **migrate-new** | `core/agents/builder-evaluator.md` | Generic Phase-7.5 verifier pattern, useful for any GitOps repo |
| `builder-implementer` | **migrate-new** | `core/agents/builder-implementer.md` | Generic Phase-4 implementer pattern |
| `gitops-operator` | **migrate-new** | `providers/gitops-argocd/agents/gitops-operator.md` | ArgoCD-specific |
| `platform-reliability-reviewer` | **migrate-new** | `core/agents/platform-reliability-reviewer.md` | Generic adversarial reviewer pattern |
| `researcher` | **migrate-new** | `core/agents/researcher.md` | Generic research pattern |
| `talos-sre` | **stay-in-cluster** | (no migration) | Talos-specific; generalize when `os-talos` provider exists |

**Summary:** 5 migrate-new (4 to core, 1 to provider/gitops-argocd), 1 stay-in-cluster.

**Note:** harness has no `agents/` subdirectory currently in any of its 3 plugins. This migration introduces the `agents/` component to all three. Verify in smoke-test that the harness plugin schema discovers `agents/` correctly.

## 8. Migration classification — Hooks (7)

| Hook | Disposition | Target path | Rationale |
|---|---|---|---|
| `check-sops` | **migrate-new** | `core/hooks/check-sops.sh` | Generic SOPS-AGE protection, fits any SOPS-using repo |
| `check-sops-bash` | **migrate-new** | `core/hooks/check-sops-bash.sh` | Same as above |
| `pre-drain-check` | **migrate-new** | `providers/csi-linstor/hooks/pre-drain-check.sh` | DRBD-specific safety check |
| `pre-push-verify` | **migrate-new** | `core/hooks/pre-push-verify.sh` | Generic infra-push checklist |
| `require-plan-review` | **migrate-new** | `core/hooks/require-plan-review.sh` | Generic plan-review enforcement |
| `require-probe-evidence` | **migrate-new** | `core/hooks/require-probe-evidence.sh` | Generic probe-evidence enforcement |
| `validate-gitops` | **migrate-new** | `providers/gitops-argocd/hooks/validate-gitops.sh` | Calls kustomize/kyverno/conftest pipeline; ArgoCD-bound by association |

**Summary:** All 7 migrate; 5 to core, 1 to gitops-argocd, 1 to csi-linstor.

### 8.1 `hooks/hooks.json` schemas to author

#### `core/hooks/hooks.json`

```json
{
  "PreToolUse": [
    {
      "matcher": "Write|Edit",
      "hooks": [{ "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/check-sops.sh" }]
    },
    {
      "matcher": "Bash",
      "hooks": [{ "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/check-sops-bash.sh" }]
    },
    {
      "matcher": "Bash",
      "if": "Bash(git push*)",
      "hooks": [{ "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/pre-push-verify.sh" }]
    },
    {
      "matcher": "ExitPlanMode",
      "hooks": [{ "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/require-plan-review.sh" }]
    }
  ],
  "PostToolUse": [
    {
      "matcher": "Write|Edit",
      "hooks": [{ "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/require-probe-evidence.sh" }]
    }
  ]
}
```

#### `providers/csi-linstor/hooks/hooks.json`

```json
{
  "PreToolUse": [
    {
      "matcher": "Bash",
      "if": "Bash(kubectl drain*)",
      "hooks": [{ "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/pre-drain-check.sh" }]
    }
  ]
}
```

#### `providers/gitops-argocd/hooks/hooks.json`

```json
{
  "PreToolUse": [
    {
      "matcher": "Bash",
      "if": "Bash(git commit*)",
      "hooks": [{ "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/validate-gitops.sh" }]
    }
  ]
}
```

**Verify** during smoke-test that `${CLAUDE_PLUGIN_ROOT}` is the documented variable name (per `code.claude.com/docs/en/plugins-reference` §"Hooks"). If the variable name differs, adjust all three files accordingly.

## 9. Migration classification — Rules (18) — gated on Step 0 outcome

### 9.1 If Step 0 outcome is **A** (rules plugin-distributable)

| Rule | Disposition | Target path | Rationale |
|---|---|---|---|
| `argocd-structure.md` | **collision-resolve** | `providers/gitops-argocd/rules/argocd-structure.md` (already exists) | Compare contents |
| `argocd-troubleshooting.md` | **migrate-new** | `providers/gitops-argocd/rules/argocd-troubleshooting.md` | ArgoCD-specific |
| `cilium-bootstrap.md` | **stay-in-cluster** | (no migration) | Cilium-WireGuard-strict-mode, Talos extraManifests gotcha — homelab-bound |
| `cilium-gateway-api.md` | **stay-in-cluster** | (no migration) | Cilium-Gateway-API specific |
| `cilium-network-policy.md` | **stay-in-cluster** | (no migration) | CNP/CCNP file-naming + PNI-bound |
| `cilium-service-sync.md` | **stay-in-cluster** | (no migration) | Cilium-bound |
| `k8s-cni.md` | **migrate-new** | `core/rules/k8s-cni.md` | Generic CNI patterns (Multus, eBPF) |
| `k8s-csi.md` | **migrate-new** | `core/rules/k8s-csi.md` | Generic CSI patterns (mount/unmount, Talos-upgrade unmount-deadlock) |
| `kubernetes-mcp-first.md` | **collision-resolve** | `core/rules/kubernetes-mcp-first.md` (already exists) | Compare |
| `linstor-storage-guardrails.md` | **collision-resolve** | `providers/csi-linstor/rules/linstor-storage-guardrails.md` (already exists) | Compare |
| `manifest-quality.md` | **collision-resolve** | `core/rules/manifest-quality.md` (already exists) | Compare |
| `minio-exit.md` | **stay-in-cluster** | (no migration) | Specific to homelab MinIO sunset |
| `monitoring-observability.md` | **migrate-new** | `core/rules/monitoring-observability.md` | Generic Prometheus/Grafana/kube-prometheus-stack guidance |
| `search-scope.md` | **stay-in-cluster** | (no migration) | Mentions specific homelab files (kubevirt-operator.yaml etc.) |
| `talos-config.md` | **stay-in-cluster** | (no migration) | Talos-bound |
| `talos-image-factory.md` | **stay-in-cluster** | (no migration) | Talos-bound |
| `talos-mcp-first.md` | **stay-in-cluster** (v0.1) | (no migration) | Talos-bound; generalize when `os-talos` provider exists |
| `talos-nodes.md` | **stay-in-cluster** | (no migration) | Talos-bound |

**Summary if A:** 4 migrate-new, 4 collision-resolve, 10 stay-in-cluster.

### 9.2 If Step 0 outcome is **B** or **C** (rules dormant in plugin)

All 18 rules **stay in the consuming cluster repo**. Skip 9.1 entirely. As part of resolving the situation:
- Open issue against `kube-agent-harness` flagging that `core/rules/` and `providers/*/rules/` directories ship dormant content. Suggest either documentation update or removal.
- Talos-Homelab rules remain in `talos-homelab-cluster:.claude/rules/` indefinitely.

## 10. Collision-resolution strategy

For each of the 7 known collisions (3 skills + 4 rules under outcome A):

1. Pull both files (harness version + Talos-Homelab version).
2. Run `diff -u <harness> <talos-homelab>`.
3. Default rule: **harness version wins**. It's the already-generalized form; the Talos-Homelab version is the source from which it was derived.
4. If diff shows the Talos-Homelab version has *new* content not yet in the harness version (post-extraction enhancements), file a separate harness PR cherry-picking those enhancements. Do **not** mix collision-resolution with content enhancements in the same migration commit.
5. Document each collision-resolution decision with a 1-line note in the migration tracking issue.

The 7 known collisions are listed inline above (§6 collision-resolve rows + §9.1 collision-resolve rows). Audit during execution may surface additional ones — handle them with the same rule.

## 11. Provider extension decision

Roadmap candidate provider plugins (per harness README): `cni-cilium`, `cni-calico`, `secrets-sops-age`, `secrets-sealed-secrets`, `secrets-external-secrets`, `os-talos`, `os-flatcar`, `gitops-flux`.

**Decision for this migration**: do NOT introduce new provider plugins. Reasons:
- harness v0.1 explicitly scopes "Roadmap (not in v0.1)" for these providers
- Talos-/Cilium-specific stay-in-cluster items can wait until the corresponding providers are added in a separate harness work-stream
- Single-concern PR boundary: this migration ships only generic + already-existing-provider content

**Implication**: 14 of the 20 stay-in-cluster skills (and 11 of the 18 rules under outcome A) carry an implicit "TODO: re-evaluate when `os-talos`/`cni-cilium` providers exist" flag. This is captured in the tracking issue's roadmap section, not addressed in this PR.

## 12. Execution mechanics

The harness-cwd session executes the following sequence:

### 12.1 Preparation

```bash
# Verify harness clone is current and on a fresh branch
cd ~/workspace/kube-agent-harness
git fetch origin && git checkout main && git pull --ff-only
git checkout -b feat/import-talos-homelab-primitives

# Make a throwaway clone of Talos-Homelab as the source
mkdir -p /tmp/migration-source
git clone --depth=1 --branch=main https://github.com/Nosmoht/Talos-Homelab.git /tmp/migration-source/talos-homelab
TALOS_SRC=/tmp/migration-source/talos-homelab
```

### 12.2 Step 0 — Smoke-test (see §5 procedure)

Execute and document outcome in tracking issue. Branch on outcome.

### 12.3 Skill migrations

For each `migrate-new` skill (4 entries from §6):

```bash
# Example: etcd-snapshot-restore → core
cp -r "$TALOS_SRC/.claude/skills/etcd-snapshot-restore" core/skills/
# Inspect SKILL.md frontmatter — strip any homelab-specific reference
$EDITOR core/skills/etcd-snapshot-restore/SKILL.md
```

For each `collision-resolve` skill (3 entries):

```bash
# Example: verify-component-deployment
diff -u core/skills/verify-component-deployment/SKILL.md \
       "$TALOS_SRC/.claude/skills/verify-component-deployment/SKILL.md" || true
# Document decision; default keep harness version unchanged.
```

### 12.4 Hook migrations (7 hooks total)

```bash
mkdir -p core/hooks providers/csi-linstor/hooks providers/gitops-argocd/hooks
cp "$TALOS_SRC/.claude/hooks/check-sops.sh" core/hooks/
cp "$TALOS_SRC/.claude/hooks/check-sops-bash.sh" core/hooks/
cp "$TALOS_SRC/.claude/hooks/pre-push-verify.sh" core/hooks/
cp "$TALOS_SRC/.claude/hooks/require-plan-review.sh" core/hooks/
cp "$TALOS_SRC/.claude/hooks/require-probe-evidence.sh" core/hooks/
cp "$TALOS_SRC/.claude/hooks/pre-drain-check.sh" providers/csi-linstor/hooks/
cp "$TALOS_SRC/.claude/hooks/validate-gitops.sh" providers/gitops-argocd/hooks/
chmod +x core/hooks/*.sh providers/*/hooks/*.sh
```

Author `core/hooks/hooks.json`, `providers/csi-linstor/hooks/hooks.json`, `providers/gitops-argocd/hooks/hooks.json` per §8.1 schemas.

**Audit each hook script** for hardcoded paths to the homelab repo (`kubernetes/overlays/homelab/`, `cluster.yaml` at repo root assumption, etc.). Where found, parameterize via env var or harness.yaml lookup.

### 12.5 Agent migrations (5 agents)

```bash
mkdir -p core/agents providers/gitops-argocd/agents
cp "$TALOS_SRC/.claude/agents/builder-evaluator.md" core/agents/
cp "$TALOS_SRC/.claude/agents/builder-implementer.md" core/agents/
cp "$TALOS_SRC/.claude/agents/platform-reliability-reviewer.md" core/agents/
cp "$TALOS_SRC/.claude/agents/researcher.md" core/agents/
cp "$TALOS_SRC/.claude/agents/gitops-operator.md" providers/gitops-argocd/agents/
```

**Audit each agent description** for homelab-specific phrasing (e.g. "homelab cluster", "Nosmoht/Talos-Homelab"). Generalize.

### 12.6 Rule migrations (only if outcome A from Step 0)

```bash
# Migrate-new (4)
cp "$TALOS_SRC/.claude/rules/k8s-cni.md" core/rules/
cp "$TALOS_SRC/.claude/rules/k8s-csi.md" core/rules/
cp "$TALOS_SRC/.claude/rules/monitoring-observability.md" core/rules/
cp "$TALOS_SRC/.claude/rules/argocd-troubleshooting.md" providers/gitops-argocd/rules/

# Collision-resolve (4) — diff and document, default keep harness version
diff -u core/rules/manifest-quality.md "$TALOS_SRC/.claude/rules/manifest-quality.md" || true
diff -u core/rules/kubernetes-mcp-first.md "$TALOS_SRC/.claude/rules/kubernetes-mcp-first.md" || true
diff -u providers/gitops-argocd/rules/argocd-structure.md "$TALOS_SRC/.claude/rules/argocd-structure.md" || true
diff -u providers/csi-linstor/rules/linstor-storage-guardrails.md "$TALOS_SRC/.claude/rules/linstor-storage-guardrails.md" || true
```

**Audit each rule** for `paths:` frontmatter values. Verify globs are generic (e.g. `kubernetes/**/cnp-*.yaml`, not `kubernetes/overlays/homelab/**/cnp-*.yaml`).

### 12.7 Plugin manifest updates

Update each plugin's `.claude-plugin/plugin.json`:

- `core/.claude-plugin/plugin.json`: bump version, document new components in description
- `providers/gitops-argocd/.claude-plugin/plugin.json`: same
- `providers/csi-linstor/.claude-plugin/plugin.json`: same

Update `.claude-plugin/marketplace.json`: bump marketplace `metadata.version` to `0.2.0` and per-plugin descriptions to reflect added components. Tag a release `v0.2.0` after merge.

### 12.8 Documentation

- Update `docs/architecture.md` with new component counts.
- Update `README.md` "Plugins in v0.1" table → "Plugins in v0.2", reflect new content.
- Add a `CHANGELOG.md` entry (or amend existing) listing additions.
- Update the README "Relationship to Talos-Homelab" section: change the wording about "frozen Talos-Homelab `.claude/skills/**`" — the freeze ended 2026-04-26 per Talos-Homelab memory.

### 12.9 Verification

```bash
# Local plugin manifest sanity
jq . .claude-plugin/marketplace.json
jq . core/.claude-plugin/plugin.json
jq . providers/gitops-argocd/.claude-plugin/plugin.json
jq . providers/csi-linstor/.claude-plugin/plugin.json
jq . core/hooks/hooks.json
jq . providers/csi-linstor/hooks/hooks.json
jq . providers/gitops-argocd/hooks/hooks.json
```

Smoke-test consumption from a sandbox cluster repo (same procedure as Step 0):

1. `claude plugin install kube-agent-harness@kube-agent-harness` — verify all skills discoverable.
2. Trigger a migrated skill (`/etcd-snapshot-restore` — if its tools are auto-mode-permitted in sandbox).
3. Trigger a migrated hook by performing the matching action (e.g. `git push`-trigger for `pre-push-verify`).
4. (If outcome A) Edit a file matching a migrated rule's `paths:` glob; verify rule loads.

### 12.10 Commit + PR

```bash
git add -A
git commit -s -m "feat: import Talos-Homelab generic + provider-bound primitives (v0.2)

Brings core skill set, agent set, and hook set into harness from the
Talos-Homelab source repo, plus extends provider plugins with additional
ArgoCD- and LINSTOR-bound skills and hooks.

Skills added: 4 (etcd-snapshot-restore[core], argocd-app-unstick + validate-gitops[gitops-argocd], linstor-volume-repair[csi-linstor])
Skills resolved by collision (harness version wins): 3 (verify-component-deployment[core], gitops-health-triage[gitops-argocd], linstor-storage-triage[csi-linstor])
Agents added: 5 (4 core + 1 gitops-argocd)
Hooks added: 7 (5 core + 1 gitops-argocd + 1 csi-linstor)
Rules added: <outcome-A: 4 migrate-new + 4 collision-resolve> | <outcome-B: 0>

Talos-/Cilium-/PNI-specific primitives stay in the consuming cluster repo
(talos-homelab-cluster, future talos-office-lab-cluster) per harness README
'small generalized subset' policy.

Smoke-tested from sandbox cluster repo with /plugin install and trigger
verification. See migration tracking issue #<TBD> for full rationale and
collision-resolution log.

Source: github.com/Nosmoht/Talos-Homelab @ c9e8b32 (post-ADR-amendment)."
git push -u origin feat/import-talos-homelab-primitives
gh pr create --title "feat: import Talos-Homelab generic + provider-bound primitives (v0.2)" \
  --body-file <body> --label feature
```

## 13. Acceptance criteria (block merge until all pass)

1. Step-0 smoke-test outcome documented in tracking issue (A, B, or C with evidence).
2. Each migrated skill has a SKILL.md frontmatter with no `homelab` / `Nosmoht/Talos-Homelab` / `node-pi-01` / `192.168.2.*` strings (generic-text audit).
3. Each migrated hook has a corresponding entry in the right `hooks/hooks.json`.
4. Each migrated agent has a description that does not reference `homelab cluster` or `Talos-Homelab` repo specifics.
5. (Outcome A only) Each migrated rule has `paths:` glob matching the consumer's likely tree (`kubernetes/**`, not `kubernetes/overlays/homelab/**`).
6. `jq .` passes on all updated `*.json` files.
7. From a sandbox cluster repo with `harness.yaml` configured, `claude plugin install ...` for all three plugins succeeds without error.
8. At least one auto-discovered skill from each plugin is invokable in the sandbox.
9. At least one hook (`pre-push-verify` from core) fires when its trigger action is taken.
10. `marketplace.json` and per-plugin `plugin.json` versions bumped to `0.2.0`.
11. README + architecture.md component counts updated.
12. PR includes a "Tested" section with sandbox-test transcript excerpt.

## 14. Rollback path

The harness-side migration is committed only on a feature branch (`feat/import-talos-homelab-primitives`). Until merged, rollback is `git branch -D feat/import-talos-homelab-primitives` + `git push origin --delete feat/import-talos-homelab-primitives` — single-step, reversible.

After merge and `v0.2.0` tag: rollback is a `git revert <merge-sha>` PR. Consumer repos pinning `v0.1.x` are unaffected; consumers pinning `v0.2.0` can pin back to `v0.1.x` until rollback completes.

**Talos-Homelab is never modified by this migration**, so there is no rollback obligation on the source side.

## 15. Out of scope (explicit)

- **Removing migrated content from Talos-Homelab `.claude/*`.** This happens later, only after `talos-homelab-cluster` repo (ADR Mini-Projekt 3) exists and consumes the harness. Premature deletion would break the live homelab cluster's tooling.
- **Adding new provider plugins** (`os-talos`, `cni-cilium`, `secrets-sops-age`). Roadmap items, separate work.
- **Live homelab cluster cutover.** Tracked separately in Talos-Homelab #155 (Phase 3D).
- **Office-lab scaffold** (Talos-Homelab #150). Out of scope per amended ADR.

## 16. Tracking issue body (to open in `devobagmbh/kube-agent-harness`)

> ### Title
> `feat: import Talos-Homelab generic + provider-bound primitives (v0.2)`
>
> ### Body
> Imports the generic and provider-bound subset of Claude Code primitives from `github.com/Nosmoht/Talos-Homelab` into this harness. Driven by the multi-repo split decided in Talos-Homelab `docs/adr-multi-repo-platform-split.md` (PR #154 there).
>
> Full plan: `https://github.com/Nosmoht/Talos-Homelab/blob/main/docs/harness-skill-migration-plan.md` (commit `<TBD>`).
>
> ### Scope (per migration plan)
> - **Step 0**: smoke-test rules-with-`paths:`-frontmatter plugin distributability (outcome decides whether 4 migrate-new + 4 collision-resolve rules ship in this PR or not).
> - 4 new skills (1 core + 3 provider-bound)
> - 3 collision-resolved skills (harness version wins by default; diff documented per skill)
> - 5 new agents (4 core + 1 gitops-argocd)
> - 7 new hooks (5 core + 1 gitops-argocd + 1 csi-linstor) + corresponding `hooks.json` schemas
> - Rules: outcome-A=8 (4 new + 4 collision); outcome-B/C=0
> - Marketplace + plugin.json version bumps to `0.2.0`; tag `v0.2.0` after merge
>
> ### Out of scope
> - Talos-/Cilium-/PNI-specific primitives stay in consumer cluster repo (per harness README "small generalized subset" policy)
> - New provider plugins (os-talos, cni-cilium, etc.) — roadmap items, separate
> - Source-side cleanup of Talos-Homelab `.claude/*` — happens later when consumer cluster repo exists

## 17. Prompt template for the harness-cwd Claude Code session

> Save the following to a file (e.g. `~/migration-prompt.md`) and paste it into the new Claude Code session in `~/workspace/kube-agent-harness` cwd as the very first message.

````
You are working on the kube-agent-harness repo (cwd is the repo root).
A Talos-Homelab session has prepared a complete migration plan that imports
generic + provider-bound Claude Code primitives from Talos-Homelab into this
harness.

Plan source (raw URL):
https://raw.githubusercontent.com/Nosmoht/Talos-Homelab/main/docs/harness-skill-migration-plan.md

Pull the plan with WebFetch (or `curl | gh api repos/...` for auth, since
this is private — actually Talos-Homelab is public, so plain WebFetch works).
Read it end-to-end before doing any filesystem changes.

Then execute it in this exact order:

1. Open a tracking issue in this repo using §16 of the plan as the body.
   Capture the issue number; reference it in commit messages.

2. Execute Step 0 (the rules smoke-test) per §5 of the plan.
   - Document the outcome (A, B, or C) as an issue comment with evidence.
   - Branch the rest of execution accordingly.

3. Create branch `feat/import-talos-homelab-primitives` and execute §12
   (mechanics) sequentially. Commit per logical group (one commit per
   migration class is fine; do not bundle skills + hooks + rules into a
   single commit — keep diffs reviewable).

4. Run §13 acceptance checks. If any fails, fix in place; do not skip.

5. Open a PR (§12.10 commit message template). Include a "Tested" section
   with sandbox-smoke-test transcript excerpts.

Hard constraints (from the plan):
- Talos-Homelab is the SOURCE only — never write to it from this session.
- Default to harness-version-wins for collisions; capture diffs.
- After processing, no migrated file may contain `homelab`, `Nosmoht/Talos-Homelab`,
  `node-pi-01`, `192.168.2.*` strings.
- Stop after PR open — do NOT merge. Merge is the maintainer's call.

Failure modes to escalate:
- Step 0 outcome C (paths-resolution against plugin-internal): file an issue
  in the harness against the plugin schema gap; do NOT migrate rules.
- Plugin schema variable name mismatch (e.g. `${CLAUDE_PLUGIN_ROOT}` is wrong):
  verify against code.claude.com/docs/en/plugins-reference §"Hooks", correct
  in all three hooks.json files; document in PR.
- Existing harness content in a collision is BETTER than the Talos-Homelab
  version (genuinely improved, not just diff): keep harness, do not import.
````

## 18. Source-session memory transfer (for continuity)

The Talos-Homelab session that produced this plan recorded the following in its memory (`~/.claude/projects/-Users-ntbc-workspace-Talos-Homelab/memory/`):

- `feedback_harness_composition.md` — kube-agent-harness IS plugin (surface) AND capability-plugin underlay
- `feedback_harness_capability_driven.md` — capability-driven design (CNI/CSI provider plugins)
- `feedback_harness_private_repo.md` — devobagmbh/kube-agent-harness stays permanently private
- `reference_harness_service_model.md` — internal devoba tooling for customer-cluster audit services
- `project_homelab_primitives_frozen.md` — freeze LIFTED 2026-04-26

The harness-cwd session does NOT inherit this memory but can read these notes via WebFetch on the Talos-Homelab raw URLs if needed for context. They are not required for plan execution; included for traceability only.
