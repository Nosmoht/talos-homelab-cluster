# Issue Workflow

Canonical reference for the GitHub Issue lifecycle in this repo, including the
agentic state-machine and the scripts/subagents that enforce transitions.

> **Audience**: agent operators (Claude Code, Codex CLI), human triagers, and
> the `/implement-issue` Skill itself. AGENTS.md §Session-Start-Ritual links
> here for the lifecycle reference.

## Lifecycle states

```
                                                       ┌────────────┐
                                                       │   closed   │
                                                       └─────▲──────┘
                                                             │
              (no status)                                    │ close <N> --pr
                  │                                          │
                  ▼ (triager)                                │
            ┌────────────┐                          ┌────────┴──────┐
            │status:triage│                          │status:        │
            └─────┬──────┘                          │needs-review   │
                  │                                  └────────▲──────┘
                  ▼ (triage done)                             │
            ┌────────────┐                                    │ handoff
            │status:ready│                                    │
            └─────┬──────┘                                    │
                  │                                  ┌────────┴──────┐
                  ▼ claim                            │status:        │
            ┌────────────┐                            │in-progress   │◄──┐
            │status:     │ ────── handoff ──────────►└────────┬──────┘   │
            │in-progress │                                    │           │ release
            └─────┬──────┘                                    │           │
                  │                                           ▼           │
                  ▼ block                                ┌─────────┐      │
            ┌────────────┐    ◄── (any state) ──────── │ failure │ ─────┘
            │status:     │                              └─────────┘
            │ blocked    │
            └────────────┘
```

## State semantics

| State (label) | Who sets | Authorization | Next states |
|---|---|---|---|
| (no label) | author | proposal/draft — not authorized for work | `status: triage` (triager) |
| `status: triage` | triager | being assessed | `status: ready` or close-as-not-planned |
| `status: ready` | triager (after spec complete + risk assigned) | **authorizes** agent or human pickup | `status: in-progress` (claim), `status: blocked` |
| `status: in-progress` | builder (via `claim`) | active work — assignee identifies session | `status: needs-review` (handoff), `status: ready` (release), `status: blocked` |
| `status: needs-review` | builder (via `handoff`) | implementation done, awaiting evaluator + human | closed (via `close --pr`), `status: blocked` |
| `status: blocked` | any actor (via `block "<reason>"`) | preserves full context for human untangling | `status: ready` (after human resolution) |

**Status-Gate principle** (AGENTS.md §Session-Start-Ritual): only issues with
`status: ready` are authorized for agent pickup. Anything else requires explicit
user authorization.

## Risk classification

Set during triage **alongside** `status: ready`. Drives selective human gating
once Layer 3 of #139 is implemented (deferred for v1):

| Risk label | Examples | Gating (v2 target) |
|---|---|---|
| `risk: low` | reversible, narrow scope, portable refactor | claim/close fast-path; no SPEC-approval gate |
| `risk: medium` | touches multiple subsystems OR has rollback cost | SPEC-approval gate before `status: ready` |
| `risk: high` | infra-mutating, secret-touching, production-impacting | SPEC-approval + secondary signature (`talos-sre` for Talos, `platform-reliability-reviewer` for cluster-wide) |

For v1: risk labels are advisory and informational; gating is human discretion.

## Issue specification format

