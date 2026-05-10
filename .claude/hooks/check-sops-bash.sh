#!/bin/bash
# Block Bash commands that attempt to write plaintext content to *.sops.yaml paths.
# Catches: redirects (>, >>), heredoc (tee), sed -i, python open() writes.
# Fail-closed on jq parse errors (unlike check-sops.sh which exits 0 on failure).

PAYLOAD=$(cat)

# Fail-closed: if jq cannot parse the payload, block and report
COMMAND=$(echo "$PAYLOAD" | jq -r '.tool_input.command // empty' 2>&1)
JQ_STATUS=$?

if [ $JQ_STATUS -ne 0 ]; then
  echo "SOPS Bash check: failed to parse hook payload (jq exit $JQ_STATUS). Blocking as fail-closed safety measure." >&2
  exit 2
fi

# No command field (should not happen for Bash matcher, but allow through)
[ -z "$COMMAND" ] && exit 0

# Detect write operations targeting *.sops.yaml or *.sops.yml
# Patterns: shell redirects (>/>>), tee, sed -i, python open() in -c script
if echo "$COMMAND" | grep -qE '(>|>>|tee( -a)?|sed[[:space:]]+-i)[^;&#|]*\.sops\.(yaml|yml)'; then
  echo "SOPS Bash check failed: command writes to *.sops.yaml via redirect/tee/sed-i. Encrypt first: sops -e -i <file.sops.yaml>" >&2
  exit 2
fi

exit 0
