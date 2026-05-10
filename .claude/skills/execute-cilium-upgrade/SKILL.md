---
name: execute-cilium-upgrade
description: Execute a reviewed Cilium upgrade for this homelab cluster by validating an approved migration plan, updating the repo-managed bootstrap version, reconciling via the Talos workflow, and enforcing health gates, stop conditions, and recovery actions.
argument-hint: <approved-plan-path>
disable-model-invocation: true
allowed-tools: Bash, Read, Grep, Glob, Write, mcp__talos__talos_apply_config, mcp__talos__talos_health, mcp__talos__talos_version, mcp__kubernetes-mcp-server__resources_get, mcp__kubernetes-mcp-server__resources_list, mcp__kubernetes-mcp-server__pods_list_in_namespace, mcp__kubernetes-mcp-server__pods_log
---

# Execute Cilium Upgrade

## Environment Setup

Read `cluster.yaml` to load cluster-specific values (node IPs, kubeconfig path, overlay name).
If the file is missing, tell the user: "Copy `cluster.yaml.example` to `cluster.yaml` and fill in your cluster details."

Use throughout this skill:
- `KUBECONFIG=<kubeconfig>` for all `kubectl` commands
- Node inventory from `nodes.control_plane`, `nodes.workers`, `nodes.gpu_workers`
- Overlay path: `kubernetes/overlays/<cluster.overlay>/`

Use this skill only after `plan-cilium-upgrade` has produced a reviewed migration plan and that plan has been explicitly approved for execution.

This skill changes live cluster state. Treat every step as safety-critical.

## Input
- Required argument: path to an approved Markdown plan document.

Preferred location:
- `docs/cilium-upgrade-plan-<from>-to-<to>-<yyyy-mm-dd>.md`

The approved plan must follow the output contract from `plan-cilium-upgrade`, contain these frontmatter fields, and contain these sections:
- `plan_source: plan-cilium-upgrade`
- `from_version: ...`
- `to_version: ...`
- `generated_at: ...`
- `status: approved`
- `approved_by: ...`
- `approved_at: ...`
- `Resolved Versions`
- `Reviewed Releases`
- `Migration Plan`
- `Risks`
- `Self-Review`

If the plan is missing any required field or section, stop. Do not infer missing approval context.

## Repository Facts You Must Respect
- Cilium is managed from `kubernetes/bootstrap/cilium/cilium.yaml`.
- Talos control-plane `extraManifests` consume that manifest from `talos/patches/controlplane.yaml`.
- `talos/versions.mk` is the version pin to update.
- Regenerate the bootstrap manifest with `make -C talos cilium-bootstrap`.
- Validate the bootstrap manifest with `make -C talos cilium-bootstrap-check`.
- Reconcile Talos-managed `extraManifests` through the supported Talos workflow. Do not use `kubectl apply` as a rollout shortcut.
- Commit and push tested changes immediately after the repo state is validated.

## Workflow

### 1. Validate the approved plan artifact
Read:
- the approved plan file passed as the argument
- `AGENTS.md`
- `README.md`
- `talos/versions.mk`
- `talos/Makefile`
- `talos/patches/controlplane.yaml`
- `.claude/rules/cilium-gateway-api.md`
- `docs/day2-operations.md`

Confirm the plan includes:
- frontmatter `plan_source: plan-cilium-upgrade`
- frontmatter `status: approved`
- non-empty frontmatter `approved_by`
- non-empty frontmatter `approved_at`
- a specific `from_version`
- a specific `to_version`
- explicit rollout steps
- explicit risks and stop conditions
- a self-review that does not leave unresolved blockers

Extract from the plan:
- approved `from_version`
- approved `to_version`
- any required pre-migration repo edits beyond the version bump
- any plan-specific validation commands or special cautions

If the plan says more investigation is required before execution, stop.

If the frontmatter `status` is not exactly `approved`, stop.

### 2. Confirm current state still matches the approved plan
Before editing anything, verify that the plan is still fresh.

Check:
- git worktree cleanliness for files involved in the upgrade
- current repo pin in `talos/versions.mk`
- current bootstrap manifest content in `kubernetes/bootstrap/cilium/cilium.yaml`
- live cluster Cilium version
- cluster health and node readiness
- Argo CD application health for platform apps that depend on Cilium

