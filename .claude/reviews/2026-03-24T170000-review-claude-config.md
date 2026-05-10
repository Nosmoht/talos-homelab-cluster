---
generated_by: review-claude-config
schema_version: 1
date: 2026-03-24
target: /Users/ntbc/workspace/Talos-Homelab
baseline_version: 2026-03-24
items_reviewed: 13
summary:
  - name: cilium-policy-debug
    type: Skill
    path: .claude/skills/cilium-policy-debug/SKILL.md
    overall: B
    score: 86.5
    clarity: A
    completeness: B
    prompt_engineering: B
    context_engineering: B
    goal_alignment: A
    safety: B
    metadata: A
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
    score: 93.5
    clarity: A
    completeness: A
    prompt_engineering: B
    context_engineering: A
    goal_alignment: A
    safety: A
    metadata: A
  - name: plan-talos-upgrade
    type: Skill
    path: .claude/skills/plan-talos-upgrade/SKILL.md
    overall: A
    score: 93.5
    clarity: A
    completeness: A
    prompt_engineering: A
    context_engineering: A
    goal_alignment: A
    safety: B
    metadata: A
  - name: update-schematics
    type: Skill
    path: .claude/skills/update-schematics/SKILL.md
    overall: A
    score: 90.5
    clarity: A
    completeness: B
    prompt_engineering: B
    context_engineering: B
    goal_alignment: A
    safety: A
    metadata: A
  - name: optimize-node-kernel
    type: Skill
    path: .claude/skills/optimize-node-kernel/SKILL.md
    overall: A
    score: 92.75
    clarity: A
    completeness: A
    prompt_engineering: A
    context_engineering: B
    goal_alignment: A
    safety: A
    metadata: A
  - name: analyze-node-hardware
    type: Skill
    path: .claude/skills/analyze-node-hardware/SKILL.md
    overall: A
    score: 91.5
    clarity: A
    completeness: A
    prompt_engineering: A
    context_engineering: B
    goal_alignment: A
    safety: A
    metadata: A
  - name: talos-node-maintenance
    type: Skill
    path: .claude/skills/talos-node-maintenance/SKILL.md
    overall: B
    score: 86.5
    clarity: B
    completeness: B
    prompt_engineering: B
    context_engineering: A
    goal_alignment: A
    safety: B
    metadata: A
  - name: gitops-health-triage
    type: Skill
    path: .claude/skills/gitops-health-triage/SKILL.md
    overall: A
    score: 90.35
    clarity: A
    completeness: B
    prompt_engineering: A
    context_engineering: B
    goal_alignment: A
    safety: A
    metadata: A
  - name: plan-cilium-upgrade
    type: Skill
    path: .claude/skills/plan-cilium-upgrade/SKILL.md
    overall: A
    score: 93.25
    clarity: A
    completeness: A
    prompt_engineering: A
    context_engineering: A
    goal_alignment: A
    safety: A
    metadata: A
  - name: talos-sre
    type: Agent
    path: .claude/agents/talos-sre.md
    overall: A
    score: 92.0
    clarity: A
    completeness: A
    prompt_engineering: A
    context_engineering: A
    goal_alignment: A
    safety: B
    metadata: A
  - name: gitops-operator
    type: Agent
    path: .claude/agents/gitops-operator.md
    overall: A
    score: 90.35
    clarity: A
    completeness: B
    prompt_engineering: A
    context_engineering: B
    goal_alignment: A
    safety: A
    metadata: A
  - name: platform-reliability-reviewer
    type: Agent
    path: .claude/agents/platform-reliability-reviewer.md
    overall: B
    score: 89.75
    clarity: A
    completeness: B
    prompt_engineering: B
    context_engineering: A
    goal_alignment: A
    safety: A
    metadata: B
---

# Review Report — 2026-03-24T170000

## cilium-policy-debug (Skill)

### Goal
Diagnose Cilium network policy traffic drops using live Hubble/monitor evidence, classify failures against known patterns, map them to Git-tracked CiliumNetworkPolicy manifests, and propose least-privilege fixes with validation commands.

### Certificate

