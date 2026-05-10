#!/bin/bash
set -u
# Block ExitPlanMode for infrastructure plans that lack review evidence.
# Only fires when the plan touches kubernetes/, talos/, bootstrap/, or .claude/hooks/ paths.
# Follows the same pattern as validate-gitops.sh (PreToolUse, exit 2 to block).
# Limitation: uses ls -t to find the active plan — if a stale plan has a newer mtime,
# the hook evaluates the wrong file. No env var for the active plan path is available.

# ExitPlanMode has no meaningful tool_input — read and discard stdin
cat > /dev/null

PLAN_DIR="$CLAUDE_PROJECT_DIR/Plans"
[ -d "$PLAN_DIR" ] || exit 0

# Find the most recently modified plan file
PLAN_FILE=$(ls -t "$PLAN_DIR"/*.md 2>/dev/null | head -1)
[ -z "$PLAN_FILE" ] && exit 0
[ ! -f "$PLAN_FILE" ] && exit 0

# Check if plan references infrastructure paths
if ! grep -qE 'kubernetes/|talos/|bootstrap/|\.claude/hooks/' "$PLAN_FILE"; then
  exit 0  # Not an infrastructure plan — no review required
fi

# Infrastructure plan detected — check for review evidence
# Require BOTH: (1) a reviewer agent name AND (2) an assessment/verdict pattern.
# Agent name alone could be a TODO placeholder; verdict alone could be self-assessed.
HAS_AGENT=0
HAS_ASSESSMENT=0

if grep -qiE 'platform-reliability-reviewer|talos-sre|gitops-operator' "$PLAN_FILE"; then
  HAS_AGENT=1
fi

if grep -qE 'Verdict:|Risk Assessment|## Review' "$PLAN_FILE"; then
  HAS_ASSESSMENT=1
fi

if [ "$HAS_AGENT" -eq 1 ] && [ "$HAS_ASSESSMENT" -eq 1 ]; then
  exit 0  # Review evidence found
fi

# Build specific feedback about what's missing
MISSING=""
[ "$HAS_AGENT" -eq 0 ] && MISSING="reviewer agent reference"
[ "$HAS_ASSESSMENT" -eq 0 ] && MISSING="${MISSING:+$MISSING + }assessment verdict"

echo "Plan review required: $(basename "$PLAN_FILE") modifies infrastructure but lacks review evidence." >&2
echo "Run platform-reliability-reviewer, talos-sre, or gitops-operator to review, then add findings to the plan." >&2
echo "Missing: $MISSING" >&2
exit 2