Run at minimum (use control-plane node IPs from `cluster.yaml`):
```
talos_version(nodes=["<cp-node-1-ip>", "<cp-node-2-ip>", "<cp-node-3-ip>"])
talos_health(nodes=["<cp-node-1-ip>"])
# Fallback: talosctl -n <cp-node-1-ip> -e <cp-node-1-ip> health --control-plane-nodes <cp-node-1-ip>,<cp-node-2-ip>,<cp-node-3-ip>
```
```bash
KUBECONFIG=<kubeconfig> kubectl get nodes -o wide
# ^ CLI-Only: token-negative; see .claude/rules/kubernetes-mcp-first.md §CLI-Only
KUBECONFIG=<kubeconfig> kubectl -n argocd get applications
# ^ CLI-Only: summary table, token-negative; see .claude/rules/kubernetes-mcp-first.md §CLI-Only
```
```
resources_get(apiVersion="apps/v1", kind="DaemonSet", name="cilium", namespace="kube-system")
# Read .spec.template.spec.containers[0].image for the daemonset image tag.
# Fallback: KUBECONFIG=<kubeconfig> kubectl -n kube-system get ds cilium -o json
resources_get(apiVersion="apps/v1", kind="Deployment", name="cilium-operator", namespace="kube-system")
# Read .spec.template.spec.containers[0].image for the operator image tag.
# Fallback: KUBECONFIG=<kubeconfig> kubectl -n kube-system get deploy cilium-operator -o json
pods_list_in_namespace(namespace="kube-system", labelSelector="k8s-app=cilium")
# Check items[].status.phase and items[].spec.nodeName for pod placement across nodes.
# Fallback: KUBECONFIG=<kubeconfig> kubectl -n kube-system get pods -l k8s-app=cilium -o wide
pods_list_in_namespace(namespace="kube-system", labelSelector="app.kubernetes.io/name=cilium-operator")
# Check items[].status.phase for operator pod health.
# Fallback: KUBECONFIG=<kubeconfig> kubectl -n kube-system get pods -l app.kubernetes.io/name=cilium-operator -o wide
resources_list(apiVersion="cilium.io/v2", kind="CiliumNode")
# Check items[].metadata.name and items[].status for per-node cilium state.
# Fallback: KUBECONFIG=<kubeconfig> kubectl get ciliumnode
```

If the live cluster version does not match the plan’s `from_version`, stop and report drift.

If the worktree already contains unrelated changes in files required for the upgrade, stop and resolve that first. Do not mix this rollout with other pending work.

If nodes are NotReady, Cilium is unhealthy, or dependent apps are already degraded, stop unless the approved plan explicitly covers that degraded starting state.

### 3. Create a pre-change evidence record
Before mutating the repo or cluster, capture baseline evidence for comparison.

Record:
- current git branch and status
- current `CILIUM_VERSION`
- live cilium daemonset image tag
- cilium pod status across all nodes
- operator status
- `ciliumnode` inventory
- key service reachability signals defined in the approved plan

Write a run record to:
- `docs/cilium-upgrade-execution-<from>-to-<to>-<yyyy-mm-dd>.md`

The run record must contain:
1. approved plan path
2. execution timestamp
3. baseline health
4. commands executed
5. results by stage
6. final verification
7. incidents, pauses, or recovery actions

### 4. Apply repo changes from the approved plan
Make only the changes required by the approved plan.

At minimum this usually means:
1. update `talos/versions.mk` `CILIUM_VERSION`
2. regenerate `kubernetes/bootstrap/cilium/cilium.yaml`
3. apply any repo-side migration edits required by upstream changes

Required commands:
```bash
make -C talos cilium-bootstrap
make -C talos cilium-bootstrap-check
```

Also run repo validation required by the changed files. At minimum:
```bash
make -C talos gen-configs
```
Dry-run all nodes via MCP (resolve IPs from cluster.yaml):
```
talos_apply_config(config_file="<abs-path>/talos/generated/<role>/<node>.yaml", dry_run=true, nodes=["<node-ip>"])
# Fallback: talosctl -n <node-ip> -e <node-ip> apply-config -f talos/generated/<role>/<node>.yaml --dry-run
```
```bash
kubectl kustomize kubernetes/overlays/<overlay>
kubectl apply -k kubernetes/overlays/<overlay> --dry-run=client
```

