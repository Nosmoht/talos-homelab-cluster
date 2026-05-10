#!/bin/sh
# MCP GitHub server wrapper — pulls auth token from gh CLI (macOS Keychain / Linux libsecret).
# Called via PATH-installed symlink created by `make mcp-install`.
# Fails loudly on missing/empty token — prevents silent anonymous-auth fallback.
# Token is injected only into the github-mcp-server child process — never exported to shell env.
set -eu

GH_BIN="${GH_BIN:-$(command -v gh 2>/dev/null || true)}"
GITHUB_MCP_BIN="${GITHUB_MCP_BIN:-$(command -v github-mcp-server 2>/dev/null || true)}"

if [ -z "$GH_BIN" ] || [ ! -x "$GH_BIN" ]; then
  echo "mcp-github-wrapper: 'gh' not found in PATH — install GitHub CLI (https://cli.github.com)" >&2
  exit 1
fi
if [ -z "$GITHUB_MCP_BIN" ] || [ ! -x "$GITHUB_MCP_BIN" ]; then
  echo "mcp-github-wrapper: 'github-mcp-server' not found in PATH — run 'make mcp-install'" >&2
  exit 1
fi

TOKEN=$("$GH_BIN" auth token 2>/dev/null) || {
  echo "mcp-github-wrapper: 'gh auth token' failed — run 'gh auth login'" >&2
  exit 1
}
if [ -z "$TOKEN" ]; then
  echo "mcp-github-wrapper: 'gh auth token' returned empty — keychain unlock required?" >&2
  exit 1
fi

export GITHUB_PERSONAL_ACCESS_TOKEN="$TOKEN"
exec "$GITHUB_MCP_BIN" stdio