Issues authored for agent pickup follow the spec format documented in the
`/implement-issue` Skill description and AGENTS.md. Required sections (per
research-validated empirical findings on 2,500+ agent config files,
[Addy Osmani 2026](https://addyosmani.com/blog/good-spec/)):

1. **Intent** — one-sentence goal
2. **Context** — why now, what surfaced this, references
3. **Acceptance Criteria** — machine-checkable predicates (file exists,
   command exits 0, grep returns N matches), not free-form prose
4. **Non-Goals** — explicit out-of-scope to prevent scope drift
5. **Boundaries** — three-tier system (✅ Always do / ⚠️ Ask first / 🚫 Never)
6. **Verification** — concrete commands proving acceptance
7. **Dependencies** — `blocks-on:` and `references:` cross-issue links

Bad-spec failure pattern (most common, per research): vague specs cause
wandering agents. The Evaluator subagent will return CRITICAL findings if
acceptance criteria are not machine-checkable predicates.

## Scripts: state transition operations

`scripts/issue-state.sh` is a single bash script with subcommands. Storage-
backend agnostic at the interface (uses `gh` CLI today; swap to Plane/Linear
by re-implementing subcommand internals only).

```
scripts/issue-state.sh claim    <N>
scripts/issue-state.sh handoff  <N>
scripts/issue-state.sh release  <N>
scripts/issue-state.sh block    <N> "<reason>"
scripts/issue-state.sh close    <N> --pr <PR-ref>
```

Common flags: `--dry-run` (print without execute), `--repo OWNER/REPO`
(override auto-detect).

Exit codes: `0` success · `1` precondition not met · `2` gh/API error · `3`
invalid arguments.

**Race semantics**: `claim` reads-then-writes in a small window. Single-
agent ops are race-free in practice; concurrent autonomous loops have a
sub-second window where two claimants could both pass the read check.
Mitigation: post-write verification — if final assignee count >1, the
script rolls back its own claim and exits non-zero. True
exclusive-claim-as-primitive is future work (would require GitHub GraphQL
mutation with optimistic locking, which has no `gh` CLI surface today).

## Subagents: agent-isolated phases

Two subagent definitions in `.claude/agents/` enforce Anthropic Principle 1
("separate the judge from the builder") via mechanically-isolated context
windows. Per [Tier-1 Claude Code Docs](https://code.claude.com/docs/en/sub-agents):
"Each subagent runs in its own context window with a custom system prompt,
specific tool access, and independent permissions."

### `builder-implementer`

- **Role**: executes an approved plan; never reviews own work
- **Context**: isolated; sees only the prompt the Orchestrator passes plus
  the working directory
- **Tools**: Read, Edit, Write, Bash, Grep, Glob, Skill (no Agent — prevents
  recursive subagent spawning)
- **Input**: `.work/issue-<N>/plan.md` + issue body + relevant rules
- **Output**: `.work/issue-<N>/implementation-summary.md` + commit SHA
- **HALT conditions**: scope drift, ambiguous criterion, missing prerequisite,
  Hard Constraint trigger

### `builder-evaluator`

- **Role**: verifies implementation against acceptance criteria; never modifies
  code (structural — no Edit/Write/Skill in toolset)
- **Context**: isolated; sees only the implementation summary, the diff, and
  reference rules — never the Orchestrator's plan reasoning
- **Tools**: Read, Grep, Glob, Bash (read-only)
- **Input**: `.work/issue-<N>/implementation-summary.md` + `gh pr diff` +
  AGENTS.md §Hard Constraints
- **Output**: `.work/issue-<N>/evaluator-findings.md` + JSON verdict
- **Severity**: CRITICAL (predicate refuted or Hard Constraint violated) /
  WARNING (concern, no block) / INFO (observation)
- **PASS rule**: zero CRITICAL findings AND zero unaddressed criteria AND zero
  Hard Constraint violations. Anything else: FAIL.

### Discovery / session-restart caveat

Claude Code scans `.claude/agents/` **at session start only**. Adding a new
subagent definition mid-session (or post-`/compact`) does NOT register it with
the Agent dispatcher; calls fail with `Agent type '<name>' not found`. To pick
up a newly-added or renamed subagent, **start a fresh Claude Code session** in
the repo cwd. This applies to `builder-implementer`, `builder-evaluator`, and
any future subagent additions. (Same root cause as the cache-breaking actions
in `~/workspace/claude-config/rules/session-optimization.md`.)

Validated empirically on 2026-04-26: builder-* files were created mid-session;
after `/compact` they remained absent from the available-agents list while
pre-existing subagents (`gitops-operator`, `platform-reliability-reviewer`,
etc.) continued to dispatch normally. Frontmatter was identical-shape — the
issue is harness state, not file content.

Codex CLI is unaffected (no auto-discovery; subagents are invoked explicitly).

## /implement-issue phase mapping

The `/implement-issue` Skill (in `~/workspace/claude-config/skills/implement-issue/`)
orchestrates the full lifecycle. The phase-to-script-and-subagent mapping:

| Phase | Action | State transition | Notes |
|---|---|---|---|
| 1: Research | inline (deconstruct skill) | — | Orchestrator gathers context |
| 2: Plan | inline (plan mode) | — | Plan written to `.work/issue-<N>/plan.md` |
| 3: Plan-Review | spawn 2 subagents in parallel (team-red + reviewer) | — | Plan approved before Phase 4 |
| **4: Implement** | **claim** + spawn `builder-implementer` | `ready → in-progress` | Builder isolated |
| 5: Test/Lint | builder-implementer continues in same turn budget | — | Tests run within builder context |
| 6: Commit | `Skill("commit")` (within builder) | — | Conventional commit |
| 7: Push-verify | inline | — | `git log @{u}..` empty + `gh run view` green |
| **7.5: Eval** | **handoff** + spawn `builder-evaluator` | `in-progress → needs-review` | Evaluator isolated, FAIL → block |
| **8: Close** | **close --pr `<ref>`** | `needs-review → closed` | Only if Phase 7.5 PASS |
| (any failure) | **block** with reason + last-error context | `* → blocked` | Never silent abandonment |

**This phase mapping is the contract for the claude-config Skill edit (Phase B
of #139)**. The Skill repo edit is out-of-tree; the contract lives here so
both Claude Code and Codex CLI users can implement compatible orchestrators.

## .work/ artifact paths

Per Anthropic Principle 3 ("communicate via files, not shared context"),
agent-to-agent communication uses files at standard paths:

| Artifact | Writer | Reader | Persistence |
|---|---|---|---|
| `.work/issue-<N>/plan.md` | Orchestrator (Phase 2) | builder-implementer | session-local |
| `.work/issue-<N>/implementation-summary.md` | builder-implementer | builder-evaluator + Orchestrator | session-local |
| `.work/issue-<N>/evaluator-findings.md` | builder-evaluator | Orchestrator + human | session-local |
| GitHub Issue comments (via `block`/`close`) | scripts/issue-state.sh | human + future agents | persistent / audit trail |

`.work/` is gitignored (or untracked-by-default in this repo). For
cross-session audit, GitHub issue comments are authoritative.

## Codex CLI compatibility

| Capability | Claude Code | Codex CLI |
|---|---|---|
| `.claude/agents/*.md` auto-discovery | ✅ | ❌ (Codex reads `.codex/agents/*.toml`) |
| Subagent auto-routing by description | ✅ | ❌ (explicit `spawn_agents_on_csv` only) |
| `scripts/issue-state.sh` invocation | ✅ via Bash | ✅ via shell |
| `/implement-issue` skill | ✅ (claude-config) | ❌ (no equivalent skill) |
| AGENTS.md as canonical context | ✅ | ✅ (cross-tool standard) |

**Codex fallback path** for issue work:
1. Codex user reads issue manually + drafts plan
2. Codex user runs `bash scripts/issue-state.sh claim <N>` directly
3. Codex implements inline (single-context, no Builder/Evaluator separation —
   reduced Anthropic-Principle-1 guarantee, logged as a warning)
4. Codex user runs `bash scripts/issue-state.sh handoff <N>` after push
5. Codex user manually inspects PR before `bash scripts/issue-state.sh close <N> --pr <ref>`

Optional future work: mirror `.claude/agents/*.md` to `.codex/agents/*.toml`
so Codex can spawn the same Builder/Evaluator subagents (different format,
same contract). Tracked separately from #139.

## See also

- AGENTS.md §Session-Start-Ritual — status-gate principle
- AGENTS.md §Subagents — auto-dispatch table including builder-implementer
  and builder-evaluator
- AGENTS.md §Hard Constraints — never-violate boundary that the Evaluator
  enforces
- KB synthesis memo `95fc8846-4dae-4cb7-846e-34250cded2bd` — research basis
- Issue #139 — workflow design + implementation tracking
