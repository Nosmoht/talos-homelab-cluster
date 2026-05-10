# MCP Server Setup

Claude Code (`.mcp.json`) and Codex CLI (`.codex/config.toml`) both reference three MCP
servers by bare command name. These binaries must be installed on your workstation and the
wrapper symlink must be registered in your `PATH`. All of this is automated by `make mcp-install`.

## Prerequisites

| Tool | macOS | Linux |
|------|-------|-------|
| `gh` (GitHub CLI) | `brew install gh` | https://cli.github.com |
| `brew` | https://brew.sh | not needed |
| `go` | via Homebrew or xcode tools | https://go.dev/dl (for `github-mcp-server`) |
| `npm` | via Homebrew Node.js | https://nodejs.org |
| `~/.local/bin` in `PATH` | add to `~/.zshrc` | add to `~/.bashrc` |

## Install

```bash
# 1. Clone the repo and enter it
git clone <repo-url> && cd Talos-Homelab

# 2. Install binaries and wrapper symlink
make mcp-install

# 3. Authenticate with GitHub (if not already done)
gh auth login

# 4. Verify everything is wired up
make mcp-verify

# 5. Restart Claude Code or Codex CLI
```

`make mcp-install` does the following per OS:

| Step | macOS | Linux |
|------|-------|-------|
| `github-mcp-server` | `brew install github-mcp-server` | `go install github.com/github/github-mcp-server/cmd/github-mcp-server@v0.33.0` |
| `kubernetes-mcp-server` | `brew install kubernetes-mcp-server` | `npm install -g kubernetes-mcp-server@0.0.60` |
| `talos-mcp` | `npm install -g talos-mcp@1.1.0` | `npm install -g talos-mcp@1.1.0` |
| Wrapper symlink | `~/.local/bin/mcp-github-wrapper -> scripts/mcp-github-wrapper.sh` | same |

## How the GitHub token works

The wrapper script (`scripts/mcp-github-wrapper.sh`) runs at MCP server spawn time:

1. Calls `gh auth token` to retrieve the token from macOS Keychain (or Linux libsecret)
2. Exports `GITHUB_PERSONAL_ACCESS_TOKEN` only into the `github-mcp-server` child process
3. The token is **never** written to disk or exported to your shell environment

To rotate: run `gh auth login` again. The wrapper picks up the new token on the next server spawn.

## Talos MCP Environment Variables

The `talos` MCP server supports these environment variables (set in `.mcp.json` and `.codex/config.toml`):

| Variable | Purpose | Default |
|---|---|---|
| `TALOS_CONTEXT` | Talos context name from `~/.talos/config` | first context |
| `TALOS_MCP_ALLOWED_PATHS` | Comma-separated **remote Talos-node** path prefixes that `talos_read_file` and `talos_list_files` may read via gRPC. **Unset = unrestricted.** | (none — unrestricted) |
| `TALOS_MCP_READ_ONLY` | Set to `true` to expose only read-only tools | false |

### `TALOS_MCP_ALLOWED_PATHS` details

This variable restricts **which paths on the Talos nodes** the AI can read — it has no relation to the local workstation filesystem. The repo sets an explicit restrictive allowlist (defense-in-depth):

```
/proc,/sys,/var/log,/run,/usr/local/etc,/etc/os-release
```

**Included:** hardware probes (`/proc/cpuinfo`, `/proc/net/*`), kernel config (`/proc/config.gz`), NIC/block device info (`/sys/class/net/*`, `/sys/block/*`), service logs (`/var/log`), runtime state (`/run`), extension configs (`/usr/local/etc`), OS version metadata (`/etc/os-release`).

**Excluded deliberately:** bare `/etc` (exposes `/etc/kubernetes/kubelet.conf` bearer token and PKI material — use `talos_get machineconfig` instead), `/var/lib` (etcd/kubelet state — use `talos_etcd`/`talos_get`), `/boot`, `/home`, `/root`.

To extend for a new use case, edit the value in `.mcp.json:19` and `.codex/config.toml:32`, then restart the MCP client.

## Troubleshooting

### `mcp-github-wrapper: not found`

`~/.local/bin` is not in your `PATH`. Add to your shell init file:

```bash
# ~/.zshrc or ~/.bashrc
export PATH="$HOME/.local/bin:$PATH"
```

Then reload: `source ~/.zshrc` (or restart your terminal), then restart Claude Code / Codex.

### `mcp-github-wrapper: 'gh auth token' failed`

Run `gh auth login` and follow the prompts.

### `mcp-github-wrapper: 'gh auth token' returned empty — keychain unlock required?`

On macOS: unlock your Keychain (`security unlock-keychain ~/Library/Keychains/login.keychain-db`)
or simply run `gh auth login` again to re-authenticate.

On Linux without a D-Bus session (headless/SSH): `gh` silently falls back to plaintext storage
in `~/.config/gh/hosts.yml`. The token is stored there; `gh auth token` still works but is not
Keychain-backed. Run `gh auth login` if the token is missing or expired.

### macOS GUI launch (Claude Code / Codex launched from Spotlight or Finder)

Apps launched outside a terminal do not inherit your shell `PATH`. The MCP servers will not be
found by bare command name. Fix with:

```bash
# Add ~/.local/bin and Homebrew to the GUI app PATH
sudo launchctl setenv PATH "/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"
```

Then restart Claude Code. This setting persists across reboots until explicitly removed.

### `github-mcp-server: not found in PATH` after `make mcp-install`

On Linux, `go install` places the binary in `$(go env GOPATH)/bin` (typically `~/go/bin`).
Ensure `~/go/bin` is in your `PATH`:

```bash
export PATH="$HOME/go/bin:$HOME/.local/bin:$PATH"
```

### Docker fallback for `github-mcp-server` (Linux without Go)

If you don't have Go installed, add this to `~/.codex/config.toml` as a user-level override:

```toml
[mcp_servers.github]
command = "docker"
args = ["run", "-i", "--rm", "-e", "GITHUB_PERSONAL_ACCESS_TOKEN", "ghcr.io/github/github-mcp-server"]
env = { GITHUB_PERSONAL_ACCESS_TOKEN = "${GITHUB_TOKEN}" }
startup_timeout_sec = 60
```

Pre-export `GITHUB_TOKEN` in your shell before launching Codex/Claude.
