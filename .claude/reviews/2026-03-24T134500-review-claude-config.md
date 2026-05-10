---
generated_by: review-claude-config
schema_version: 1
date: 2026-03-24
target: /Users/ntbc/workspace/Talos-Homelab
baseline_version: 2026-03-24
items_reviewed: 13
summary:
  - name: analyze-node-hardware
    type: Skill
    path: .claude/skills/analyze-node-hardware/SKILL.md
    overall: B
    score: 88.5
    clarity: A
    completeness: B
    prompt_engineering: B
    context_engineering: B
    goal_alignment: A
    safety: B
    metadata: B
  - name: cilium-policy-debug
    type: Skill
    path: .claude/skills/cilium-policy-debug/SKILL.md
    overall: C
    score: 75.25
    clarity: B
    completeness: C
    prompt_engineering: F
    context_engineering: C
    goal_alignment: B
    safety: C
    metadata: B
  - name: optimize-node-kernel
    type: Skill
    path: .claude/skills/optimize-node-kernel/SKILL.md
    overall: B
    score: 89.5
    clarity: A
    completeness: A
    prompt_engineering: B
    context_engineering: B
    goal_alignment: A
    safety: B
    metadata: C
  - name: update-schematics
    type: Skill
    path: .claude/skills/update-schematics/SKILL.md
    overall: A
    score: 93.0
    clarity: A
    completeness: A
    prompt_engineering: B
    context_engineering: A
    goal_alignment: A
    safety: A
    metadata: B
  - name: execute-cilium-upgrade
    type: Skill
    path: .claude/skills/execute-cilium-upgrade/SKILL.md
    overall: A
    score: 93.5
    clarity: A
    completeness: A
    prompt_engineering: B
    context_engineering: A
    goal_alignment: A
    safety: A
    metadata: A
  - name: execute-talos-upgrade
    type: Skill
    path: .claude/skills/execute-talos-upgrade/SKILL.md
    overall: A
    score: 92.0
    clarity: A
    completeness: A
    prompt_engineering: B
    context_engineering: B
    goal_alignment: A
    safety: A
    metadata: A
  - name: gitops-health-triage
    type: Skill
    path: .claude/skills/gitops-health-triage/SKILL.md
    overall: B
    score: 84.0
    clarity: B
    completeness: C
    prompt_engineering: C
    context_engineering: B
    goal_alignment: B
    safety: A
    metadata: A
  - name: plan-cilium-upgrade
    type: Skill
    path: .claude/skills/plan-cilium-upgrade/SKILL.md
    overall: A
    score: 92.0
    clarity: A
    completeness: A
    prompt_engineering: B
    context_engineering: B
    goal_alignment: A
    safety: A
    metadata: A
  - name: plan-talos-upgrade
    type: Skill
    path: .claude/skills/plan-talos-upgrade/SKILL.md
    overall: A
    score: 92.0
    clarity: A
    completeness: A
    prompt_engineering: B
    context_engineering: B
    goal_alignment: A
    safety: A
    metadata: A
  - name: talos-node-maintenance
    type: Skill
    path: .claude/skills/talos-node-maintenance/SKILL.md
    overall: B
    score: 81.0
    clarity: B
    completeness: C
    prompt_engineering: C
    context_engineering: B
    goal_alignment: B
    safety: C
    metadata: A
  - name: talos-sre
    type: Agent
    path: .claude/agents/talos-sre.md
    overall: C
    score: 74.0
    clarity: C
    completeness: D
    prompt_engineering: D
    context_engineering: C
    goal_alignment: C
    safety: B
    metadata: B
  - name: gitops-operator
    type: Agent
    path: .claude/agents/gitops-operator.md
    overall: C
    score: 74.5
    clarity: C
    completeness: D
    prompt_engineering: D
    context_engineering: C
    goal_alignment: B
    safety: C
    metadata: B
  - name: platform-reliability-reviewer
    type: Agent
    path: .claude/agents/platform-reliability-reviewer.md
    overall: C
    score: 75.0
    clarity: C
    completeness: C
    prompt_engineering: C
    context_engineering: C
    goal_alignment: B
    safety: D
    metadata: B
---

# Review Report — 2026-03-24T134500

**Target:** `/Users/ntbc/workspace/Talos-Homelab`
**Items reviewed:** 13 (10 Skills, 3 Agents)
**Baseline version:** 2026-03-24

---

## 1. analyze-node-hardware (Skill)

**Path:** `.claude/skills/analyze-node-hardware/SKILL.md`

### Goal
Gather comprehensive hardware telemetry from a Talos Linux Kubernetes node via `talosctl` and NFD, then produce a structured Markdown hardware profile document suitable for kernel tuning decisions.

### Certificate

| Dimension | Grade | Weight | Justification |
|-----------|-------|--------|---------------|
| Clarity | A | 15% | Sequential numbered steps, explicit variable naming, deterministic branching for argument resolution |
| Completeness | B | 15% | Happy path and argument variants covered; block-device/PCI loops described in pseudocode rather than executable commands |
| Prompt Engineering | B | 15% | Detailed output-format template, constraint specification, CoT sequencing; lacks role priming and few-shot examples |
| Context Engineering | B | 15% | Tools scoped to task, JIT config-file reads; PCI enumeration inline rather than in reference file |
| Goal Alignment | A | 20% | Covers all critical axes for Talos kernel-tuning analysis including CPU, memory, storage, network, IOMMU, GPU, NFD |
| Safety | B | 15% | Explicit read-only constraint, scoped talosctl flags; no overwrite guard for output document |
| Metadata | B | 5% | Complete frontmatter; description says "NFD" without spelling it out |
| **Overall** | **B** | **100%** | **Weighted: 88.5** |

