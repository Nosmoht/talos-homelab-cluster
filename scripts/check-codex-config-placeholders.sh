#!/bin/bash
# Validate that .codex/config.toml contains only ${VAR} placeholder expansions
# in env blocks — no literal tokens (API keys, passwords, etc.) must be committed.
#
# Called by pre-commit framework on changes to .codex/config.toml.

set -euo pipefail

CONFIG=".codex/config.toml"

if [ ! -f "$CONFIG" ]; then
  echo "check-codex-config-placeholders: $CONFIG not found, skipping."
  exit 0
fi

# Extract lines inside env = { ... } blocks (TOML inline table syntax).
# Flag any value that is NOT a ${...} placeholder and NOT a comment.
# A valid env value looks like: KEY = "${VAR}" or KEY = "${VAR}/suffix"
# An invalid env value: KEY = "actual-secret-value"

FAIL=0

while IFS= read -r line; do
  # Skip blank lines and comment lines
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  [[ -z "${line// /}" ]] && continue

  # Match env = { ... } inline table entries: key = "value"
  # Only check string values (quoted with ")
  while IFS= read -r kv; do
    # Extract the value portion (after =)
    value=$(echo "$kv" | sed -n 's/^[^=]*=[[:space:]]*"\([^"]*\)".*/\1/p')
    [ -z "$value" ] && continue

    # Reject values that don't start with ${ (i.e., literal values)
    if [[ "$value" != \$\{* ]]; then
      echo "ERROR: Literal value found in $CONFIG env block: $kv" >&2
      echo "       Replace with a \${ENV_VAR} placeholder to avoid committing secrets." >&2
      FAIL=1
    fi
  done < <(echo "$line" | grep -oE '[A-Z_]+ = "[^"]*"' || true)

done < "$CONFIG"

if [ "$FAIL" -ne 0 ]; then
  echo "check-codex-config-placeholders: FAILED — literal tokens detected in $CONFIG" >&2
  exit 1
fi

echo "check-codex-config-placeholders: OK — all env values use \${VAR} placeholders"
exit 0
