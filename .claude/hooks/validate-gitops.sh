#!/bin/bash
# Block git commit if staged kubernetes/ changes fail GitOps validation.
# Follows the same pattern as check-sops.sh (PreToolUse, exit 2 to block).
# Intentionally skips conftest + trivy (slow) — the full pipeline is in the skill and CI.
INPUT=$(cat)
COMMAND=$(jq -r '.tool_input.command // empty' <<< "$INPUT" 2>/dev/null)
[ -z "$COMMAND" ] && exit 0

# Only intercept git commit (NOT push — push sends already-committed work).
# No ^ anchor: handles prefixed commands like "cd /path && git commit".
if [[ "$COMMAND" =~ git[[:space:]]commit ]]; then
  cd "$CLAUDE_PROJECT_DIR" || exit 0

  # Fast-path: skip validation if no kubernetes/ files are staged
  if ! git diff --cached --name-only 2>/dev/null | grep -q '^kubernetes/'; then
    exit 0
  fi

  # Render once to a temp file (avoid double render, capture stderr for diagnosis)
  RENDERED=$(mktemp)
  RENDER_ERR=$(mktemp)
  trap 'rm -f "$RENDERED" "$RENDER_ERR"' EXIT

  if ! kubectl kustomize kubernetes/overlays/homelab > "$RENDERED" 2>"$RENDER_ERR"; then
    echo "validate-gitops FAILED: kustomize render error:" >&2
    tail -20 "$RENDER_ERR" >&2
    exit 2
  fi

  # Run kubeconform on rendered output (quick schema check)
  if command -v kubeconform &> /dev/null; then
    if ! kubeconform -strict -ignore-missing-schemas < "$RENDERED" > /dev/null 2>&1; then
      echo "validate-gitops FAILED: kubeconform schema error. Run 'kubectl kustomize kubernetes/overlays/homelab | kubeconform -strict -ignore-missing-schemas' for details." >&2
      exit 2
    fi
  fi
fi
exit 0