| Dimension | Grade | Weight | Justification |
|-----------|-------|--------|---------------|
| Clarity | A | 15% | Explicit 4-step workflow with gate conditions ("do not proceed without drop evidence"), concrete commands, deterministic output template |
| Completeness | B | 15% | Core and error paths covered (cluster unreachable, hubble fallback); missing no-drops-found path, hubble unavailable fallback |
| Prompt Engineering | B | 15% | Role priming, CoT, constraint specification, output template; lacks few-shot examples for classification |
| Context Engineering | B | 15% | JIT reference loading, reference file separation, minimal tool set |
| Goal Alignment | A | 20% | Evidence-first approach matches domain best practices; Hubble filtering, least-privilege, hardening follow-up |
| Safety | B | 15% | `disable-model-invocation: true`, stop condition on unreachable cluster, hard rules against wildcards; missing confirmation gate before write |
| Metadata | A | 5% | All frontmatter fields present and accurate |
| **Overall** | **B** | **100%** | **Weighted: 86.5** |

### Strengths
- Evidence-first philosophy with explicit gate preventing premature fix proposals
- Well-structured output template capturing evidence, root cause, manifest path, patch, and validation
- Reference file separation for failure class knowledge

### Recommendations

#### 1. Add a "no drops found" path (Impact: Medium)
**Current:**
```
Do not proceed to Step 2 without at least one confirmed drop event showing source identity, destination, and port.
```
**Recommended:**
```
Do not proceed to Step 2 without at least one confirmed drop event.

If no drops are observed:
1. Widen the namespace scope or remove the namespace filter.
2. Reproduce the failing request while hubble observe is running.
3. Check `cilium-dbg policy get` on the relevant endpoint.
4. If still no drops, report: "No drop evidence found. The issue may be DNS, service misconfiguration, or intermittent."
```

#### 2. Add audit mode validation strategy (Impact: Medium)
**Current:** Validation commands section with no pre-enforcement testing.
**Recommended:** Add `policy.cilium.io/audit-mode: "enabled"` annotation step to validate policies before enforcement.

#### 3. Add confirmation gate before writing output (Impact: Medium)
**Current:** `Write docs/cilium-debug-<scope>-<yyyy-mm-dd>.md using this template:`
**Recommended:** `Present the completed report to the user for review. After user confirmation, write...`

---

## execute-cilium-upgrade (Skill)

### Goal
Execute a pre-approved Cilium CNI upgrade on a Talos-managed homelab Kubernetes cluster by validating the plan artifact, applying repo changes, reconciling via Talos workflows, and enforcing health gates with classified recovery paths.

### Certificate

| Dimension | Grade | Weight | Justification |
|-----------|-------|--------|---------------|
| Clarity | A | 15% | 11 sequential steps with explicit commands, file paths, and unambiguous stop/continue logic |
| Completeness | A | 15% | Full lifecycle: input validation, pre-flight, evidence, repo mutation, diff review, commit, rollout, health gates, 9 stop conditions, 3 recovery paths, verification |
| Prompt Engineering | B | 15% | Strong constraints, output format, hard rules; lacks few-shot examples and role priming |
| Context Engineering | A | 15% | JIT retrieval of 7 context files, domain facts pinned to repo paths, plan artifact as single input |
| Goal Alignment | A | 20% | Respects Talos extraManifests workflow, prohibits kubectl-apply shortcuts, covers Cilium-specific health signals |
| Safety | A | 15% | `disable-model-invocation: true`, approved-plan gating, 9 stop conditions, 3 classified recovery paths, "do not improvise" guardrail |
| Metadata | A | 5% | Complete frontmatter with accurate description and argument-hint |
| **Overall** | **A** | **100%** | **Weighted: 93.5** |

### Strengths
- Rigorous plan-gate architecture with frontmatter approval contract
- Classified recovery paths (agent restart, partial stall, full rollback) with "do not improvise"
- Evidence-based audit trail via run record
- Domain-precise health gates (ciliumnode, Gateway API, Hubble, L2, policy drops)

### Recommendations

#### 1. Add rollout monitoring cadence and timeout (Impact: Medium)
**Current:** `monitor Cilium agent and operator rollout to completion`
**Recommended:** Add polling interval (30s) and stall timeout (10 minutes → stop condition).

#### 2. Add plan staleness check (Impact: Low)
**Recommended:** Warn if `approved_at` is more than 7 days old.

---

## execute-talos-upgrade (Skill)

### Goal
Execute a validated, approved Talos Linux cluster upgrade through a gated node-by-node rollout with pre-flight checks, per-node health gates, explicit stop conditions, and recovery actions.

### Certificate

