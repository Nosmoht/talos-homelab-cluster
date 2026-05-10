# Agent Harness Audit Prompt

Reusable prompt for auditing a Claude Code agent harness (`.claude/agents/`, `.claude/skills/`,
`.claude/rules/`, hooks, `CLAUDE.md`) in any repository and producing a prioritized improvement
roadmap. Paste this as the first message in a new Claude Code session in the target repo.

---

## Prompt (copy everything below this line)

---

Perform a comprehensive audit of this repository's Claude Code agent harness and produce a
prioritized roadmap of improvements. The harness consists of `.claude/agents/`, `.claude/skills/`,
`.claude/rules/`, `.claude/hooks/`, and `CLAUDE.md` / `AGENTS.md`.

## Phase 1 — Inventory

Read and record the current state:

1. `CLAUDE.md` and `AGENTS.md` (if present) — project instructions, rule/skill/agent table, hook table
2. `ls .claude/rules/*.md` — list all rules with their frontmatter (`paths:` scope, presence/absence)
3. `ls .claude/agents/*.md` — list all agents with their frontmatter (`model:`, `description:`, `allowed-tools:`)
4. `ls .claude/skills/*/SKILL.md` — list all skills with their frontmatter (`disable-model-invocation:`, `allowed-tools:`)
5. `ls .claude/hooks/` and read each hook script (first 10 lines) — note trigger event and what it enforces
6. `.claude/settings.local.json` or `.claude/settings.json` — note configured hooks and any tool overrides
7. Check for stray files: files in `.claude/` root that are not part of the defined structure, duplicate settings files in repo root, empty skill stubs (directories without `SKILL.md`)

For each agent: record name, model, description, allowed-tools.
For each skill: record name, disable-model-invocation, allowed-tools.
For each rule: record name, paths: frontmatter (present/absent, glob pattern), line count.

## Phase 2 — Defect Scan

Evaluate the inventory against five defect categories. For each finding, record: file, line (if known), severity (BLOCKING / WARNING / INFO), and a concrete fix.

### Category A — Silent Failures (highest risk, invisible breakage)

**A1. Rules without frontmatter or without `paths:` key**
A rule file without a `paths:` frontmatter block is never auto-loaded by Claude Code — it exists
on disk but never activates. Check: `head -5 .claude/rules/*.md | grep -l '^---'` (absence = silent failure).

**A2. Subagent scope shadowing in skills that spawn agents**
When a skill spawns a subagent via the Agent tool, the subagent cannot see the parent skill's
`references/*.md` files — the directory scope is not inherited. Any skill that (a) has a
`references/` subdirectory AND (b) spawns an Agent that is expected to use those references has
a silent context gap. Fix: inline the load-bearing constraints as a block in the spawn prompt, or
pass an absolute file path with an explicit Read instruction.

**A3. Broken cross-references**
Skills, agents, and rules that reference other files by path (e.g., "See `.claude/rules/foo.md`").
Verify each referenced path exists: `git ls-files | xargs grep -l 'rules/.*\.md' | xargs grep -oh '\.claude/rules/[^ )]*\.md'` (adjust pattern). Every broken reference is a silent context gap.

**A4. `allowed-tools` listing tools not available in this context**
If a skill lists an MCP tool (e.g., `mcp__talos__talos_get`) that is not configured in `.mcp.json`,
the tool silently fails at invocation time. Cross-check each `mcp__*` entry in `allowed-tools`
against the server names in `.mcp.json`.

### Category B — Prompt Ergonomics (performance degradation)

**B1. MUST/CRITICAL/ALWAYS/NEVER overuse in skills and agents**
Claude 4.6 research (PRISM study) shows that overuse of imperative emphasis words causes
"literal-following mode" — up to 26% reasoning degradation. These words should be reserved for:
(a) instructions backed by a hook that actually enforces them, (b) references to documented hard
constraints, or (c) genuine security invariants (secrets, auth). Count occurrences in each
`.claude/skills/**` and `.claude/agents/**` file. Flag any where >3 occur and none map to an
enforcing hook.

**B2. Vague or over-broad agent descriptions**
Claude Code uses the `description:` field for auto-dispatch matching. Descriptions containing
authority claims ("senior operator", "expert in") or stacked topic lists cause over-triggering.
Best practice: active voice, concrete trigger condition, ≤20 words. Flag any description that (a)
exceeds 20 words, (b) contains "senior/expert/best", or (c) lists more than two distinct use cases.

**B3. Over-broad `paths:` scopes in rules**
A rule with `paths: [".claude/**"]` fires on every edit inside `.claude/` — including hooks,
settings, memory files — and loads its full content each time. IFScale research shows measurable
performance degradation past ~150 loaded instructions. Scope rules to the files that actually
benefit from them. Flag rules where the glob matches file types the rule content does not address.

**B4. Token-heavy rules loaded unnecessarily**
Rules >100 lines loaded on frequently-edited paths burn context budget on every tool call. Check
if the rule's content justifies its load frequency: a 160-line policy loaded on `.claude/**`
fires many more times than a 160-line policy loaded on `kubernetes/**`. Flag mismatches.

### Category C — Structural Duplication (maintenance burden)

**C1. Rule pairs with thematic overlap**
Read each pair of rules that share topic keywords in their filename or H1 heading. Identify whether
their `paths:` scopes overlap. If two rules both load on the same file edit and address the same
topic, one of these is true: (a) they should be merged, (b) one should be scoped tighter, or (c)
they address different aspects and the split is intentional. Document which case applies.