### Strengths
- Argument resolution is exceptionally clear: two lookup paths, variable assignment, and a fallback-to-clarification all specified explicitly with file paths.
- The output document template is comprehensive — 11 named sections with table schemas defined.
- The sysctl verification step adds real operational value by comparing configured values against live state.
- The `talosctl -n $NODE_IP -e $NODE_IP` pattern is enforced throughout with explanatory note (VIP limitation).

### Recommendations

#### 1. Close the loop/iteration gaps for block-device and PCI enumeration (Impact: High)

The shell loops for `/sys/block/$DEV` and `/sys/bus/pci/devices/$BDF` are described in pseudocode but not as executable commands. A model executing this skill will need to invent the loop structure.

**Current:**
```bash
# Block devices — list /sys/block/ then for each real device read scheduler and rotational
talosctl -n $NODE_IP -e $NODE_IP ls /sys/block/
# For each device (sda, sdb, nvme0n1, etc.):
talosctl -n $NODE_IP -e $NODE_IP read /sys/block/$DEV/queue/scheduler
talosctl -n $NODE_IP -e $NODE_IP read /sys/block/$DEV/queue/rotational
```
**Recommended:**
```bash
BLOCK_DEVS=$(talosctl -n $NODE_IP -e $NODE_IP ls /sys/block/ 2>/dev/null | tail -n +2 | awk '{print $NF}' | grep -vE '^(loop|ram)')
for DEV in $BLOCK_DEVS; do
  echo "=== $DEV ==="
  talosctl -n $NODE_IP -e $NODE_IP read /sys/block/$DEV/queue/scheduler 2>/dev/null || echo "not present"
  talosctl -n $NODE_IP -e $NODE_IP read /sys/block/$DEV/queue/rotational 2>/dev/null || echo "not present"
done
```

#### 2. Add an overwrite guard for the output document (Impact: Medium)

**Current:**
```
Write the analysis to `docs/hardware-analysis-$NODE_NAME.md`
```
**Recommended:**
```
Write the analysis to `docs/hardware-analysis-$NODE_NAME-YYYYMMDD.md` (use today's date).
If a file already exists for today, append a suffix: `-2`, `-3`, etc. Do not overwrite existing analyses.
```

#### 3. Add role priming (Impact: Medium)

**Recommended** — add at the top:
```
You are a Talos Linux infrastructure engineer performing read-only hardware inventory
and kernel-tuning analysis. Your output must be factual, structured, and based solely
on data retrieved from the node.
```

#### 4. Add authentication/connectivity failure stop condition (Impact: Medium)

**Recommended** — add at the start of Step 1:
```bash
# Connectivity pre-check — abort if this fails
talosctl -n $NODE_IP -e $NODE_IP version --short
```
"If this command fails, stop and report the error — do not proceed to generate a hardware profile document with empty data."

#### Reference File Recommendation
A `references/sysctl-catalog.md` listing the sysctl paths with their purpose and expected ranges would offload stable reference data from the skill body.

---

## 2. cilium-policy-debug (Skill)

**Path:** `.claude/skills/cilium-policy-debug/SKILL.md`

### Goal
Diagnose Cilium and Gateway API traffic drops in a homelab Kubernetes cluster, map failures to CiliumNetworkPolicy manifests, and propose least-privilege fixes.

### Certificate

| Dimension | Grade | Weight | Justification |
|-----------|-------|--------|---------------|
| Clarity | B | 15% | Sequential steps numbered and readable; Step 2 lacks decision logic for failure class matching |
| Completeness | C | 15% | Happy path covered; no handling for Hubble unavailability, no kubectl error states, no output template |
| Prompt Engineering | F | 15% | No role priming, no output template with placeholders, no CoT scaffolding, no few-shot examples |
| Context Engineering | C | 15% | Reasonable tool set; kubectl commands pre-listed, no reference file for stable failure classes |
| Goal Alignment | B | 20% | Covers key Cilium failure classes; misses Hubble audit mode and `cilium-dbg monitor` |
| Safety | C | 15% | Hard rules against wildcard policies; no confirmation gate before writing, no stop condition |
| Metadata | B | 5% | Complete and accurate frontmatter |
| **Overall** | **C** | **100%** | **Weighted: 75.25** |

### Strengths
- Correctly identifies homelab-specific manifest paths for immediate actionability.
- Four failure classes (entity identity, post-DNAT port, label gap, AND semantics) are domain-accurate.
- Hard rules against wildcard policies with mandatory hardening follow-up.
- `disable-model-invocation: true` correctly set.

### Recommendations

#### 1. Add Role Priming and Chain-of-Thought Scaffolding (Impact: High)

**Current:**
```
# Cilium Policy Debug

Use this skill when traffic fails between Gateway/API, monitoring components, or intra-cluster services.
```
**Recommended:**
```
# Cilium Policy Debug

You are a Cilium CNI specialist. Your method is evidence-first: never propose a policy patch without
observed drop evidence. Reason step-by-step through identity → policy gap → manifest → fix.

Use this skill when traffic fails between Gateway/API, monitoring components, or intra-cluster services.
```