| Dimension | Grade | Weight | Justification |
|-----------|-------|--------|---------------|
| Clarity | A | 15% | 11-step workflow with clear sequencing, numbered steps, explicit bash commands, stop/continue logic |
| Completeness | A | 15% | Full lifecycle with specific node IPs, file paths, 8 stop conditions, recovery actions, final verification |
| Prompt Engineering | B | 15% | Strong constraints and hard rules; lacks few-shot examples for run record structure |
| Context Engineering | A | 15% | JIT retrieval of 6+ files, cluster topology with explicit IPs, generated config separation |
| Goal Alignment | A | 20% | Plan-then-execute pattern, etcd leader avoidance, VIP prohibition, DRBD-aware |
| Safety | A | 15% | `disable-model-invocation: true`, 8 stop conditions, "never continue past stop", no parallel upgrades, drift detection |
| Metadata | A | 5% | Complete frontmatter with accurate description |
| **Overall** | **A** | **100%** | **Weighted: 93.5** |

### Strengths
- Exceptional safety architecture with two-skill plan/execute separation
- Etcd quorum awareness — upgrades non-leader CP nodes first
- Full audit trail via pre-change evidence record and run record
- Repo-cluster state synchronization in steps 2 and 5

### Recommendations

#### 1. Add run record example template (Impact: Medium)
**Recommended:** Add a concrete example structure for the run record with frontmatter and per-node rollout log.

#### 2. Add explicit etcd backup step (Impact: Medium)
**Recommended:** Add `talosctl etcd snapshot` before rollout begins.

#### 3. Specify default health-check wait thresholds (Impact: Low)
**Recommended:** Default 10 minutes for CP nodes, 5 minutes for workers.

---

## plan-talos-upgrade (Skill)

### Goal
Produce a comprehensive, repo-aware Talos Linux upgrade and migration plan by resolving versions, reading all intermediate release notes, identifying cluster-specific risks, and saving a reviewed draft for manual operator approval.

### Certificate

| Dimension | Grade | Weight | Justification |
|-----------|-------|--------|---------------|
| Clarity | A | 15% | 11 well-structured steps, explicit input handling rules, clear plan-only boundary |
| Completeness | A | 15% | Full lifecycle: version resolution, intermediate releases, impact analysis, migration plan, rollback, self-review, artifact, approval |
| Prompt Engineering | A | 15% | CoT via 11-step workflow, constraints ("Repository Facts"), self-review checklist as feedback loop |
| Context Engineering | A | 15% | JIT retrieval of 12+ repo files, external release notes on demand, scoped per-step |
| Goal Alignment | A | 20% | Plan-only boundary stated and reinforced, manual approval gate, all deliverables map to required outcome |
| Safety | B | 15% | Write justified for draft artifact, Bash for cluster queries; could explicitly restrict Bash to read-only |
| Metadata | A | 5% | Complete frontmatter with accurate description and argument-hint |
| **Overall** | **A** | **100%** | **Weighted: 93.5** |

### Strengths
- Thorough version resolution logic with all three argument arities
- Mandatory intermediate release note reading (all patches, not just minors)
- Self-review checklist (10 items) as built-in verification gate
- Deep repo context loading (12+ files)

### Recommendations

#### 1. Restrict Bash to read-only commands (Impact: Medium)
**Recommended:** Add explicit constraint: Bash only for `talosctl get/version`, `curl`, `git log/diff` — no mutating commands during planning.

#### 2. Add output length guidance (Impact: Low)
**Recommended:** Target 200-400 lines, prefer tables over prose.

---

## update-schematics (Skill)

### Goal
Analyze node hardware profiles and update Talos Image Factory schematic YAML files with the correct set of system extensions, gated by user approval.

### Certificate

| Dimension | Grade | Weight | Justification |
|-----------|-------|--------|---------------|
| Clarity | A | 15% | 10 well-named steps with clear sequential progression, explicit scope boundaries |
| Completeness | B | 15% | Full workflow from argument resolution through reporting; some steps use parenthetical shorthand |
| Prompt Engineering | B | 15% | Structured decomposition, approval gate, curated mapping table, fallback logic; no role priming or examples |
| Context Engineering | B | 15% | JIT retrieval, upstream/downstream skill scoping; no token budget awareness for multi-node runs |
| Goal Alignment | A | 20% | Directly addresses stated goal, clear input/output contract, explicit scope boundary with optimize-node-kernel |
| Safety | A | 15% | `disable-model-invocation: true`, explicit approval gate at Step 7, YAML validation, mismatch warnings |
| Metadata | A | 5% | Complete frontmatter with accurate description and argument-hint |
| **Overall** | **A** | **100%** | **Weighted: 90.5** |

### Strengths
- Strong safety architecture with approval gate and YAML validation
- Clear scope boundaries with adjacent skills
- Resilient data retrieval with API fallback
- Well-structured 10-step pipeline

