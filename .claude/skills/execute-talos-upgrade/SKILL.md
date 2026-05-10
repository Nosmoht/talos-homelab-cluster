---
name: execute-talos-upgrade
description: Execute a reviewed Talos upgrade for this homelab cluster by validating an approved migration plan, updating repo-managed version and schematic inputs, regenerating configs, and performing a gated node-by-node rollout with explicit recovery actions.
argument-hint: <approved-plan-path>
disable-model-invocation: true
allowed-tools:
  - Bash
  - Read
  - Grep
  - Glob
  - Write
  - mcp__talos__talos_apply_config
  - mcp__talos__talos_version
  - mcp__talos__talos_health
  - mcp__talos__talos_etcd
  - mcp__talos__talos_services
  - mcp__talos__talos_dmesg
  - mcp__talos__talos_etcd_snapshot
  - mcp__talos__talos_upgrade
  - mcp__talos__talos_rollback
  - mcp__talos__talos_validate
  - mcp__kubernetes-mcp-server__resources_get
  - mcp__kubernetes-mcp-server__resources_list
  - mcp__kubernetes-mcp-server__pods_list_in_namespace
---

# Execute Talos Upgrade

## Environment Setup

Read `cluster.yaml` to load cluster-specific values (node IPs, kubeconfig path, cluster name).
If the file is missing, tell the user: "Copy `cluster.yaml.example` to `cluster.yaml` and fill in your cluster details."

Use throughout this skill:
- `KUBECONFIG=<kubeconfig>` for all `kubectl` commands
- `-n <node-ip> -e <node-ip>` for all `talosctl` commands targeting a node
- Node inventory from `nodes.control_plane`, `nodes.workers`, `nodes.gpu_workers`, `nodes.pi_nodes`
- Upgrade order: control-plane nodes first, then workers, then GPU workers, then Pi nodes

Use this skill only after `plan-talos-upgrade` has produced a reviewed migration plan and that plan has been explicitly approved for execution.

This skill changes live cluster state and reboots nodes. Treat every step as safety-critical.

## Input
- Required argument: path to an approved Markdown plan document.

Preferred location:
- `docs/talos-upgrade-plan-<from>-to-<to>-<yyyy-mm-dd>.md`

The approved plan must follow the output contract from `plan-talos-upgrade`, contain these frontmatter fields, and contain these sections:
- `plan_source: plan-talos-upgrade`
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
- Talos version intent is pinned in `talos/versions.mk`.
- Install images are derived from `talos/.schematic-ids.mk` and `talos/Makefile`.
- Generated machine configs live under `talos/generated/**` and must never be edited directly.
- Cluster-wide upgrades must be done one node at a time with explicit readiness gates.
- Manual Talos operations must use explicit node endpoints.
- If schema, boot args, or extensions change, schematic regeneration may be required before upgrade execution.
- Do not batch this rollout with unrelated repo changes.

## Workflow

### 1. Validate the approved plan artifact
Read:
- the approved plan file passed as the argument
- `AGENTS.md`
- `README.md`
- `docs/day2-operations.md`
- `talos/Makefile`
- `talos/versions.mk`
- relevant Talos patch and schematic files referenced by the plan

Confirm the plan includes:
- frontmatter `plan_source: plan-talos-upgrade`
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
- whether schematics must be regenerated
- any required repo edits beyond `TALOS_VERSION`
- whether coupled Cilium work requires `talos/patches/controlplane.yaml` `?v=` changes and `make -C talos cilium-bootstrap`
- any plan-specific validation commands or special cautions

If the plan says more investigation is required before execution, stop.

If the frontmatter `status` is not exactly `approved`, stop.

### 2. Confirm current state still matches the approved plan
Before editing anything, verify that the plan is still fresh.

Check:
- git worktree cleanliness for files involved in the upgrade
- current repo pin in `talos/versions.mk`
- current schematic inputs and IDs if the plan depends on them
- live Talos version across control-plane nodes
- cluster health, etcd health, and node readiness
- Cilium and Kubernetes baseline health before node reboots begin

