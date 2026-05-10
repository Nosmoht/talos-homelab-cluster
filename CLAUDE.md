# Talos Homelab — Claude Code Memory

@AGENTS.md

## Claude-Code-Specific Additions

### Path-Scoped Auto-Loaded Rules

Claude Code auto-loads `.claude/rules/*.md` via `paths:` frontmatter when editing matching files.
All 13 rules activate without a manual Read step. Codex CLI has no equivalent mechanism —
see AGENTS.md §Domain Rules for the on-demand reference table.

### Hooks (PreToolUse / PostToolUse enforcement)

Configured in `.claude/settings.local.json`. Active only under Claude Code:

| Hook | Trigger | Effect |
|---|---|---|
| `check-sops.sh` | PreToolUse Write\|Edit | Blocks plaintext write to `*.sops.yaml` |
| `check-sops-bash.sh` | PreToolUse Bash | Blocks redirect/heredoc to `*.sops.yaml` |
| `validate-gitops.sh` | PreToolUse Bash `git commit*` | Runs kustomize + dry-run |
| `pre-drain-check.sh` | PreToolUse Bash `kubectl drain*` | DRBD safety pre-check |
| `pre-push-verify.sh` | PreToolUse Bash `git push*` | Infrastructure push safety |
| `require-plan-review.sh` | PreToolUse ExitPlanMode | Plan approval gate |
| `require-probe-evidence.sh` | PostToolUse Write\|Edit | Evidence probe check |

Tool-agnostic SOPS enforcement is additionally enforced via pre-commit framework —
see AGENTS.md §Tool-Agnostic Safety Invariants.

### Subagents

`.claude/agents/` — auto-dispatched via description matching:

- `gitops-operator` — ArgoCD operations and troubleshooting
- `talos-sre` — Talos/hardware operations perspective
- `platform-reliability-reviewer` — adversarial risk assessment (prefix: `pre-operation:` or `pre-merge:`)
- `researcher` — upstream research, CVE intelligence, version compatibility
- `builder-implementer` — executes approved /implement-issue plan in isolated context (Phase 4); writes `.work/issue-<N>/implementation-summary.md`
- `builder-evaluator` — verifies implementation against acceptance criteria in isolated context (Phase 7.5); read-only by tool restriction; writes `.work/issue-<N>/evaluator-findings.md`

The builder-implementer and builder-evaluator subagents enforce Anthropic Principle 1 ("separate the judge from the builder") via mechanical context-window isolation per [Tier-1 Claude Code docs](https://code.claude.com/docs/en/sub-agents). See `docs/issue-workflow.md` for the full lifecycle and `/implement-issue` Skill phase mapping.

**Session-restart caveat**: Claude Code scans `.claude/agents/` at session start only. Newly-added subagent definitions are NOT registered mid-session (or post-`/compact`). After adding or renaming a subagent file, start a fresh Claude Code session in the repo cwd. See `docs/issue-workflow.md` §Discovery / session-restart caveat.

Under Codex CLI: no auto-dispatch — explicit invocation only. See AGENTS.md §Deltas vs Claude Code.

### Context Architecture

- 19 skills in `.claude/skills/` — dispatch via `/skill-name` or intent matching
- Rules auto-load via `paths:` frontmatter (Claude-specific; Codex uses §Domain Rules table in AGENTS.md)
- Scheduled MCP checks: `talos-update-check`, `nvidia-extension-check`, `cilium-update-check` (weekly)
- ExitPlanMode gated by `require-plan-review.sh` hook
- After incidents: update AGENTS.md §Hard Constraints if the lesson is universal; write postmortem to `docs/`
- This file kept minimal — all shared operational knowledge lives in AGENTS.md