#### 2. Add an Output Template with Placeholders (Impact: High)

**Recommended** output template:
```markdown
# Cilium Debug: <scope> — <yyyy-mm-dd>

## Evidence
- Drop verdict: <hubble/monitor output snippet>
- Affected identity: <source> → <destination> (<port/proto>)
- Denied by: <policy name or "no matching allow rule">

## Root Cause
<Failure class: entity mismatch | post-DNAT port | label gap | AND semantics conflict>

## Manifest to Patch
- File: <path>
- Current selector/rule: <snippet>
- Proposed change: <snippet>

## Validation Commands
<exact commands to confirm the fix>

## Hardening Follow-up
<Required if any temporary broadening was applied. Otherwise: "N/A">
```

#### 3. Integrate Hubble Audit Mode and `cilium-dbg monitor` (Impact: High)

**Recommended** — add to Step 1:
```bash
# Preferred: Hubble flow filter
hubble observe --verdict DROPPED --namespace <scope-namespace> --last 50

# Fallback: cilium-dbg monitor
kubectl -n kube-system exec -it <cilium-pod> -- cilium-dbg monitor --type drop
```
"Do not proceed to Step 2 without at least one confirmed drop event."

#### 4. Add Stop Condition for kubectl Failures (Impact: Medium)

"If kubectl exits non-zero (kubeconfig missing, cluster unreachable), stop and report."

#### 5. Extract Failure Classes to a Reference File (Impact: Medium)

Create `.claude/skills/cilium-policy-debug/references/failure-classes.md` with the current four classes plus diagnosis criteria.

---

## 3. optimize-node-kernel (Skill)

**Path:** `.claude/skills/optimize-node-kernel/SKILL.md`

### Goal
Research and apply optimized kernel parameters for a Talos node based on hardware analysis, requiring user approval before writing changes.

### Certificate

| Dimension | Grade | Weight | Justification |
|-----------|-------|--------|---------------|
| Clarity | A | 15% | Eight numbered steps, deterministic decision tables for patch placement, hard approval gate |
| Completeness | A | 15% | 8 tuning categories, edge cases (mixed HDD+SSD, KSPP dedup, DRBD drain), failure modes covered |
| Prompt Engineering | B | 15% | Structured output templates, constraint specification, decision table; lacks role priming and few-shot |
| Context Engineering | B | 15% | JIT retrieval well-scoped; tool set very broad (9 tools including unconstrained Agent) |
| Goal Alignment | A | 20% | KSPP dedup guard, schematic vs patch layering, upgrade-vs-apply distinction, per-hardware-class tuning |
| Safety | B | 15% | Approval gate explicit; no halt condition on YAML validation failure, Agent tool unrestricted |
| Metadata | C | 5% | Description undersells scope (omits approval gate, documentation update, verification) |
| **Overall** | **B** | **100%** | **Weighted: 89.5** |

### Strengths
- Patch placement decision table removes ambiguity about where each parameter class belongs.
- Prerequisite gate with actionable user-facing messaging.
- Tuning categories map closely to production Talos + Kubernetes operator needs.
- Explicit `Wait for user approval before proceeding to Step 6`.

### Recommendations

#### 1. Narrow the allowed-tools set (Impact: High)

**Current:**
```
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, WebSearch, WebFetch, Agent
```
**Recommended:**
```
allowed-tools: Bash, Read, Write, Edit, WebSearch, WebFetch
```

#### 2. Add halt condition when YAML validation fails (Impact: High)

Add: "If YAML validation fails for any file, halt all further edits and report the specific parse error. Do not proceed to the next file or to `make gen-configs`."

#### 3. Add role priming (Impact: Medium)

**Recommended:** Add "You are a Linux kernel and Talos infrastructure specialist."

#### 4. Add few-shot example row to recommendation table (Impact: Medium)

**Recommended** example:
```
| `net.core.rmem_max` | `212992` | `134217728` | NIC supports 25GbE; larger receive buffer reduces packet drops |
```

---

## 4. update-schematics (Skill)

**Path:** `.claude/skills/update-schematics/SKILL.md`

### Goal
Analyze node hardware to determine correct Talos Image Factory system extensions per schematic group, present diff for approval, apply changes, and run post-apply make targets.

### Certificate

| Dimension | Grade | Weight | Justification |
|-----------|-------|--------|---------------|
| Clarity | A | 15% | Ten numbered steps, deterministic branching, named stop conditions, explicit approval gate |
| Completeness | A | 15% | Argument validation, API failure fallback, union-rule, YAML validation, kernel-module cross-check |
| Prompt Engineering | B | 15% | Structured output templates, constraint specification; missing CoT and few-shot |
| Context Engineering | A | 15% | JIT retrieval, scoped context, external API as live reference with fallback |
| Goal Alignment | A | 20% | Precise PCI class codes, correct extension mapping, REMOVE behavior, scope boundaries |
| Safety | A | 15% | Approval gate, REMOVE flagged not auto-applied, role patches out of scope, YAML validation |
| Metadata | B | 5% | Complete; description could mention approval-gated workflow |
| **Overall** | **A** | **100%** | **Weighted: 93.0** |

