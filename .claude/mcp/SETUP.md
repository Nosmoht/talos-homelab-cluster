# MCP Setup for Homelab Repo

This repository expects at least two MCP servers for daily work:

- `github` (`gh mcp-server`) for PR, issue, and workflow interaction.
- `kubernetes` (`kubectl-mcp-server`) for structured cluster reads/writes.

## Prerequisites

```bash
# GitHub MCP
brew install gh

# Kubernetes MCP server runtime
brew install node
npm install -g kubectl-mcp-server

# Optional: default kubeconfig for this repo (use the path from cluster.yaml)
export KUBECONFIG=/tmp/<cluster-name>-kubeconfig
```

## Validation

```bash
gh auth status
npx -y kubectl-mcp-server --help
```

If `kubectl-mcp-server` is unavailable in your environment, keep `github` enabled and use `kubectl`/`talosctl` through normal terminal tools until a compatible Kubernetes MCP server is installed.
