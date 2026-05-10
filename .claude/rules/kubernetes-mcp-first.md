---
paths:
  - ".claude/skills/**"
  - ".claude/agents/**"
  - ".claude/rules/kubernetes-mcp-first.md"
  - "docs/day2-operations.md"
---

# Kubernetes MCP-First Policy

## Policy Statement

Use `mcp__kubernetes-mcp-server__*` tools for all supported read operations inside `.claude/` skill
and agent workflows. Fall back to `kubectl` CLI only for operations with no MCP equivalent (see
CLI-Only table below).

**Failure taxonomy — three distinct cases, each handled differently:**

- **(a) Tool error or timeout** → retry once → fall back to `kubectl` CLI for the remainder of the
  session and log the fallback in the report.
- **(b) Empty collection** (`resources_list → []`) is a **valid zero result**. Do **not** fall back
  to `kubectl` — report the empty result directly. Fallback-on-empty double-queries the cluster and
  inverts the token-reduction goal.
- **(c) Partial or inconsistent data** is undetectable at the tool boundary. Trust the response.

**`# Fallback: kubectl ...` comments** adjacent to MCP calls are policy, not dead code. They are the
retry fallback for case (a) and must not be removed. See `cluster-health-snapshot/SKILL.md` L161 for
the per-skill Hard Rules line that reinforces this.

When a MCP tool fails: retry once, then fall back to CLI for the remainder of the session and log the
fallback.

## Read-Only Mode Disclosure

The server is configured with `--read-only --disable-multi-cluster` in `.mcp.json`:

- `--read-only` blocks all create, update, and delete operations. All write operations (`apply`,
  `patch`, `delete`, `annotate`, `label`, `scale`, `rollout`, `drain`, `cordon`, `uncordon`,
  `exec`, `debug`) must use `kubectl` CLI.
- `--disable-multi-cluster` restricts the server to the current kubeconfig context only.
  `kubectl --context` is CLI-only by definition.
- **Version pin** lives in `docs/mcp-setup.md` (brew/npm install instructions), **not** in
  `.mcp.json`. The server is a bare PATH-resolved command. Any version bump that changes tool
  schemas is load-bearing — check `docs/mcp-setup.md` before upgrading.

## MCP Tool Mapping

### MCP-First (always prefer these for reads)

| kubectl idiom | MCP tool | Required params |
|---|---|---|
| `kubectl get <kind>` / `-A` | `resources_list` | `apiVersion`, `kind` |
| `kubectl get <kind> <name>` | `resources_get` | `apiVersion`, `kind`, `name` |
| `kubectl get httproute -A` | `resources_list` | `apiVersion="gateway.networking.k8s.io/v1"`, `kind="HTTPRoute"` |
| `kubectl get pods -A` | `pods_list` | — |
| `kubectl get pods -n NS` | `pods_list_in_namespace` | `namespace` |
| `kubectl get pod NAME -n NS` | `pods_get` | `name`, `namespace` |
| `kubectl logs POD -n NS` | `pods_log` | `name`, `namespace`, `tail` (required) |
| `kubectl top nodes` | `nodes_top` | — (requires metrics-server) |
| `kubectl top pods` | `pods_top` | — (requires metrics-server) |
| `kubectl get events` | `events_list` | — |
| `kubectl get ns` | `namespaces_list` | — |
| `kubectl config view` | `configuration_view` | — |
| node system logs | `nodes_log` | `name` |
| `/api/v1/nodes/.../stats/summary` | `nodes_stats_summary` | `name` |

### CLI-Only (no safe MCP equivalent)

| Operation | CLI Command | Reason |
|---|---|---|
| Apply/patch/delete resources | `kubectl apply/patch/delete` | `--read-only` flag blocks |
| Annotate, label, scale | `kubectl annotate/label/scale` | `--read-only` flag blocks |
| Rollout, cordon, drain, uncordon | `kubectl rollout/cordon/drain/uncordon` | `--read-only` flag blocks; no MCP equivalent |
| Pod exec / debug | `kubectl exec` / `kubectl debug` | `--read-only` flag blocks |
| Describe (event-aggregated output) | `kubectl describe` | No event-aggregation tool in MCP |
| LINSTOR plugin | `kubectl linstor ...` | Plugin, no MCP surface |
| Local kustomize render | `kubectl kustomize` | Local render, no cluster call |
| Kustomize dry-run (local) | `kubectl apply -k --dry-run=client` | Local validation, no cluster call |
| Log follow (streaming) | `kubectl logs -f` | No streaming equivalent in MCP |
| Label-selector logs | `kubectl logs -l <selector>` | `pods_log` takes `name`, not a selector |
| Config backup to file | `kubectl get mc -o yaml > /tmp/file` | MCP returns to conversation, not to disk |
| Multi-cluster context switch | `kubectl --context` | `--disable-multi-cluster` blocks |
| Long-ceiling wait | `kubectl wait --timeout` | Bounded-poll contract caps at 2 minutes (see §Watch/Wait Contract) |
| Token-negative reads (no selector) | `kubectl get nodes -o wide` | JSON object list >> column output; net token-negative |
| Token-negative reads (no selector) | `kubectl get pods -A` without selector | JSON object list >> column output; net token-negative |
| Token-negative reads (no selector) | `kubectl get applications` for summary tables | Same reason |
| Raw cluster metrics proxy | `kubectl get --raw /metrics` | Raw proxy endpoint not exposed by MCP |

