#!/bin/bash
# Block kubectl drain if DRBD resources are degraded or satellites are offline.
# Prevents the DRBD D-state upgrade deadlock documented in talos-mcp-first.md §Node Recovery.
INPUT=$(cat)
COMMAND=$(jq -r '.tool_input.command // empty' <<< "$INPUT" 2>/dev/null)
[ -z "$COMMAND" ] && exit 0

# Only intercept kubectl drain subcommand (must be followed by a space and argument)
if [[ "$COMMAND" =~ kubectl[[:space:]]+drain[[:space:]] ]]; then
  # Extract node name — skip flag tokens (starting with -), take first non-flag token after drain
  # BSD-compatible: uses tr and grep -v (no grep -oP on macOS)
  NODE=$(echo "$COMMAND" | sed 's/.*drain//' | tr ' ' '\n' | grep -v '^-' | grep -v '^$' | head -1)
  [ -z "$NODE" ] && exit 0

  # Check for degraded DRBD resources cluster-wide
  DEGRADED=$(kubectl linstor resource list 2>/dev/null | grep -c "Degraded\|SyncTarget\|Inconsistent" || true)
  if [ "$DEGRADED" -gt 0 ]; then
    echo "DRBD safety check FAILED: $DEGRADED degraded resource(s) detected. Run '/linstor-storage-triage' for details." >&2
    exit 2
  fi

  # Check for OFFLINE satellites (with ALLOWED_OFFLINE allowlist bypass)
  # ALLOWED_OFFLINE="node-pi-01,other-name" permits drain when every OFFLINE
  # satellite is in the allowlist. Use case: permacordoned helper nodes that
  # should not block drains on unrelated nodes. No blanket bypass intentionally —
  # stale env vars silently reviving D-state deadlocks is the footgun this hook
  # exists to prevent.
  OFFLINE_NAMES=$(kubectl linstor node list 2>/dev/null \
    | awk -F'|' '/OFFLINE|UNKNOWN/ {gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2}' \
    | grep -v '^$' || true)
  if [ -n "$OFFLINE_NAMES" ]; then
    UNALLOWED=""
    for name in $OFFLINE_NAMES; do
      case ",${ALLOWED_OFFLINE:-}," in
        *",$name,"*) continue ;;
        *) UNALLOWED="$UNALLOWED $name" ;;
      esac
    done
    if [ -n "$UNALLOWED" ]; then
      COUNT=$(echo "$UNALLOWED" | wc -w | tr -d ' ')
      echo "DRBD safety check FAILED: $COUNT satellite(s) OFFLINE/UNKNOWN:$UNALLOWED. Run '/linstor-storage-triage' for details, or set ALLOWED_OFFLINE=\"name1,name2\" if these are expected." >&2
      exit 2
    fi
    # All offline nodes are in the allowlist — log the bypass loudly.
    ACCEPTED=$(echo "$OFFLINE_NAMES" | tr '\n' ',' | sed 's/,$//')
    echo "pre-drain-check: hook bypass — accepting OFFLINE satellites [$ACCEPTED] per ALLOWED_OFFLINE env" >&2
  fi
fi
exit 0