**C2. Agent/skill duplication**
If two agents or two skills have descriptions that could match the same user intent, one is a
candidate for removal or scope-narrowing. Flag pairs with >50% semantic overlap in description.

**C3. Outdated references in non-frozen files**
After renames or merges, stale references accumulate. Run:
`git ls-files | xargs grep -l '<old-name>' 2>/dev/null | grep -v '^\.claude/reviews/'`
for any known renamed files. Flag each hit outside frozen audit history.

### Category D — Operational Gaps (missing runbooks)

**D1. Operations mentioned in docs/postmortems without a skill**
Read `docs/` for postmortem files, incident reports, and `day2-operations.md`. For each procedure
described as "manual steps", "run this sequence", or "next time do X" — check if a corresponding
skill exists. A postmortem that ends with "we should automate this" but has no skill is a gap.

**D2. Operations mentioned in AGENTS.md/CLAUDE.md without a skill**
Read §Operational Runbooks table. For each operation referenced in prose (e.g., "rotate before
expiration", "restore from snapshot", "unstick stuck sync") — verify a skill covers it. Cross-check
the narrative text of §Hard Constraints and §Operational Patterns for undocumented runbooks.

**D3. Skills that reference non-existent reference files**
For each skill with a `references/` subdirectory listed in its SKILL.md: verify the files exist.
A reference to a file that doesn't exist is a documentation gap; a reference to a file that used
to exist but was renamed is a broken pointer (see A3).

### Category E — Hygiene (low risk, low effort)

**E1. Stale count claims in CLAUDE.md / AGENTS.md**
`grep -E '[0-9]+ (rules|skills|agents)' CLAUDE.md AGENTS.md` — verify each claim against
`ls .claude/rules/*.md | wc -l`, `ls .claude/skills/*/SKILL.md | wc -l`,
`ls .claude/agents/*.md | wc -l`.

**E2. Duplicate or misplaced config files**
Check for `.claude_settings.json` in repo root alongside `.claude/settings.local.json` — both
define hook config, only one is canonical. Also check for `.claude/settings.json` vs
`.claude/settings.local.json` ambiguity.

**E3. Empty skill stubs**
`find .claude/skills -maxdepth 1 -mindepth 1 -type d | while read d; do test -f "$d/SKILL.md" || echo "EMPTY: $d"; done`
Empty directories confuse tool discovery. Either delete or add a minimal stub with
`disable-model-invocation: true` and a TODO description.

**E4. Agent/skill body vs. CLAUDE.md/AGENTS.md description drift**
For each agent in the auto-dispatch table in CLAUDE.md/AGENTS.md, compare the documented
"use for" description against the actual `description:` field in the agent file. Drift here causes
users to expect behavior the agent doesn't have.

**E5. Tool-Least-Privilege violations**
For each agent, check if `allowed-tools` includes `Edit` or `Write` but the agent's described
behavior is read-only (diagnosis, proposal, diff). Read-only agents with write tools are a latent
risk: they can mutate files when instructed, even if not intended. Flag cases where agent prose
says "proposes" or "diagnoses" but tools include `Edit`/`Write`.

## Phase 3 — Prioritize

Score each finding by: **Impact** (BLOCKING > WARNING > INFO) × **Effort** (Low/Medium/High).

Recommended phase order:
- **Phase 0 (Prerequisite):** All Category E hygiene items — tiny diffs, clean baseline
- **Phase 1 (Highest value):** All Category A silent failures + Category B ergonomics — these have
  the largest quality multiplier on all subsequent work
- **Phase 2 (Structure):** Category C duplication — reduces maintenance burden going forward
- **Phase 3 (Gaps):** Category D new skills — adds value but requires the most authoring work

Within each phase, sequence items so that prerequisite changes (renames, deletes) come before
changes that reference the new names.

## Phase 4 — Produce the Roadmap Plan

Output a plan in this structure for each phase:

```
## Phase N — <Title> (Scope <Letter>)

### <ID>. <Item title>

**Finding:** <what is wrong and where>
**Affected Files:** <list with line numbers where known>
**Fix:** <concrete diff description or new file content outline>
**Acceptance:** <verifiable shell command or observable state>
```

Then append a **PR Sequence** table:

| PR | Title | Items | Estimated scope |
|----|-------|-------|-----------------|
| 1  | ...   | A–Z   | <N files>       |

Use Conventional Commits format for PR titles: `type(scope): message`.

## Phase 5 — Reviewer Pass

Before presenting the plan, spawn `platform-reliability-reviewer` with prefix `pre-operation:` and
the full plan text. Ask it to check:
1. Are all cross-references in the rename sweep complete? (no stale refs in non-frozen files)
2. Are any BLOCKING safety invariants affected? (SOPS chain, CI checks, hook enforcement)
3. Are any acceptance criteria unverifiable (missing shell command, untestable claim)?
4. Is there a count-oscillation risk if rule counts change across multiple PRs?

Integrate all findings from the reviewer into the plan before presenting it to the user.

## Output Format

Present the final plan as a Markdown document. Save it to `Plans/<random-adjective-noun>.md`
(same naming convention as other plans in this repo). Then summarize findings in one table:

| Category | Count | Highest Severity | Top Finding |
|----------|-------|-----------------|-------------|
| A Silent Failures | N | BLOCKING/WARNING/INFO | ... |
| B Prompt Ergonomics | N | ... | ... |
| C Structural Duplication | N | ... | ... |
| D Operational Gaps | N | ... | ... |
| E Hygiene | N | ... | ... |

End with: "Plan saved to `Plans/<name>.md`. Ready to begin Phase 0?"