### Strengths
- Precise hardware signal extraction using PCI class codes and vendor IDs.
- Union-rule for shared schematics correctly prevents under-provisioning.
- REMOVE behavior (flag, never auto-remove) is the correct conservative default.
- Fallback strategy on API failure prevents hard failure on transient network errors.
- Explicit scope boundaries prevent overlap with sibling skills.

### Recommendations

#### 1. Add CoT framing to hardware signal extraction (Impact: Medium)

**Recommended** — add explicit reasoning steps before populating the mapping table.

#### 2. Add version-compatibility guard for API calls (Impact: Medium)

**Recommended:**
```bash
TALOS_VERSION_CLEAN="${TALOS_VERSION#v}"
curl -sS "https://factory.talos.dev/version/${TALOS_VERSION_CLEAN}/extensions/official" | jq '.'
```

#### 3. Clarify LTS vs non-LTS extension naming (Impact: Medium)

Add: "Use `-lts` variants when `TALOS_VERSION` tracks an LTS release. Cross-reference the catalog output — only one variant will be present for the given version."

#### Reference File Recommendation
A `references/extension-catalog-notes.md` covering LTS selection rules and kernel module requirements.

---

## 5. execute-cilium-upgrade (Skill)

**Path:** `.claude/skills/execute-cilium-upgrade/SKILL.md`

### Goal
Safely execute a pre-approved Cilium CNI upgrade by validating plan artifact, applying repo changes, and enforcing stage-gate health checks.

### Certificate

| Dimension | Grade | Weight | Justification |
|-----------|-------|--------|---------------|
| Clarity | A | 15% | 11-step sequential workflow, deterministic branching, unambiguous command sequences |
| Completeness | A | 15% | Pre-validation, state freshness, baseline capture, stage gates, stop conditions, recovery, run record |
| Prompt Engineering | B | 15% | Strong constraint specification, structured output; missing CoT for recovery decisions |
| Context Engineering | A | 15% | JIT file reads, reference files named individually, `disable-model-invocation: true` |
| Goal Alignment | A | 20% | Stage gates map to Cilium-specific health signals, stop conditions match official upgrade guide |
| Safety | A | 15% | Multiple hard stops, approval contract, no kubectl apply shortcut, rollback preserves repo |
| Metadata | A | 5% | Complete and accurate |
| **Overall** | **A** | **100%** | **Weighted: 93.5** |

### Strengths
- Immutable approval contract with full frontmatter schema check.
- State freshness gate prevents drift between plan creation and execution.
- Talos-correct rollout path (prohibits `kubectl apply`, routes through `make -C talos upgrade-k8s`).
- 8 named stop conditions covering the full Cilium blast radius.

### Recommendations

#### 1. Add CoT scaffold for recovery path selection (Impact: Medium)

**Recommended** — classify failure scope before choosing recovery:
- Agent restart only (pods crashloop but DaemonSet not rolled forward)
- Partial rollout stall (some nodes on new version)
- Full rollback required (gateway down, broad policy drops)

#### 2. Add consecutive-minor-version guard (Impact: Low)

Confirm `to_version` minor is exactly `from_version` minor + 1.

#### 3. Capture Hubble drop baseline before mutation (Impact: Low)

Add `hubble observe --last 100 --verdict DROP` to pre-change evidence capture.

---

## 6. execute-talos-upgrade (Skill)

**Path:** `.claude/skills/execute-talos-upgrade/SKILL.md`

### Goal
Execute a gated, node-by-node Talos cluster upgrade consuming an approved plan, making repo changes, and performing sequenced rollout with per-node health gates.

### Certificate

| Dimension | Grade | Weight | Justification |
|-----------|-------|--------|---------------|
| Clarity | A | 15% | 11 numbered steps, explicit actions, concrete bash commands, deterministic sequencing |
| Completeness | A | 15% | Pre-flight to final verification, edge cases (Cilium coupling, GPU/Pi, CSR bootstrap) |
| Prompt Engineering | B | 15% | Strong constraint specification; missing CoT for diagnosis/recovery |
| Context Engineering | B | 15% | JIT retrieval; LINSTOR commands duplicated without differentiation |
| Goal Alignment | A | 20% | Repo-first workflow, DRBD/LINSTOR gates, heterogeneous fleet awareness |
| Safety | A | 15% | Approval contract, hard stops, no-improvise rule, `disable-model-invocation: true` |
| Metadata | A | 5% | Complete and accurate |
| **Overall** | **A** | **100%** | **Weighted: 92.0** |

### Strengths
- Repo-first discipline: committed and pushed before any `talosctl upgrade` command.
- Comprehensive stop conditions covering etcd quorum, storage, networking, CSR, stuck-shutdown.
- Evidence capture creates auditable trail critical for homelab with persistent storage.
- Heterogeneous node fleet awareness with explicit ordering.

### Recommendations

#### 1. Add etcd leader-first guidance (Impact: Medium)

Upgrade non-leader control-plane nodes first: `talosctl etcd status` before rollout.

#### 2. Differentiate LINSTOR checks (Impact: Low)

Add inline guidance for what constitutes pass/fail in pre-flight vs per-node gates.

#### 3. Make commit template dynamic (Impact: Low)

Extract `to_version` from plan frontmatter instead of using `<to-version>` placeholder.

---

## 7. gitops-health-triage (Skill)

**Path:** `.claude/skills/gitops-health-triage/SKILL.md`

### Goal
Triage ArgoCD app sync/health drift and produce a focused, GitOps-safe remediation plan.

