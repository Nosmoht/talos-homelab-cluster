#!/bin/bash
# Validate that reviewer output files (Plans/*-agent-*.md) contain probe evidence.
# Fires as PostToolUse on Write|Edit. Exit code 2 forces Claude to fix the output.
#
# Enforces three invariants:
#   1. A ## Probes (or ## Verification Log) section exists.
#   2. That section contains at least one probe command (kubectl/talosctl/curl/port-forward).
#   3. The verdict token appears AFTER the ## Probes section lexically.

INPUT=$(cat)
FILE_PATH=$(jq -r '.tool_input.file_path // empty' <<< "$INPUT" 2>/dev/null)

[ -z "$FILE_PATH" ] && exit 0

# Only validate reviewer output files matching Plans/*-agent-*.md
if [[ ! "$FILE_PATH" =~ /Plans/.*-agent-.*\.md$ ]]; then
  exit 0
fi

[ ! -f "$FILE_PATH" ] && exit 0

# Check 1: ## Probes or ## Verification Log section exists
if ! grep -qE '^## (Probes|Verification Log)' "$FILE_PATH"; then
  echo "require-probe-evidence: $(basename "$FILE_PATH") is missing a '## Probes' section." >&2
  echo "Reviewer output must include a '## Probes' section with raw kubectl/talosctl/curl output." >&2
  echo "If no invariant rows fired, write: '## Probes\nNo rows fired: <one-line reason>'." >&2
  exit 2
fi

# Check 2: Probes section contains at least one tool command
PROBES_LINE=$(grep -n '^## Probes\|^## Verification Log' "$FILE_PATH" | head -1 | cut -d: -f1)
if [ -n "$PROBES_LINE" ]; then
  PROBES_CONTENT=$(tail -n +"$PROBES_LINE" "$FILE_PATH")
  if ! echo "$PROBES_CONTENT" | grep -qE 'kubectl|talosctl|curl|port-forward'; then
    echo "require-probe-evidence: $(basename "$FILE_PATH") has a ## Probes section but no probe commands." >&2
    echo "Include raw output from kubectl, talosctl, curl, or port-forward — or explain why no probes apply." >&2
    exit 2
  fi
fi

# Check 3: Verdict appears after ## Probes section
VERDICT_LINE=$(grep -n 'Verdict:\|VERDICT:\|\*\*Verdict\*\*\|## Verdict' "$FILE_PATH" | head -1 | cut -d: -f1)

if [ -n "$PROBES_LINE" ] && [ -n "$VERDICT_LINE" ]; then
  if [ "$VERDICT_LINE" -lt "$PROBES_LINE" ]; then
    echo "require-probe-evidence: Verdict at line $VERDICT_LINE appears before ## Probes at line $PROBES_LINE in $(basename "$FILE_PATH")." >&2
    echo "Move all findings and the verdict below the ## Probes section." >&2
    exit 2
  fi
fi

exit 0