Run at minimum:
Use control-plane node IPs from `cluster.yaml`:
```bash
git status --short
```
```
talos_version(nodes=["<cp-node-1-ip>", "<cp-node-2-ip>", "<cp-node-3-ip>"])
talos_health(nodes=["<cp-node-1-ip>"])
talos_etcd(subcommand="members", nodes=["<cp-node-1-ip>"])
talos_etcd(subcommand="status", nodes=["<cp-node-1-ip>"])
# Fallback: talosctl -n <cp-node-1-ip> -e <cp-node-1-ip> health --control-plane-nodes <cp-node-1-ip>,<cp-node-2-ip>,<cp-node-3-ip>
```
```bash
KUBECONFIG=<kubeconfig> kubectl get nodes -o wide
# ^ CLI-Only: token-negative; see .claude/rules/kubernetes-mcp-first.md §CLI-Only
KUBECONFIG=<kubeconfig> kubectl get pods -A | grep -v Running
# ^ CLI-Only: no selector, token-negative; see .claude/rules/kubernetes-mcp-first.md §CLI-Only
KUBECONFIG=<kubeconfig> kubectl linstor node list
# ^ CLI-Only: kubectl plugin, no MCP surface
KUBECONFIG=<kubeconfig> kubectl linstor resource list
# ^ CLI-Only: kubectl plugin, no MCP surface
```
```
pods_list_in_namespace(namespace="kube-system", labelSelector="k8s-app=cilium")
# Check items[].status.phase — all should be "Running". Read items[].metadata.name for pod names.
# Fallback: KUBECONFIG=<kubeconfig> kubectl -n kube-system get pods -l k8s-app=cilium -o wide
```

If the live cluster version does not match the plan’s `from_version`, stop and report drift.

If the worktree already contains unrelated changes in files required for the upgrade, stop and resolve that first. Do not mix this rollout with other pending work.

If nodes are NotReady, etcd is unhealthy, DRBD state is risky, or Cilium is already degraded, stop unless the approved plan explicitly covers that degraded starting state.

### 3. Create a pre-change evidence record
Before mutating the repo or cluster, capture baseline evidence and a recovery snapshot.

Take an etcd backup:
```
talos_etcd_snapshot(nodes=["<cp-node-1-ip>"], path="/tmp/etcd-backup-pre-upgrade-YYYYMMDD.db")
# Fallback: talosctl -n <cp-node-1-ip> -e <cp-node-1-ip> etcd snapshot /tmp/etcd-backup-pre-upgrade-$(date +%Y%m%d).db
```
Store the backup path in the run record. Verify the snapshot file size is non-zero before proceeding.

Capture baseline evidence for comparison.

Record:
- current git branch and status
- current `TALOS_VERSION`, `KUBERNETES_VERSION`, and `CILIUM_VERSION`
- schematic IDs if present
- Talos version by node
- etcd members and cluster health
- node readiness
- Cilium health and storage health

Write a run record to:
- `docs/talos-upgrade-execution-<from>-to-<to>-<yyyy-mm-dd>.md`

The run record must contain:
1. approved plan path
2. execution timestamp
3. baseline health
4. commands executed
5. results by stage and by node
6. final verification
7. incidents, pauses, or recovery actions

Example structure:
```markdown
---
plan_path: docs/talos-upgrade-plan-v1.8.0-to-v1.9.0-2026-03-20.md
executed_at: 2026-03-21T14:00:00Z
---
## Baseline Health
[pre-change evidence output]
## Rollout Log
### node-01
- dry-run: OK
- upgrade: started 14:05, rebooted 14:07, healthy 14:09
- gates: etcd 3/3, cilium OK, linstor OK
```

### 4. Apply repo changes from the approved plan
Make only the changes required by the approved plan.

At minimum this usually means:
1. update `talos/versions.mk` `TALOS_VERSION`
2. regenerate schematics if the plan requires it
3. regenerate configs
4. validate generated configs

Required commands when applicable:
```bash
make -C talos schematics
make -C talos validate-schematics
make -C talos cilium-bootstrap
make -C talos cilium-bootstrap-check
make -C talos gen-configs
# Validate all generated configs (CLI-only — talos_validate works per-node, not file)
find talos/generated -type f -name '*.yaml' | sort | while read f; do echo "Validating $f"; talosctl validate --config "$f" --mode metal --strict; done
```
Dry-run all nodes via MCP (resolve IPs from cluster.yaml):
```
talos_apply_config(config_file="<abs-path>/talos/generated/<role>/<node>.yaml", dry_run=true, nodes=["<node-ip>"])
# Fallback: talosctl -n <node-ip> -e <node-ip> apply-config -f talos/generated/<role>/<node>.yaml --dry-run
```

If the approved plan includes Kubernetes or Cilium coupling, update and validate those repo changes before continuing. Do not continue with a partially updated repo state.