### Certificate

| Dimension | Grade | Weight | Justification |
|-----------|-------|--------|---------------|
| Clarity | B | 15% | Sequential steps; terse decision logic for failure classification |
| Completeness | C | 15% | Happy path covered; missing operationState extraction, controller logs, per-class remediation |
| Prompt Engineering | C | 15% | Constraint specification and output format present; no role priming, CoT, or examples |
| Context Engineering | B | 15% | Lean tool use; no reference file for remediation patterns |
| Goal Alignment | B | 20% | Failure taxonomy is domain-accurate; misses operationState extraction and controller logs |
| Safety | A | 15% | Hard rule against kubectl apply, output scoped to docs file |
| Metadata | A | 5% | Complete and accurate |
| **Overall** | **B** | **100%** | **Weighted: 84.0** |

### Strengths
- GitOps-first hard rule is explicit and well-positioned.
- Five failure modes are domain-accurate and specific to this cluster's stack.
- Repository path mapping is concrete with exact directory patterns.
- Output format has five named sections with confidence rating.

### Recommendations

#### 1. Extract exact Kubernetes API error before classification (Impact: High)

**Recommended** — add to Step 1:
```bash
kubectl -n argocd get application <app> -o jsonpath='{.status.operationState.message}'
argocd app diff <app> --local
```

#### 2. Add per-failure-class remediation lookup table (Impact: High)

| Failure class | Git change | Emergency live action |
|---|---|---|
| webhook/defaulted-field drift | Add `ignoreDifferences` | — |
| immutable field rejection | Add `Replace: true` sync option | `kubectl delete <resource>` then sync |
| missing CRD/order dependency | Add sync-wave annotations | — |
| Cilium policy blocking | Update NetworkPolicy in overlay | — |
| stale operation state | Patch to clear operationState, git no-op commit | Must follow with git sync |

#### 3. Add confidence calibration guidance (Impact: Medium)

High: failure message directly names resource/field. Medium: pattern match without confirmed diff. Low: multiple plausible classes.

#### 4. Add controller/repo-server log inspection (Impact: Medium)

For generic errors, inspect `argocd-application-controller` and `argocd-repo-server` logs.

#### Reference File Recommendation
Create `.claude/skills/gitops-health-triage/references/argocd-remediation-patterns.md`.

---

## 8. plan-cilium-upgrade (Skill)

**Path:** `.claude/skills/plan-cilium-upgrade/SKILL.md`

### Goal
Build a repo-specific Cilium upgrade plan by resolving versions, reading release notes, identifying breaking changes, and saving a reviewed draft plan with approval gating.

### Certificate

| Dimension | Grade | Weight | Justification |
|-----------|-------|--------|---------------|
| Clarity | A | 15% | Clear sequential workflow, deterministic branching, fail-closed behavior |
| Completeness | A | 15% | Version resolution, intermediate release reading, blast-radius analysis, self-review checklist |
| Prompt Engineering | B | 15% | Constraint specification, self-review gate; lacks explicit CoT and few-shot |
| Context Engineering | B | 15% | JIT retrieval, scoped reads; could use reference file for upgrade constraints |
| Goal Alignment | A | 20% | Comprehensive feature mapping, rollback asymmetry, source citation requirement |
| Safety | A | 15% | Write scoped to docs only, approval gate, fail-closed on cluster access |
| Metadata | A | 5% | Complete and accurate |
| **Overall** | **A** | **100%** | **Weighted: 92.0** |

### Strengths
- Exceptional repo-specificity with real paths, make targets, and KUBECONFIG conventions.
- Correct GitOps discipline with explicit prohibitions against kubectl apply drift.
- Version resolution with fail-closed behavior on cluster unreachable.
- Approval gating via file frontmatter — no plan silently becomes authoritative from chat.
- Self-review gate with explicit checklist before output.

### Recommendations

#### 1. Add one-minor-version-at-a-time hop validation (Impact: Medium)