### Recommendations

#### 1. Add role priming (Impact: Medium)
**Recommended:** Add "You are a Talos Linux infrastructure engineer" with CoT directive.

#### 2. Add context budget guidance for multi-node runs (Impact: Low)
**Recommended:** Batch hardware analysis docs in groups of 3-5 when processing `all`.

---

## optimize-node-kernel (Skill)

### Goal
Research hardware-specific Linux kernel parameters and apply optimized sysctl/boot settings to a Talos Kubernetes node, using its hardware analysis document as input.

### Certificate

| Dimension | Grade | Weight | Justification |
|-----------|-------|--------|---------------|
| Clarity | A | 15% | 8 sequential steps, clear decision tables, explicit placement rules, role priming |
| Completeness | A | 15% | All 6 tuning categories, prerequisite checks, research, categorization, approval gate, application, documentation, verification |
| Prompt Engineering | A | 15% | Role priming, structured output templates, 4 critical rules, CoT in Step 4, verification steps |
| Context Engineering | B | 15% | Good JIT retrieval, conditional file loading; no token budget awareness, no bundled reference files |
| Goal Alignment | A | 20% | Perfectly aligned with stated purpose, hardware-driven research, placement decision table |
| Safety | A | 15% | `disable-model-invocation: true`, approval gate, YAML validation with halt, semantic diff validation, rollback instructions |
| Metadata | A | 5% | Complete frontmatter with accurate description |
| **Overall** | **A** | **100%** | **Weighted: 92.75** |

### Strengths
- Exceptional placement decision table eliminating ambiguity across patch layers
- Multi-layer validation pipeline (YAML syntax → semantic diff → rollback)
- Hardware-driven conditional logic throughout
- "Not Recommended" table for documenting rejected parameters

### Recommendations

#### 1. Add few-shot example for parameter recommendation (Impact: Medium)
**Recommended:** Include one worked example row in the output template.

#### 2. Add explicit warning about disabling CPU mitigations (Impact: Medium)
**Recommended:** Never recommend `mitigations=off` unless user explicitly requests and acknowledges security risk.

---

## analyze-node-hardware (Skill)

### Goal
Perform comprehensive hardware inventory and kernel-tuning analysis of a Talos Kubernetes node, producing a structured hardware profile document.

### Certificate

| Dimension | Grade | Weight | Justification |
|-----------|-------|--------|---------------|
| Clarity | A | 15% | Well-structured role priming, step numbering, explicit bash code blocks with comments |
| Completeness | A | 15% | 20+ talosctl reads, NFD labels, USB inventory, live sysctls, current config state, gap analysis with CoT |
| Prompt Engineering | A | 15% | Role priming, constraints ("do not infer"), structured output template (11 sections), CoT in gap analysis |
| Context Engineering | B | 15% | Good JIT retrieval, PCI >40 summarization rule; no token budget cap for output, no reference files |
| Goal Alignment | A | 20% | Tightly aligned: hardware inventory + kernel-tuning gap analysis, output maps 1:1 to gathered data |
| Safety | A | 15% | `disable-model-invocation: true`, "read-only" role priming, Write scoped to single output path |
| Metadata | A | 5% | Complete frontmatter with all fields |
| **Overall** | **A** | **100%** | **Weighted: 91.5** |

### Strengths
- Exceptional data gathering coverage (20+ talosctl reads)
- Three-layer safety: frontmatter, role priming, Important Notes
- Built-in CoT for gap analysis (Section 6.3)
- Graceful degradation for missing hardware

### Recommendations

#### 1. Add AMD CPU path for frequency governor (Impact: Medium)
**Recommended:** Add `cpufreq/boost` sysfs path for AMD alongside Intel `intel_pstate/no_turbo`.

#### 2. Add timeout/retry note for talosctl commands (Impact: Medium)
**Recommended:** `timeout 10` for connectivity check, abort after 3 consecutive failures.

---

## talos-node-maintenance (Skill)

### Goal
Enable safe, single-node Talos Linux day-2 maintenance operations with preflight safety checks, appropriate operation selection, post-change verification, and documentation.

### Certificate

