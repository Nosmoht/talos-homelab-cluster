# Claude Code Stack Audit (Homelab)

Date: 2026-03-03

## Existing State Before Changes

- `CLAUDE.md`: strong cluster-specific constraints and operational gotchas.
- Rules existed for Talos config, node config, image factory, GitOps pattern, and Cilium Gateway API.
- Skills existed for hardware analysis, kernel optimization, and schematic updates.
- No repository-level agent profiles existed.
- No repository `.mcp.json` existed.

## Gaps Identified

1. Missing day-to-day operational skills for:
   - ArgoCD drift triage
   - Talos maintenance runbooks
   - Cilium policy debugging
2. Existing Talos skills referenced incorrect file paths (missing `talos/` prefixes).
3. No role-specialized agents for delegation workflows.
4. No project MCP server configuration for GitHub/Kubernetes workflows.
5. No rule focused on manifest quality and day-2 Talos/Argo operations.

## Implemented Improvements

- Fixed path correctness in existing skills:
  - `.claude/skills/analyze-node-hardware/SKILL.md`
  - `.claude/skills/optimize-node-kernel/SKILL.md`
  - `.claude/skills/update-schematics/SKILL.md`
- Added new rules:
  - `.claude/rules/argocd-operations.md`
  - `.claude/rules/manifest-quality.md`
  - `.claude/rules/talos-operations.md`
- Added new skills:
  - `.claude/skills/gitops-health-triage/SKILL.md`
  - `.claude/skills/talos-node-maintenance/SKILL.md` *(deprecated — superseded by `talos-apply` + `talos-upgrade`)*
  - `.claude/skills/talos-apply/SKILL.md`
  - `.claude/skills/talos-upgrade/SKILL.md`
  - `.claude/skills/cilium-policy-debug/SKILL.md`
- Added new agents:
  - `.claude/agents/gitops-operator.md`
  - `.claude/agents/talos-sre.md`
  - `.claude/agents/platform-reliability-reviewer.md`
- Added MCP configuration and setup notes:
  - `.mcp.json`
  - `.claude/mcp/SETUP.md`

## Result

The repository now has a complete Claude Code baseline for daily DevOps, Kubernetes, and Talos work, with clear specialization across rules, skills, agents, and MCP integration.