If the bootstrap manifest or supporting manifests need additional migration edits, make them before continuing. Do not continue with a partially updated repo.

### 5. Review the repo diff before rollout
Inspect the exact diff and compare it to the approved plan.

Confirm:
- `CILIUM_VERSION` changed to the approved target and nothing else changed unintentionally
- the rendered bootstrap manifest references the approved target
- no forbidden direct-apply workflow has been introduced
- no unrelated files were modified unless the plan required them

If the diff contains unexpected changes, stop and resolve before continuing.

### 6. Commit and push the validated repo state
Once the repo changes are validated:
```bash
git status --short
git add talos/versions.mk kubernetes/bootstrap/cilium/cilium.yaml
git commit -m "chore(cilium): upgrade to <to-version>"
git push
```

Do not batch this change with unrelated work.

After pushing, if Argo CD applications that depend on the new repo state need a refresh signal, use the repo’s documented hard refresh pattern:
```bash
KUBECONFIG=<kubeconfig> kubectl annotate application <app> -n argocd argocd.argoproj.io/refresh=hard --overwrite
```

### 7. Execute the supported rollout path
Use the approved plan’s sequencing. For this repo, Cilium rollout must stay consistent with Talos-managed `extraManifests`.

Default sequence:
1. ensure repo changes are pushed
2. reconcile Talos `extraManifests` using the supported workflow
3. monitor Cilium agent and operator rollout to completion
   - poll rollout status every 30 seconds
   - if no progress after 10 minutes, treat as a stop condition (rollout stall)
4. verify dependent platform capabilities

Supported reconciliation command when the plan depends on re-applying control-plane `extraManifests` (ensure `make -C talos cilium-bootstrap-check` passed first):
```bash
talosctl upgrade-k8s --to <kubernetes-version> -n <cp-node-1-ip> -e <cp-node-1-ip>
```
Resolve `<kubernetes-version>` from `talos/versions.mk` (`KUBERNETES_VERSION`).

If the approved plan also includes Talos or Kubernetes changes, follow that exact broader sequencing and do not collapse it into a pure Cilium rollout.

Do not use `kubectl apply` against `kubernetes/bootstrap/cilium/cilium.yaml` as a shortcut.

### 8. Enforce stage gates during rollout
After each stage, verify health before proceeding.

Minimum health gates:
```bash
KUBECONFIG=<kubeconfig> kubectl -n kube-system rollout status ds/cilium --timeout=10m
# ^ CLI-Only: rollout status — no MCP equivalent; see .claude/rules/kubernetes-mcp-first.md §CLI-Only
KUBECONFIG=<kubeconfig> kubectl -n kube-system rollout status deploy/cilium-operator --timeout=10m
# ^ CLI-Only: rollout status — no MCP equivalent
KUBECONFIG=<kubeconfig> kubectl -n argocd get applications
# ^ CLI-Only: summary table, token-negative; see .claude/rules/kubernetes-mcp-first.md §CLI-Only
```
```
pods_list_in_namespace(namespace="kube-system", labelSelector="k8s-app=cilium")
# Check items[].status.phase — all should be "Running". Check items[].spec.nodeName for per-node placement.
# Fallback: KUBECONFIG=<kubeconfig> kubectl -n kube-system get pods -l k8s-app=cilium -o wide
resources_list(apiVersion="cilium.io/v2", kind="CiliumNode")
# Check items[].metadata.name — one CiliumNode per Ready node expected.
# Fallback: KUBECONFIG=<kubeconfig> kubectl get ciliumnode
```

Also run plan-specific verification for:
- Gateway API data path
- Hubble relay / UI / metrics
- L2 announcements and LoadBalancer VIP continuity
- policy enforcement and high-signal drop checks
- storage/control-plane connectivity if called out in the plan

If Hubble is available, prefer it for post-change drop evidence.