| Dimension | Grade | Weight | Justification |
|-----------|-------|--------|---------------|
| Clarity | B | 15% | Well-structured workflow with CoT; staged mode decision criteria could be clearer |
| Completeness | B | 15% | Covers apply/upgrade, CP etcd safety, drain/uncordon, rollback; missing DRBD placement check, Pi nodes, timeout guidance |
| Prompt Engineering | B | 15% | Role priming, CoT, code examples, constraints, stop conditions; missing output template, no examples |
| Context Engineering | A | 15% | JIT reference loading, reference file separation, token-efficient |
| Goal Alignment | A | 20% | Tightly focused on single-node day-2 ops, scopes out multi-node and K8s version upgrades |
| Safety | B | 15% | `disable-model-invocation: true`, etcd backup, quorum check, dry-run; missing confirmation gate before apply/upgrade, missing DRBD check |
| Metadata | A | 5% | Complete frontmatter with all fields |
| **Overall** | **B** | **100%** | **Weighted: 86.5** |

### Strengths
- Safety-first preflight sequence (etcd snapshot, machineconfig backup, quorum check, dry-run)
- Good reference architecture with JIT loading
- Accurate domain modeling of apply vs upgrade decision tree

### Recommendations

#### 1. Add user confirmation gate before destructive operations (Impact: High)
**Recommended:** Present maintenance plan summary and wait for explicit approval before executing apply/upgrade.

#### 2. Add DRBD/storage placement verification before drain (Impact: High)
**Recommended:** `kubectl linstor volume list --nodes <node>` — verify all volumes have at least one healthy replica elsewhere.

#### 3. Add structured output template (Impact: Medium)
**Recommended:** Add markdown template for maintenance doc with Change Summary, Commands Executed, Verification Results, Recovery Notes.

---

## gitops-health-triage (Skill)

### Goal
Diagnose ArgoCD application sync/health failures and produce a structured, GitOps-safe remediation plan with calibrated confidence levels.

### Certificate

| Dimension | Grade | Weight | Justification |
|-----------|-------|--------|---------------|
| Clarity | A | 15% | Clear role priming, well-structured 4-step workflow, explicit bash commands |
| Completeness | B | 15% | 7 failure classes, fallback log inspection, confidence calibration; missing RBAC, resource quota, sync loop classes |
| Prompt Engineering | A | 15% | Role priming, CoT, JIT reference reads, constraint-based hard rules |
| Context Engineering | B | 15% | Good reference file usage, token-efficient |
| Goal Alignment | A | 20% | Directly serves triage goal, severity-sorted `all` mode, calibrated confidence |
| Safety | A | 15% | `disable-model-invocation: true`, hard rules against kubectl apply, Write scoped to docs/ |
| Metadata | A | 5% | Complete frontmatter with all fields |
| **Overall** | **A** | **100%** | **Weighted: 90.35** |

### Strengths
- Excellent failure taxonomy with structured remediation lookup table
- Strong safety posture with GitOps discipline enforcement
- Calibrated confidence levels (High/Medium/Low) with clear definitions
- Graceful fallback for empty error messages

### Recommendations

#### 1. Add missing failure classes (Impact: Medium)
**Recommended:** Add RBAC/permission denied, resource quota exceeded, sync loop (HPA/VPA/cert-manager drift), resource suspended.

#### 2. Add output example (Impact: Medium)
**Recommended:** Include a concrete few-shot example of a completed triage report.

#### 3. Add explicit destructive-command guard (Impact: Low)
**Recommended:** Explicit allowlist for kubectl commands (get, describe, logs, patch for operationState only).

---

## plan-cilium-upgrade (Skill)

### Goal
Generate a comprehensive, repo-specific Cilium CNI upgrade plan by resolving versions, analyzing intermediate release notes, and producing a reviewable draft artifact with rollback procedures.

### Certificate

| Dimension | Grade | Weight | Justification |
|-----------|-------|--------|---------------|
| Clarity | A | 15% | 11-step workflow, 3-arity input handling with examples |
| Completeness | A | 15% | 9 deliverables, 4 failure modes, rollback, drift detection, consecutive minor validation |
| Prompt Engineering | A | 15% | CoT via sequential workflow, constraints, self-review checklist |
| Context Engineering | A | 15% | JIT retrieval of 7+ files, reference file for constraints, GitHub API, WebSearch |
| Goal Alignment | A | 20% | Bootstrap coupling awareness, consecutive minor hop validation, manual approval gate |
| Safety | A | 10% | No Edit tool, Write only for draft artifacts, manual approval gate, 4 abort conditions |
| Metadata | A | 10% | Complete frontmatter with accurate description |
| **Overall** | **A** | **100%** | **Weighted: 93.25** |

