# Talos Homelab — Claude Code Memory

@AGENTS.md

## Claude-Code-Specific Additions

### Path-Scoped Auto-Loaded Rules

Claude Code auto-loads `.claude/rules/*.md` via `paths:` frontmatter when editing matching files.
All 19 rules activate without a manual Read step. Codex CLI has no equivalent mechanism —
see AGENTS.md §Domain Rules for the on-demand reference table.

### Hooks (PreToolUse / PostToolUse enforcement)

Hooks are shipped by the `devobagmbh/kube-agent-harness` plugin family — see AGENTS.md §"Tool-Agnostic Safety Invariants" for the active matcher list and §"MCP Server Configuration" for the marketplace install. The legacy `.claude/hooks/*.sh` files remain in this repo as Codex CLI fallback (Codex has no plugin runtime); they are inert under Claude Code as long as `.claude/settings.local.json` carries no `"hooks"` registrations.

Tool-agnostic SOPS enforcement is additionally enforced via pre-commit framework —
see AGENTS.md §Tool-Agnostic Safety Invariants.

### Subagents

Claude Code agent surface:

- `.claude/agents/talos-sre.md` — Talos/hardware operations perspective (homelab-bound; only repo-local agent).
- Plugin-shipped (via `devobagmbh/kube-agent-harness`): `builder-evaluator`, `builder-implementer`, `platform-reliability-reviewer`, `researcher` (core), `gitops-operator` (gitops-argocd provider).

The builder-implementer and builder-evaluator subagents enforce Anthropic Principle 1 ("separate the judge from the builder") via mechanical context-window isolation per [Tier-1 Claude Code docs](https://code.claude.com/docs/en/sub-agents). See `docs/issue-workflow.md` for the full lifecycle and `/implement-issue` Skill phase mapping.

**Session-restart caveat**: Claude Code scans agent sources at session start only. Newly-added subagent definitions (`.claude/agents/` or plugin sources) are NOT registered mid-session (or post-`/compact`). After adding or renaming a subagent, restart Claude Code in the repo cwd. See `docs/issue-workflow.md` §Discovery / session-restart caveat.

Under Codex CLI: no auto-dispatch and no plugin runtime — only `talos-sre` is reachable, via explicit invocation. See AGENTS.md §Deltas vs Claude Code.

### Context Architecture

- 25 cluster-local skills in `.claude/skills/` — plus 6 plugin-shipped skills under `/kube-agent-harness*:*` namespaces. See AGENTS.md §Operational Runbooks for both tables.
- Rules auto-load via `paths:` frontmatter (Claude-specific; Codex uses §Domain Rules table in AGENTS.md)
- ExitPlanMode gated by plugin-shipped `require-plan-review.sh` hook
- Plugin contract: `.claude/harness.yaml` declares `gitops: argocd`, `csi: linstor`. Drift-guarded by `make harness-check`.
- After incidents: update AGENTS.md §Hard Constraints if the lesson is universal; write postmortem to `docs/`
- This file kept minimal — all shared operational knowledge lives in AGENTS.md