### 5. Review the repo diff before rollout
Inspect the exact diff and compare it to the approved plan.

Confirm:
- `TALOS_VERSION` changed to the approved target and nothing else changed unintentionally
- schematic or patch changes match the approved plan exactly
- any required `talos/patches/controlplane.yaml` `?v=` bump and bootstrap Cilium regeneration match the approved plan exactly
- generated config changes are consistent with the version hop
- no unrelated files were modified unless the plan required them

If the diff contains unexpected changes, stop and resolve before continuing.

### 6. Commit and push the validated repo state
Once the repo changes are validated:
```bash
git status --short
git add talos/versions.mk talos/.schematic-ids.mk talos/talos-factory-schematic.yaml talos/talos-factory-schematic-gpu.yaml talos/talos-factory-schematic-pi.yaml talos/patches/controlplane.yaml kubernetes/bootstrap/cilium/cilium.yaml
git commit -m "chore(talos): upgrade to <to-version>"
git push
```

Stage only the files actually changed by the approved plan. Do not batch this change with unrelated work.

### 7. Execute the supported rollout path
Before beginning, check etcd leadership: `talosctl -n <cp-node-1-ip> -e <cp-node-1-ip> etcd status`. Upgrade non-leader control-plane nodes first to minimize quorum disruption risk. If the first planned CP node is the current etcd leader, begin with a follower node instead.

Use the approved plan’s sequencing. Default order: control-plane nodes first (from `nodes.control_plane`), then standard workers (from `nodes.workers`), then GPU workers (from `nodes.gpu_workers`), then Pi nodes (from `nodes.pi_nodes`). Resolve the exact node names and IPs from `cluster.yaml`.

For each node (resolve install image from `talos/.schematic-ids.mk` + `talos/versions.mk`):
```
# 1. Dry-run:
talos_apply_config(config_file="<abs-path>/talos/generated/<role>/<node>.yaml", dry_run=true, nodes=["<node-ip>"])
# 2. Apply config (dry_run must be false):
talos_apply_config(config_file="<abs-path>/talos/generated/<role>/<node>.yaml", dry_run=false, confirm=true, nodes=["<node-ip>"], mode="auto")
# 3. Upgrade (fires and returns — poll talos_health until node rejoins):
talos_upgrade(nodes=["<node-ip>"], image="<install-image>", preserve=true, confirm=true)
talos_health(nodes=["<node-ip>"])  # repeat until healthy
# Fallback for apply: talosctl -n <node-ip> -e <node-ip> apply-config -f talos/generated/<role>/<node>.yaml
# Fallback for upgrade: talosctl upgrade -n <node-ip> -e <node-ip> --image <install-image> --preserve
```

Wait for health gates to pass before moving to the next node. Do not parallelize node upgrades.

If the approved plan includes a separate Kubernetes or Cilium reconciliation step, follow that exact broader sequencing and do not improvise a shorter path.

If the approved plan includes a coupled Cilium refresh through Talos `extraManifests`, apply config to all nodes then run `talosctl upgrade-k8s` (CLI-only — no MCP equivalent):
```
# Apply config to all nodes via MCP:
for each node: talos_apply_config(config_file="<abs-path>/talos/generated/<role>/<node>.yaml", dry_run=false, confirm=true, nodes=["<node-ip>"], mode="auto")
```
```bash
# Then reconcile extraManifests (ensure cilium-bootstrap-check passed first — CLI-only):
talosctl upgrade-k8s --to <kubernetes-version> -n <cp-node-1-ip> -e <cp-node-1-ip>
```

### 8. Enforce stage gates during rollout
After each node upgrade, verify health before proceeding.

Minimum per-node health gates:
```
resources_get(apiVersion="v1", kind="Node", name="<node>")
# Check .status.conditions[] — find type=="Ready", verify status=="True".
# Fallback: KUBECONFIG=<kubeconfig> kubectl get node <node>
```
```bash
KUBECONFIG=<kubeconfig> kubectl get nodes -o wide
# ^ CLI-Only: token-negative; see .claude/rules/kubernetes-mcp-first.md §CLI-Only
KUBECONFIG=<kubeconfig> kubectl linstor node list
# ^ CLI-Only: kubectl plugin, no MCP surface
```
```
pods_list_in_namespace(namespace="kube-system", labelSelector="k8s-app=cilium")
# Check items[].status.phase — all should be "Running" after node reboot.
# Fallback: KUBECONFIG=<kubeconfig> kubectl -n kube-system get pods -l k8s-app=cilium -o wide
```
```
talos_version(nodes=["<node-ip>"])
talos_health(nodes=["<cp-node-1-ip>"])
talos_etcd(subcommand="members", nodes=["<cp-node-1-ip>"])
# Fallback: talosctl -n <cp-node-1-ip> -e <cp-node-1-ip> health --control-plane-nodes <cp-node-1-ip>,<cp-node-2-ip>,<cp-node-3-ip>
```

