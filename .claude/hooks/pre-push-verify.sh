#!/bin/bash
set -u
# Print verification checklist before pushing infrastructure changes.
# Advisory only (exit 0) — serves as a self-reminder for post-push verification.
# Follows the same pattern as validate-gitops.sh (PreToolUse, stdin JSON parsing).
INPUT=$(cat)
COMMAND=$(jq -r '.tool_input.command // empty' <<< "$INPUT" 2>/dev/null)
[ -z "$COMMAND" ] && exit 0

if [[ "$COMMAND" =~ git[[:space:]]push ]]; then
  cd "$CLAUDE_PROJECT_DIR" || exit 0

  # Determine upstream ref, fall back to origin/main
  UPSTREAM=$(git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null)
  [ -z "$UPSTREAM" ] && UPSTREAM="origin/main"

  # Check if infrastructure files are in the push diff
  INFRA_FILES=$(git diff --name-only "$UPSTREAM"..HEAD -- kubernetes/ talos/ 2>/dev/null)
  [ -z "$INFRA_FILES" ] && exit 0

  FILE_COUNT=$(echo "$INFRA_FILES" | wc -l | tr -d ' ')
  PREVIEW=$(echo "$INFRA_FILES" | head -10)

  echo "Infrastructure push: $FILE_COUNT file(s) changed. Post-push verification checklist:" >&2
  echo "$PREVIEW" | sed 's/^/  /' >&2
  [ "$FILE_COUNT" -gt 10 ] && echo "  ... and $((FILE_COUNT - 10)) more" >&2
  echo "  [ ] ArgoCD sync+health: kubectl get applications -A -o wide | grep -vE 'Synced.*Healthy'" >&2
  echo "  [ ] Pod health:  kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded" >&2
  echo "  [ ] Events:      kubectl get events -A --sort-by=.lastTimestamp | tail -20" >&2
fi
exit 0