Flag hops spanning more than one minor version. Recommend staged path. Source: [Cilium Upgrade Guide](https://docs.cilium.io/en/stable/operations/upgrade/)

#### 2. Add Helm `--reuse-values` prohibition (Impact: Medium)

Cilium's upgrade guide explicitly forbids this flag. Add to execution plan constraints.

#### 3. Align Output Format section names with Step 7 (Impact: Low)

Step 7 defines 9 sections; Output Format lists 5 different names. Use the Step 7 names consistently.

#### Reference File Recommendation
Create `.claude/skills/plan-cilium-upgrade/references/cilium-upgrade-constraints.md` with version hop rules, `--reuse-values` prohibition, preflight commands.

---

## 9. plan-talos-upgrade (Skill)

**Path:** `.claude/skills/plan-talos-upgrade/SKILL.md`

### Goal
Build a repo-specific Talos upgrade plan by resolving versions, reading release notes, identifying cluster-specific risks, and saving a reviewed draft plan.

### Certificate

| Dimension | Grade | Weight | Justification |
|-----------|-------|--------|---------------|
| Clarity | A | 15% | Explicit sequential workflow, deterministic branching, fail-closed |
| Completeness | A | 15% | Edge cases (DRBD, GPU, Pi, etcd, Cilium coupling), self-review checklist, source citation |
| Prompt Engineering | B | 15% | Constraint specification, self-review gate; lacks explicit CoT and few-shot |
| Context Engineering | B | 15% | JIT retrieval; could conditionally load schematic files for patch-only upgrades |
| Goal Alignment | A | 20% | Repo-specific facts, blast-radius enumeration, rollback asymmetry acknowledged |
| Safety | A | 15% | Write scoped to docs, approval gate, fail-closed on cluster access |
| Metadata | A | 5% | Complete and accurate |
| **Overall** | **A** | **100%** | **Weighted: 92.0** |

### Strengths
- Exceptional repo specificity (file paths, IP addresses, make targets, node names).
- Fail-closed on cluster access with explicit escape hatch requiring user consent.
- Approval gate architecture via YAML frontmatter.
- Self-review checklist with 9 points including source citation requirement.
- Rollback asymmetry acknowledged.

### Recommendations

#### 1. Add etcd snapshot as required pre-upgrade step (Impact: Medium)

**Recommended** — add to preflight:
```bash
talosctl -n 192.168.2.61 -e 192.168.2.61 etcd snapshot /tmp/etcd-backup-<date>.snapshot
```

#### 2. Add talosctl client version pin check (Impact: Low)

Verify `talosctl version --client` matches or exceeds target version.

#### 3. Align Output Format section names with Step 7 (Impact: Low)

Use the 9 section names from Step 7 consistently in Output Format.

#### Reference File Recommendation
A `references/talos-upgrade-checklist.md` with support matrix URL patterns, Image Factory API endpoint, canonical node upgrade order.

---

## 10. talos-node-maintenance (Skill)

**Path:** `.claude/skills/talos-node-maintenance/SKILL.md`

### Goal
Plan and execute safe single-node Talos day-2 maintenance with preflight checks, operation selection, and post-change verification.

### Certificate

| Dimension | Grade | Weight | Justification |
|-----------|-------|--------|---------------|
| Clarity | B | 15% | Sequential numbered workflow; operation-selection heuristic terse but functional |
| Completeness | C | 15% | Happy path covered; missing etcd backup, node drain, apply modes, `--preserve` flag, rollback |
| Prompt Engineering | C | 15% | Constraint specification and output template present; no role priming, CoT, or examples |
| Context Engineering | B | 15% | Lean, JIT resolution of node IP; no unnecessary tools |
| Goal Alignment | B | 20% | Structure matches domain; weakened by absent backup/drain steps |
| Safety | C | 15% | Hard rules protect generated configs; no etcd quorum check, no drain, no `--preserve` |
| Metadata | A | 5% | Complete and accurate |
| **Overall** | **B** | **100%** | **Weighted: 81.0** |

### Strengths
- Lean, sequential five-step structure.
- Explicit endpoint safety mandating `-n <ip> -e <ip>`.
- Hard rule protecting generated configs from direct edits.
- Good Makefile abstraction.

### Recommendations

#### 1. Add etcd snapshot and config backup before CP operations (Impact: High)

**Recommended** — add to Step 2:
```bash
talosctl etcd snapshot /tmp/etcd-backup-$(date +%Y%m%d).snapshot -n <ip> -e <ip>
talosctl get machineconfig -n <ip> -e <ip> -o yaml > /tmp/machineconfig-<node>.yaml
```

#### 2. Add Kubernetes drain/uncordon around upgrade operations (Impact: High)

**Recommended** — add to Step 3 for upgrades:
```bash
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
# ... run upgrade ...
kubectl uncordon <node>  # after verification passes
```

#### 3. Document apply modes and `--preserve` risk (Impact: Medium)

Add notes on `--mode=staged` for CP nodes and ensure `--preserve` is passed on upgrade.

#### 4. Add etcd quorum check to CP verification (Impact: Medium)

Add `talosctl etcd members` and `talosctl etcd status` to Step 4 for CP nodes.

#### Reference File Recommendation
Create `.claude/skills/talos-node-maintenance/references/talos-operations-guide.md` covering apply modes, `--preserve`, etcd backup, rollback commands.

---

## 11. talos-sre (Agent)

**Path:** `.claude/agents/talos-sre.md`

### Goal
Specialized SRE subagent for Talos Linux node lifecycle management — config generation, apply/upgrade safety, and control-plane stability.

### Certificate

| Dimension | Grade | Weight | Justification |
|-----------|-------|--------|---------------|
| Clarity | C | 15% | Responsibilities listed but no ordered workflow; model must infer step sequence |
| Completeness | D | 15% | No failure modes, no stop conditions, no role-specific risk profiles |
| Prompt Engineering | D | 15% | No role priming beyond title, no CoT, no examples, no output format |
| Context Engineering | C | 15% | Primary files listed but no JIT retrieval instructions for existing rules files |
| Goal Alignment | C | 20% | Correct intent but no operational procedures, no etcd backup, no drain |
| Safety | B | 15% | Three domain-specific guardrails; no stop conditions for failure cases |
| Metadata | B | 5% | Complete and accurate description |
| **Overall** | **C** | **100%** | **Weighted: 74.0** |

### Strengths
- Safety guardrails are domain-specific and correct (explicit endpoints, no generated config edits, risk flagging).
- Correct model selection (`opus` for multi-step safety reasoning).
- Primary files section provides grounding.

### Recommendations

#### 1. Add explicit ordered canonical workflow (Impact: High)

**Recommended:**
```markdown
## Canonical Workflow
1. **gen-configs** — `make -C talos gen-configs`
2. **Dry-run** — `make -C talos dry-run-<node>`; inspect output.
3. **Review** — Confirm node role, check workload/DRBD placement.
4. **Apply or Upgrade** — `make -C talos apply-<node>` or `upgrade-<node>`.
5. **Verify** — Confirm node rejoins, etcd quorum healthy (CP only).
```

#### 2. Add stop conditions and failure modes (Impact: High)

**Recommended:**
```markdown
## Stop Conditions
- `gen-configs` fails or generated config missing
- Dry-run shows errors or unexpected sections
- Etcd quorum below 2/3 before CP reboot
- Prior upgrade left a node in non-Ready state
```

#### 3. Add JIT retrieval for `.claude/rules/` files (Impact: Medium)

**Recommended:**
```markdown
## Reference Files (Read Before Acting)
- `.claude/rules/talos-operations.md` — Safety checklist, hard rules
- `.claude/rules/talos-config.md` — Patch semantics, Makefile targets
- `.claude/rules/talos-nodes.md` — Node inventory, roles, IPs
```

#### 4. Add node role risk profiles (Impact: Medium)

Document CP (highest risk, etcd snapshot required), worker (check DRBD), GPU (verify NVIDIA modules post-reboot).

#### 5. Add reasoning protocol (Impact: Medium)

**Recommended:**
```markdown
## Reasoning Protocol
Before executing: What role? What blast radius? Apply or upgrade? Any stop conditions?
State answers before issuing any command.
```

---

## 12. gitops-operator (Agent)

**Path:** `.claude/agents/gitops-operator.md`

### Goal
Diagnose ArgoCD reconciliation failures, determine minimal git changes to restore convergence, and validate rollout plans within GitOps discipline.

### Certificate

| Dimension | Grade | Weight | Justification |
|-----------|-------|--------|---------------|
| Clarity | C | 15% | Responsibilities listed but no sequential procedure |
| Completeness | D | 15% | No failure handling, no sync-wave reasoning, no escalation path |
| Prompt Engineering | D | 15% | Minimal role priming, no output format template, no CoT |
| Context Engineering | C | 15% | Scoped file references; no explicit Glob/Read instructions |
| Goal Alignment | B | 20% | Accurate domain guardrail, correct preference for deterministic root-cause |
| Safety | C | 15% | kubectl apply prohibited; no constraints on Edit/Write/Bash misuse |
| Metadata | B | 5% | Concise, accurate description |
| **Overall** | **C** | **100%** | **Weighted: 74.5** |

### Strengths
- Prohibition on `kubectl apply` for ArgoCD-managed resources is exactly correct.
- "Prefer deterministic root-cause explanation over speculative fixes" is sound epistemics.
- Scoped file references anchor to correct repo structure.

### Recommendations

#### 1. Add structured diagnostic workflow (Impact: High)

**Recommended** — 7-step triage ladder:
```markdown
## Diagnostic Workflow
1. **Triage scope** — Identify affected apps via app-of-apps topology.
2. **Classify failure** — OutOfSync / health degraded / missing resource / sync-wave deadlock.
3. **Root-cause** — Grep manifests and git history for the specific field causing drift.
4. **Identify minimal change** — Smallest git diff that restores convergence.
5. **Validate** — `kubectl --dry-run=client` or `kustomize build | kubeval`.
6. **Propose with verification** — Include ArgoCD verification command.
7. **If convergence impossible** — State why, list safe escape options, stop.
```

#### 2. Add safety constraints for destructive tools (Impact: High)

**Recommended:**
```markdown
## Guardrails
- No direct cluster mutations — only read-only kubectl commands permitted.
- No destructive file operations outside scoped directories.
- Validation gate before any Edit or Write.
- Confirm before multi-file changes.
```

#### 3. Add sync-wave ordering rules (Impact: Medium)

Document ordering semantics, dependency reasoning, and deadlock detection heuristics.

#### 4. Add output format template (Impact: Medium)

**Recommended:**
```markdown
**Root Cause:** <one sentence>
**Affected Files:** <list>
**Proposed Diff:** <diff>
**Validation Command:** <command>
**Verification Command:** <argocd command>
**Rollback:** <revert path>
```

#### Reference File Recommendation
Create `.claude/references/argocd-gitops-patterns.md` covering sync-wave semantics, reconciliation failure taxonomy, safe escape hatches.

---

## 13. platform-reliability-reviewer (Agent)

**Path:** `.claude/agents/platform-reliability-reviewer.md`

### Goal
Pre-merge reviewer catching reliability regressions, unsafe rollout plans, missing rollback paths, and secret-handling violations in Kubernetes/Talos changes.

### Certificate

| Dimension | Grade | Weight | Justification |
|-----------|-------|--------|---------------|
| Clarity | C | 15% | Review topics listed but no ordered procedure |
| Completeness | C | 15% | Output contract present but lacks severity definitions and pass criteria |
| Prompt Engineering | C | 15% | Basic role priming and constraint spec; no structured output template |
| Context Engineering | C | 15% | Primary files listed but no explicit read instructions |
| Goal Alignment | B | 20% | Domain-specific stack named, real review dimensions covered |
| Safety | D | 15% | Bash allowed but unconstrained for supposedly read-only reviewer |
| Metadata | B | 5% | Accurate description |
| **Overall** | **C** | **100%** | **Weighted: 75.0** |

### Strengths
- Domain specificity names exact stack (ArgoCD, CiliumNetworkPolicy, Talos, SOPS/ksops).
- Output contract includes file+line references and concrete fixes.
- Preference for determinism over speculation.

### Recommendations

#### 1. Remove Bash or add read-only safety gate (Impact: High)

**Option A** — remove Bash entirely:
```yaml
allowed-tools:
  - Read
  - Glob
  - Grep
```
**Option B** — constrain:
```markdown
## Safety Gate
Bash is permitted only for read-only introspection (yq, helm template --dry-run).
Never run kubectl apply, talosctl apply, git commit, or any mutating command.
```

#### 2. Add sequential review procedure (Impact: High)

**Recommended:**
```markdown
## Review Procedure
1. **Discover scope** — Glob changed files.
2. **ArgoCD & CiliumNetworkPolicy regressions** — Check sync policies, health checks.
3. **Talos patch logic** — Verify ordering, quorum safety.
4. **Rollback path** — Confirm every change has identifiable revert.
5. **Secret hygiene** — Grep for plaintext; verify SOPS wiring.
6. **Validation gaps** — Missing health checks, resource limits, readiness probes.
7. **Compile findings** — Group by severity.
```

#### 3. Add severity definitions and pass criteria (Impact: Medium)

**Recommended:**
```markdown
- **BLOCKING** — Must resolve before merge.
- **WARNING** — Should address; merge with acknowledgment.
- **INFO** — Residual risk or improvement notes.

Final verdict: APPROVED | APPROVED WITH WARNINGS | BLOCKED
```

#### 4. Add detailed role priming (Impact: Medium)

**Recommended:**
```markdown
You are a senior platform reliability engineer specializing in Kubernetes GitOps,
Talos Linux, and ArgoCD. You review with the rigor of a production on-call engineer.
```

#### Reference File Recommendation
Create `.claude/agents/references/platform-reliability-checklist.md` covering SOPS wiring patterns, ArgoCD health check requirements, Talos patch quorum rules, CiliumNetworkPolicy completeness criteria.

---

## Summary

| Item | Type | Overall | Clarity | Completeness | PE | CE | Goal | Safety | Meta |
|------|------|---------|---------|--------------|----|----|------|--------|------|
| analyze-node-hardware | Skill | B (88.5) | A | B | B | B | A | B | B |
| cilium-policy-debug | Skill | C (75.25) | B | C | F | C | B | C | B |
| optimize-node-kernel | Skill | B (89.5) | A | A | B | B | A | B | C |
| update-schematics | Skill | A (93.0) | A | A | B | A | A | A | B |
| execute-cilium-upgrade | Skill | A (93.5) | A | A | B | A | A | A | A |
| execute-talos-upgrade | Skill | A (92.0) | A | A | B | B | A | A | A |
| gitops-health-triage | Skill | B (84.0) | B | C | C | B | B | A | A |
| plan-cilium-upgrade | Skill | A (92.0) | A | A | B | B | A | A | A |
| plan-talos-upgrade | Skill | A (92.0) | A | A | B | B | A | A | A |
| talos-node-maintenance | Skill | B (81.0) | B | C | C | B | B | C | A |
| talos-sre | Agent | C (74.0) | C | D | D | C | C | B | B |
| gitops-operator | Agent | C (74.5) | C | D | D | C | B | C | B |
| platform-reliability-reviewer | Agent | C (75.0) | C | C | C | C | B | D | B |

---

## Cross-Cutting Observations

### Common Anti-Patterns

1. **Agents lack structured workflows.** All three agents describe responsibilities but provide no sequential procedure. This is the single largest systemic issue — skills average B+ while agents average C.

2. **Prompt Engineering gap across agents.** All agents score D on Prompt Engineering. They lack role priming, CoT scaffolding, output format templates, and examples. Skills consistently score B by using at least 3 techniques.

3. **Missing stop conditions in agents.** None of the three agents define what causes them to halt. This is critical for agents with Bash/Write/Edit access.

4. **No reference files anywhere.** No skill or agent uses a `references/` subdirectory for stable domain knowledge. Several items (cilium-policy-debug failure classes, gitops-health-triage remediation patterns, talos-sre operational procedures) would benefit significantly from reference file separation.

### Consistent Strengths

1. **Strong safety in execution skills.** The plan→execute skill pairs (plan-cilium-upgrade/execute-cilium-upgrade, plan-talos-upgrade/execute-talos-upgrade) have excellent approval gates, stop conditions, and least-privilege scoping.

2. **Repo-specific grounding.** Skills consistently encode real file paths, IP addresses, make targets, and node names rather than relying on generic knowledge.

3. **Metadata quality.** 12 of 13 items have complete, accurate frontmatter with `disable-model-invocation: true` correctly applied.

### Systemic Recommendations

1. **Elevate agent quality to match skills.** Apply the same structured workflow, stop conditions, and output format patterns from the A-graded skills to all three agents.

2. **Add reference files for stable domain knowledge.** Priority candidates: Cilium failure class taxonomy, ArgoCD remediation patterns, Talos operations guide, platform reliability checklist.

3. **Add JIT retrieval instructions to agents.** The repo has rich `.claude/rules/` files that agents should explicitly read before acting — currently only skills reference these.

4. **Add role priming universally.** Only 2 of 13 items have any role priming. A single domain-specific sentence at the top of each item would improve consistency.