Also run plan-specific verification for:
- API server reachability
- control-plane quorum and learner/voter status
- Cilium recovery and pod networking
- storage/DRBD safety
- GPU or Pi node-specific behavior if applicable
- kubelet CSR handling if a node fails to become Ready automatically

### 9. Stop conditions
Stop immediately if any of the following occur:
- a control-plane node fails to return healthy within the approved threshold
- etcd quorum is degraded or a member fails to rejoin cleanly
- a worker remains NotReady past the approved threshold
- DRBD or LINSTOR health degrades beyond the approved risk boundary
- Cilium fails to recover after a node reboot
- API server or pod networking is broken
- a node is stuck shutting down
- unexpected CSR, certificate, or bootstrap issues block readiness

Do not continue “to see if it settles” once a stop condition is met.

### 10. Recovery actions
If a stop condition is met:
1. halt further rollout actions
2. collect diagnostics
3. compare the failure with the approved rollback and recovery guidance
4. choose the least-risk recovery path supported by the plan

Useful diagnostics:
```
talos_version(nodes=["<node-ip>"])
talos_services(nodes=["<node-ip>"])
talos_dmesg(nodes=["<node-ip>"])
talos_etcd(subcommand="members", nodes=["<cp-node-1-ip>"])
# Fallback: talosctl -n <node-ip> -e <node-ip> version && talosctl -n <node-ip> -e <node-ip> services && talosctl -n <node-ip> -e <node-ip> dmesg | tail -n 200
```
```
resources_list(apiVersion="certificates.k8s.io/v1", kind="CertificateSigningRequest")
# Check items[].status.conditions[].type == "Approved" and status == "True".
# Pending CSRs show no conditions or conditions with type=="Pending".
# Fallback: KUBECONFIG=<kubeconfig> kubectl get csr
```
```bash
KUBECONFIG=<kubeconfig> kubectl get nodes -o wide
# ^ CLI-Only: token-negative; see .claude/rules/kubernetes-mcp-first.md §CLI-Only
KUBECONFIG=<kubeconfig> kubectl linstor resource list
# ^ CLI-Only: kubectl plugin, no MCP surface
```
```
pods_list_in_namespace(namespace="kube-system", labelSelector="k8s-app=cilium")
# Check items[].status.phase for Cilium recovery after node reboots.
# Fallback: KUBECONFIG=<kubeconfig> kubectl -n kube-system get pods -l k8s-app=cilium -o wide
```

If recovery requires repo reversion:
- revert only the Talos upgrade change set
- regenerate configs
- validate again
- commit and push the reversion
- follow the approved recovery path for node repair or rollback

Do not improvise a downgrade or reset flow unless the approved plan explicitly covers it.

### 11. Final verification
Do not declare success until the target state is verified.

Run `/cluster-health-snapshot` for a structured 5-layer health check (Talos, K8s, Cilium, LINSTOR, PKI):
```
/cluster-health-snapshot
```

Confirm in addition to the snapshot output:
- live Talos version equals approved `to_version` on every node
- repo pin equals approved `to_version`
- etcd is healthy with 3 voters and 0 learners
- all nodes are Ready
- any coupled Kubernetes or Cilium steps from the plan are complete

Capture both the cluster-health-snapshot output and the final verification in the run record.

## Output
Return a concise execution summary with:
- approved plan path
- versions executed
- repo changes made
- rollout sequence used
- final health status
- any incidents or remaining risks
- path to the execution record

## Hard Rules
- On Kubernetes MCP tool failure: retry once, then run the `# Fallback:` kubectl command from the same step. Applies to all `mcp__kubernetes-mcp-server__*` calls in this skill.
- Never execute without an approved plan artifact that matches the planning skill’s output contract.
- Never execute a plan whose frontmatter approval fields are missing or still set to `draft`.
- Never skip the “state still matches plan” check.
- Never parallelize node upgrades.
- Never use VIP-based shortcuts where direct node endpoints are required for safety.
- Never continue past a defined stop condition.
- Never hide drift, failed checks, or partial rollout state in the final output.
