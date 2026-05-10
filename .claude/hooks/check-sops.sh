#!/bin/bash
# Block writes of unencrypted content to *.sops.yaml paths
FILE_PATH=$(jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$FILE_PATH" ] && exit 0

# Only check files that should be SOPS-encrypted
if [[ "$FILE_PATH" == *.sops.yaml ]] || [[ "$FILE_PATH" == *.sops.yml ]]; then
  CONTENT=$(jq -r '.tool_input.content // empty' 2>/dev/null)
  if [ -n "$CONTENT" ] && ! echo "$CONTENT" | grep -q 'sops:'; then
    echo "SOPS check failed: $FILE_PATH appears unencrypted (missing 'sops:' key). Encrypt with: sops -e -i $FILE_PATH" >&2
    exit 2
  fi
fi
exit 0