### 9. Stop conditions
Stop immediately if any of the following occur:
- any node becomes NotReady and does not recover within the approved threshold
- `ds/cilium` rollout stalls or pods crashloop
- `cilium-operator` rollout stalls
- `ciliumnode` objects are missing, stale, or inconsistent with ready nodes
- Gateway API ingress breaks
- service VIPs or L2 announcements fail
- policy drops spike in impacted namespaces
- Argo CD shows broad degradation outside the expected blast radius

Do not continue “to see if it settles” once a stop condition is met.

### 10. Recovery actions
If a stop condition is met:
1. Halt further rollout actions immediately.
2. Collect diagnostics (commands below).
3. Classify the failure scope before choosing a recovery path:
   - **Agent restart only** (pods crashloop but DaemonSet not yet rolled forward): restart the Cilium DaemonSet pods on the affected node and re-run stage gates. Do not revert the repo yet.
   - **Partial rollout stall** (some nodes on new version, some on old): do not roll back nodes that already succeeded. Follow the plan's node-specific guidance.
   - **Full rollback required** (gateway down, broad policy drops, operator unavailable): revert the repo change, regenerate bootstrap artifacts, commit and push, and reconcile via the plan-approved path.
4. Do not improvise outside these three categories without explicit plan guidance.

Useful diagnostics:
```bash
KUBECONFIG=<kubeconfig> kubectl -n kube-system describe ds cilium
# ^ CLI-Only: describe — no MCP event-aggregation equivalent; see .claude/rules/kubernetes-mcp-first.md §CLI-Only
```
```
# Collect per-pod logs for crashlooping Cilium agents (fan-out: list → log per pod):
pods_list_in_namespace(namespace="kube-system", labelSelector="k8s-app=cilium")
# For each pod in items[].metadata.name that is not Running:
pods_log(name="<cilium-pod>", namespace="kube-system", tail=200)
# Fallback: KUBECONFIG=<kubeconfig> kubectl -n kube-system logs ds/cilium --tail=200

# Collect operator logs:
pods_list_in_namespace(namespace="kube-system", labelSelector="app.kubernetes.io/name=cilium-operator")
# For each pod in items[].metadata.name:
pods_log(name="<cilium-operator-pod>", namespace="kube-system", tail=200)
# Fallback: KUBECONFIG=<kubeconfig> kubectl -n kube-system logs deploy/cilium-operator --tail=200

resources_list(apiVersion="cilium.io/v2", kind="CiliumNode")
# Check items[].status for stale or missing ciliumnode objects.
# Fallback: KUBECONFIG=<kubeconfig> kubectl get ciliumnode -o yaml
```

If rollback requires repo reversion:
- revert only the Cilium upgrade change
- regenerate bootstrap artifacts
- validate again
- commit and push the reversion
- use the plan-approved reconciliation path

Do not improvise a direct-apply rollback unless the incident response explicitly accepts repo drift as a temporary emergency measure.

### 11. Final verification
Do not declare success until the target state is verified.

Run `/cluster-health-snapshot` for a structured 5-layer health check (Talos, K8s, Cilium, LINSTOR, PKI):
```
/cluster-health-snapshot
```

Confirm in addition to the snapshot output:
- live Cilium version equals approved `to_version`
- repo pin equals approved `to_version`
- all nodes have healthy `ciliumnode` objects
- Gateway API, Hubble, and L2/VIP behavior are normal
- Argo CD applications are healthy or only show expected transient reconciliation

Capture both the cluster-health-snapshot output and the final verification in the run record.

## Output
Return a concise execution summary with:
- approved plan path
- versions executed
- repo changes made
- rollout command path used
- final health status
- any incidents or remaining risks
- path to the execution record

## Hard Rules
- On Kubernetes MCP tool failure: retry once, then run the `# Fallback:` kubectl command from the same step. Applies to all `mcp__kubernetes-mcp-server__*` calls in this skill.
- Never execute without an approved plan artifact that matches the planning skill’s output contract.
- Never execute a plan whose frontmatter approval fields are missing or still set to `draft`.
- Never skip the “state still matches plan” check.
- Never use `kubectl apply` as the primary rollout mechanism for this Cilium deployment.
- Never continue past a defined stop condition.
- Never hide drift, failed checks, or partial rollout state in the final output.