## Decision Flow

```
Need a Kubernetes read operation?
  → Is there a MCP tool for it? (see table above)
      YES → Use MCP tool
      NO  → Use kubectl CLI (CLI-Only list)
  → MCP tool fails with error or timeout?
      Retry once → still fails → kubectl CLI fallback for session, log it
  → MCP tool returns empty list?
      Report empty — do NOT fall back to kubectl (case b)
```

## Critical Parameter Rules

These parameters must **always** be specified explicitly — never rely on defaults:

- **`apiVersion` + `kind`** for every `resources_list` and `resources_get` call (e.g. `apps/v1`,
  `cilium.io/v2`, `argoproj.io/v1alpha1`, `gateway.networking.k8s.io/v1`). Without `apiVersion`
  the server may resolve to the wrong group version.
- **`namespace`** for all namespaced kinds on `resources_list`, `resources_get`, `pods_list_in_namespace`,
  `pods_get`, `pods_log`. Omitting namespace returns cross-namespace or fails silently.
- **`container`** on `pods_log` for multi-container pods. Without it the server picks the first
  container, which may not be the relevant one.
- **`tail`** on every `pods_log` call. Without it the server's default limit silently truncates
  evidence. Match the original `kubectl logs --tail=N`; if the original had no `--tail`, default
  to `tail=500` and document the bound inline (e.g. `# tail=500 — original had no --tail`).
- **`labelSelector`** / **`fieldSelector`** — when the original `kubectl` had `-l` or
  `--field-selector`, pass the equivalent through. Never fetch-all and filter client-side — it
  defeats the token-reduction goal and is rejected by the token-budget check.
- **`resources_get` for named lookups** — use `resources_get` for a single named object, not
  `resources_list` + client-side name filter. Two different tools for two different access patterns.

## Known Restrictions

- **No `-f` / follow mode** — `pods_log` is single-shot. Live streaming stays on `kubectl logs -f`.
- **No `jsonpath` / `-o go-template`** — post-filter in skill prose against the returned JSON
  structure (e.g. `items[].status.phase`, `status.conditions[].type == "Approved"`), not against
  column positions or jsonpath expressions.
- **Structured JSON output** — `resources_list` returns full object JSON, not `kubectl` column
  format. Any skill step that previously `grep`/`awk`/`jsonpath`'d kubectl stdout must be rewritten
  to describe the JSON field path. Include a worked example in the PR description audit block.
- **`--disable-multi-cluster`** strips context-switching. Any workflow requiring a non-default
  context is CLI-only.
- **Version pin** — the MCP server binary is PATH-resolved. The installed version is pinned via
  the instructions in `docs/mcp-setup.md`. A version bump that changes tool schemas is
  load-bearing: verify `allowed-tools` entries in skills still match after any upgrade.

## kubectl Hygiene

- **Always pass explicit `-n <namespace>` for any kubectl command that creates, mutates, or execs into objects** — `run`, `create`, `apply`, `delete`, `edit`, `patch`, `exec`, `debug`, `port-forward`, `cp`, `rollout`, `scale`, `label`, `annotate`, `logs` (if using `-f` or writing to a ticket). Never rely on the kubeconfig context default namespace: it can point at a non-existent namespace, a stale target from a previous cluster, or simply whatever the user was last working on — and the failure mode depends on which value it currently holds. Explicit `-n` makes commands self-describing in git history, PR comments, and runbook output.
- **Exceptions:**
  - Cluster-scoped resources (`Node`, `PersistentVolume`, `ClusterRole`, `CRD`, `StorageClass`, `Namespace`) — no namespace needed.
  - MCP tools (`mcp__kubernetes-mcp-server__*`) take `namespace` as an explicit parameter and cannot inherit the context default.
  - Interactive read-only `get` / `describe` during live troubleshooting — acceptable to omit if the intent is immediately obvious, but never omit when the output lands in a PR, issue, commit message, or runbook.

## Watch/Wait Contract

MCP tools are single-shot — there is no `-w` / `--watch` mode. Replace `kubectl get ... -w`,
`kubectl wait`, and `kubectl rollout status` with a **bounded poll**:

- **Max 12 iterations × 10 s sleep = 2-minute ceiling.**
- On timeout: report the last observed status and stop — do not extend.
- Longer-ceiling waits stay on `kubectl wait --timeout` (CLI-Only).

Example pattern:
```
for i in $(seq 1 12); do
  status=$(resources_get(...).status.phase)
  [ "$status" = "Running" ] && break
  sleep 10
done
# Report status — do not loop further
```