### Strengths
- Thorough version resolution pipeline with drift detection
- Cluster-specific impact analysis against actual feature flags
- Safety-by-design with no Edit tool and manual approval gate
- Bootstrap coupling awareness prevents dangerous out-of-band changes

### Recommendations

#### 1. Add concrete output example fragment (Impact: Medium)
**Recommended:** Include a short example of Version Resolution and Breaking Changes sections.

#### 2. Add token/length guidance for release note processing (Impact: Low)
**Recommended:** Summarize per-release to single table row if total content exceeds ~8K tokens.

---

## talos-sre (Agent)

### Goal
Serve as a safety-focused Talos Linux SRE agent that generates, validates, and applies node configurations while enforcing etcd quorum protection and blast-radius reasoning.

### Certificate

| Dimension | Grade | Weight | Justification |
|-----------|-------|--------|---------------|
| Clarity | A | 15% | Explicit role, workflow, stop conditions, risk profiles, reasoning protocol |
| Completeness | A | 15% | Full node lifecycle, risk profile differentiation, stop conditions; missing rollback procedures |
| Prompt Engineering | A | 15% | Role priming, reasoning protocol as CoT forcing function, stop conditions as constraints |
| Context Engineering | A | 15% | JIT reference loading, 3 well-scoped rules files, lean agent body |
| Goal Alignment | A | 20% | Every section serves node lifecycle safety, reference file architecture ensures current state |
| Safety | B | 15% | Guardrails present, stop conditions, endpoint rules; no explicit user confirmation gate before destructive ops |
| Metadata | A | 5% | Complete frontmatter with all fields |
| **Overall** | **A** | **100%** | **Weighted: 92.0** |

### Strengths
- Reasoning protocol as CoT forcing function (4-question pre-action checklist)
- JIT reference file architecture with 3 scoped rules files
- Stop conditions as hard constraints (halt-and-report, not advisory)
- Risk profile differentiation (CP/Worker/GPU)

### Recommendations

#### 1. Add user confirmation gate before apply/upgrade (Impact: High)
**Recommended:** After review step, present dry-run diff and reasoning answers, wait for explicit user approval.

#### 2. Add structured output template (Impact: Medium)
**Recommended:** Define output format: Node, Operation, Reasoning, Dry-run result, Outcome, Post-checks.

#### 3. Add rollback procedures (Impact: Medium)
**Recommended:** Failed apply → revert and re-apply; failed upgrade → `talosctl rollback`; etcd loss → restore from snapshot.

---

## gitops-operator (Agent)

### Goal
Provide a specialized ArgoCD and Kubernetes GitOps operator that diagnoses reconciliation failures and proposes minimal, safe git-based changes.

### Certificate

| Dimension | Grade | Weight | Justification |
|-----------|-------|--------|---------------|
| Clarity | A | 15% | Strong role priming, clear 7-step diagnostic workflow |
| Completeness | B | 15% | Covers diagnostic workflow, sync-wave rules, output format, guardrails; missing error-handling for absent reference files |
| Prompt Engineering | A | 15% | CoT enforced, structured output template, role priming, constraints |
| Context Engineering | B | 15% | JIT reference loading, scoped primary files; no token budget guidance |
| Goal Alignment | A | 20% | Directly aligned with GitOps operator role, 7-step workflow maps to use cases |
| Safety | A | 15% | Prohibits kubectl apply/delete/patch, validation gate before Edit/Write, confirmation before multi-file changes |
| Metadata | A | 5% | Correct frontmatter with all fields |
| **Overall** | **A** | **100%** | **Weighted: 90.35** |

### Strengths
- Robust safety model prohibiting cluster mutations on ArgoCD-managed resources
- Methodical 7-step diagnostic pipeline enforcing CoT
- Well-scoped 6-field structured output format
- Clear operational philosophy: "minimal, deterministic git changes over speculative cluster mutations"

### Recommendations

#### 1. Add few-shot diagnostic example (Impact: Medium)
**Recommended:** Include a concrete worked example showing Root Cause, Affected Files, Proposed Diff, etc.

#### 2. Add reference file absence handling (Impact: Low)
**Recommended:** "If a file is missing or unreadable, note it and proceed with model knowledge — do not halt."

#### 3. Add explicit Bash dry-run default (Impact: Medium)
**Recommended:** "Bash commands default to read-only: prefer `kubectl get`, `describe`, `argocd app get/diff`, `kustomize build`."

---

## platform-reliability-reviewer (Agent)

### Goal
Serve as an automated pre-merge reliability and security reviewer for Kubernetes/Talos infrastructure changes, catching regressions and unsafe rollout plans.

### Certificate

| Dimension | Grade | Weight | Justification |
|-----------|-------|--------|---------------|
| Clarity | A | 15% | Explicit 7-step procedure with "do not skip steps", concrete severity definitions |
| Completeness | B | 15% | Core review dimensions covered; missing early-exit handling, reference file absence handling |
| Prompt Engineering | B | 15% | Role priming, output template, constraints, CoT; missing few-shot examples, no self-verification step |
| Context Engineering | A | 15% | Minimal tool set (Read, Glob, Grep — exactly what's needed), JIT reference loading, scoped primary files |
| Goal Alignment | A | 20% | Domain-specific checks (CiliumNetworkPolicy, SOPS, webhook defaults), severity-based classification |
| Safety | A | 10% | Read-only tools — textbook least-privilege for a reviewer |
| Metadata | B | 10% | All required fields present; description accurate; minor: could note review-only nature |
| **Overall** | **B** | **100%** | **Weighted: 89.75** |

### Strengths
- Excellent role priming with operational urgency ("catch what will break at 2am")
- Precise tool scoping — three read-only tools, no more, no less
- Domain-specific review checklist mapping to real Kubernetes failure modes
- Structured output contract with three verdict levels

### Recommendations

#### 1. Add few-shot finding example (Impact: Medium)
**Recommended:** Include concrete BLOCKING and WARNING examples with `[SEVERITY] file:line — description / Fix:` format.

#### 2. Add early-exit and error handling (Impact: Medium)
**Recommended:** If no files match scope → APPROVED verdict. If reference file missing → INFO finding and continue.

#### 3. Add self-verification step (Impact: Medium)
**Recommended:** Before compiling findings, re-read cited file:line for each BLOCKING finding to confirm and eliminate false positives.

---

## Summary

| Item | Type | Overall | Clarity | Completeness | PE | CE | Goal | Safety | Meta |
|------|------|---------|---------|--------------|----|----|------|--------|------|
| cilium-policy-debug | Skill | B (86.5) | A | B | B | B | A | B | A |
| execute-cilium-upgrade | Skill | A (93.5) | A | A | B | A | A | A | A |
| execute-talos-upgrade | Skill | A (93.5) | A | A | B | A | A | A | A |
| plan-talos-upgrade | Skill | A (93.5) | A | A | A | A | A | B | A |
| update-schematics | Skill | A (90.5) | A | B | B | B | A | A | A |
| optimize-node-kernel | Skill | A (92.75) | A | A | A | B | A | A | A |
| analyze-node-hardware | Skill | A (91.5) | A | A | A | B | A | A | A |
| talos-node-maintenance | Skill | B (86.5) | B | B | B | A | A | B | A |
| gitops-health-triage | Skill | A (90.35) | A | B | A | B | A | A | A |
| plan-cilium-upgrade | Skill | A (93.25) | A | A | A | A | A | A | A |
| talos-sre | Agent | A (92.0) | A | A | A | A | A | B | A |
| gitops-operator | Agent | A (90.35) | A | B | A | B | A | A | A |
| platform-reliability-reviewer | Agent | B (89.75) | A | B | B | A | A | A | B |

## Cross-Cutting Observations

### Consistent Strengths
- **Safety discipline is excellent across the board.** Nearly every item uses `disable-model-invocation: true`, explicit stop conditions, and domain-appropriate guardrails. The plan/execute skill pairing with frontmatter approval gates is a standout pattern.
- **JIT reference file architecture.** All items defer stable knowledge to `.claude/rules/` or `references/` files, keeping skill bodies lean and context-efficient.
- **Domain-specific awareness.** Skills reference actual repo paths, Makefile targets, and cluster topology rather than generic Kubernetes patterns.

### Common Gaps
- **Few-shot examples are missing from most items.** Only 5/13 items score A on Prompt Engineering. Adding a single worked example to each output template would improve consistency.
- **User confirmation gates are inconsistent.** Some skills have explicit confirmation steps before writes; others proceed directly. All destructive skills and agents should have a uniform confirmation pattern.
- **Context Engineering scores lag other dimensions.** Several items lack token budget awareness or context management guidance for multi-node/multi-app runs.

### Systemic Recommendations
1. Add a shared `references/output-examples.md` with canonical examples for each skill's output format.
2. Standardize a confirmation gate pattern across all skills with `disable-model-invocation: true`.
3. Add explicit Bash command allowlists/denylists to skills that mix read-only analysis with write access.

## Delta from Prior Review (2026-03-24T134500)

| Item | Dimension | Previous | Current | Change |
|------|-----------|----------|---------|--------|
| analyze-node-hardware | Overall | B (88.5) | A (91.5) | +1 grade |
| analyze-node-hardware | Completeness | B | A | +1 grade |
| analyze-node-hardware | Prompt Engineering | B | A | +1 grade |
| analyze-node-hardware | Safety | B | A | +1 grade |
| analyze-node-hardware | Metadata | B | A | +1 grade |
| cilium-policy-debug | Overall | C (75.25) | B (86.5) | +1 grade |
| cilium-policy-debug | Clarity | B | A | +1 grade |
| cilium-policy-debug | Completeness | C | B | +1 grade |
| cilium-policy-debug | Prompt Engineering | F | B | +3 grades |
| cilium-policy-debug | Context Engineering | C | B | +1 grade |
| cilium-policy-debug | Goal Alignment | B | A | +1 grade |
| cilium-policy-debug | Safety | C | B | +1 grade |
| optimize-node-kernel | Overall | B (89.5) | A (92.75) | +1 grade |
| optimize-node-kernel | Prompt Engineering | B | A | +1 grade |
| optimize-node-kernel | Safety | B | A | +1 grade |
| optimize-node-kernel | Metadata | C | A | +2 grades |
| update-schematics | Overall | A (93.0) | A (90.5) | same grade, -2.5 pts |
| update-schematics | Completeness | A | B | -1 grade |
| update-schematics | Context Engineering | A | B | -1 grade |
| execute-talos-upgrade | Overall | A (92.0) | A (93.5) | same grade, +1.5 pts |
| execute-talos-upgrade | Context Engineering | B | A | +1 grade |
| gitops-health-triage | Overall | B (84.0) | A (90.35) | +1 grade |
| gitops-health-triage | Clarity | B | A | +1 grade |
| gitops-health-triage | Completeness | C | B | +1 grade |
| gitops-health-triage | Prompt Engineering | C | A | +2 grades |
| gitops-health-triage | Goal Alignment | B | A | +1 grade |
| plan-cilium-upgrade | Overall | A (92.0) | A (93.25) | same grade, +1.25 pts |
| plan-cilium-upgrade | Prompt Engineering | B | A | +1 grade |
| plan-cilium-upgrade | Context Engineering | B | A | +1 grade |
| plan-talos-upgrade | Overall | A (92.0) | A (93.5) | same grade, +1.5 pts |
| plan-talos-upgrade | Prompt Engineering | B | A | +1 grade |
| plan-talos-upgrade | Context Engineering | B | A | +1 grade |
| talos-node-maintenance | Overall | B (81.0) | B (86.5) | same grade, +5.5 pts |
| talos-node-maintenance | Completeness | C | B | +1 grade |
| talos-node-maintenance | Prompt Engineering | C | B | +1 grade |
| talos-node-maintenance | Safety | C | B | +1 grade |
| talos-sre | Overall | C (74.0) | A (92.0) | +2 grades |
| talos-sre | Clarity | C | A | +2 grades |
| talos-sre | Completeness | D | A | +3 grades |
| talos-sre | Prompt Engineering | D | A | +3 grades |
| talos-sre | Context Engineering | C | A | +2 grades |
| talos-sre | Goal Alignment | C | A | +2 grades |
| talos-sre | Safety | B | B | same |
| talos-sre | Metadata | B | A | +1 grade |
| gitops-operator | Overall | C (74.5) | A (90.35) | +2 grades |
| gitops-operator | Clarity | C | A | +2 grades |
| gitops-operator | Completeness | D | B | +2 grades |
| gitops-operator | Prompt Engineering | D | A | +3 grades |
| gitops-operator | Context Engineering | C | B | +1 grade |
| gitops-operator | Goal Alignment | B | A | +1 grade |
| gitops-operator | Safety | C | A | +2 grades |
| gitops-operator | Metadata | B | A | +1 grade |
| platform-reliability-reviewer | Overall | C (75.0) | B (89.75) | +1 grade |
| platform-reliability-reviewer | Clarity | C | A | +2 grades |
| platform-reliability-reviewer | Completeness | C | B | +1 grade |
| platform-reliability-reviewer | Prompt Engineering | C | B | +1 grade |
| platform-reliability-reviewer | Context Engineering | C | A | +2 grades |
| platform-reliability-reviewer | Goal Alignment | B | A | +1 grade |
| platform-reliability-reviewer | Safety | D | A | +3 grades |
