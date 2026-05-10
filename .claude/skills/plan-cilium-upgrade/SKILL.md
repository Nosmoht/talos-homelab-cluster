---
name: plan-cilium-upgrade
description: Build a repo-specific Cilium upgrade and migration plan for this homelab cluster by resolving current and target versions, reading all intermediate release notes, identifying breaking changes and risks, and reviewing the plan before presenting it.
argument-hint: [from-version] [to-version]
allowed-tools: Bash, Read, Grep, Glob, Write, WebSearch, WebFetch, Agent, mcp__talos__talos_version, mcp__talos__talos_health, mcp__kubernetes-mcp-server__resources_get, mcp__kubernetes-mcp-server__resources_list, mcp__kubernetes-mcp-server__pods_list_in_namespace
---

# Plan Cilium Upgrade

## Environment Setup

Read `cluster.yaml` to load cluster-specific values (node IPs, kubeconfig path, overlay name).
If the file is missing, tell the user: "Copy `cluster.yaml.example` to `cluster.yaml` and fill in your cluster details."

Use throughout this skill:
- `KUBECONFIG=<kubeconfig>` for all `kubectl` commands
- Node inventory from `nodes.control_plane`, `nodes.workers`, `nodes.gpu_workers`

Use this skill when asked to plan a Cilium upgrade for this cluster. This skill produces a migration plan only. It does not roll out the upgrade unless the user explicitly asks for execution afterward.

## Inputs
- Optional `from-version`
- Optional `to-version`

Argument handling:
- two arguments: treat them as `from-version` then `to-version`
- one argument: treat it as `to-version`; resolve `from-version` from the running cluster
- zero arguments: resolve both versions automatically

Examples:
```text
plan-cilium-upgrade 1.18.3 1.19.0
plan-cilium-upgrade 1.19.2   # interpreted as to-version
plan-cilium-upgrade
```

## Bash Usage Constraints
This skill is read-only. For live Talos-layer queries, prefer MCP tools over CLI:
- `talos_version(nodes=[...])` — live Talos version (preferred over `talosctl version`)
- `talos_health(nodes=[...])` — cluster health check (preferred over `talosctl health`)
- `curl` / `wget` — fetching upstream release metadata
- `git log` / `git diff` / `git status` — repo history
- Cilium live state: use `resources_get` / `resources_list` / `pods_list_in_namespace` MCP tools (see §2, §7 below)
- `talosctl apply-config ... --dry-run` — validation only (no MCP equivalent; CLI only — B2)
Do NOT run any mutating commands during planning.

## Repository Facts You Must Respect
- Cilium is bootstrap-managed from `kubernetes/bootstrap/cilium/cilium.yaml`.
- Talos control plane nodes consume that manifest through `talos/patches/controlplane.yaml` `extraManifests`.
- Version intent is pinned in `talos/versions.mk` as `CILIUM_VERSION := ...`.
- Do not propose `kubectl apply` for Argo CD-managed rollout work.
- Do not propose ad-hoc `kubectl apply` drift fixes for `kubernetes/bootstrap/cilium/cilium.yaml`; reconcile through the Talos workflow.

## Required Outcome
Produce a comprehensive upgrade plan that includes:
1. resolved source and target versions, with how each was determined
2. all intermediate Cilium releases in semver order
3. a concise summary of important changes per release
4. breaking changes, deprecations, default flips, and migration actions
5. cluster-specific impact analysis for this repo and runtime
6. a staged execution plan with validation and rollback considerations
7. explicit risks, blockers, and open questions
8. a self-review section performed before the final plan is presented
9. a saved plan file under `docs/` with approval metadata initialized to `draft`

### Example Output Fragment
```markdown
### Version Resolution
- **From:** v1.15.3 (cluster) / v1.15.3 (repo pin) — no drift
- **To:** v1.16.1 (latest stable)
- **Hop:** 1.15 → 1.16 (single minor, valid)

### Breaking Changes
| Release | Change | Cluster Impact | Action Required |
|---------|--------|---------------|-----------------|
| v1.16.0 | Deprecated `--enable-legacy-host-routing` | Using kube-proxy replacement — affected | Update bootstrap values before upgrade |
```

## Workflow

### 1. Load repo context first
Read at minimum:
- `AGENTS.md`
- `README.md`
- `talos/versions.mk`
- `talos/patches/controlplane.yaml`
- `.claude/rules/cilium-gateway-api.md`
- `docs/day2-operations.md`

Then inspect the current bootstrap manifest:
- `kubernetes/bootstrap/cilium/cilium.yaml`

Extract and record:
- repo-pinned Cilium version from `talos/versions.mk`
- whether the bootstrap manifest embeds chart/image labels that imply a different version
- enabled Cilium features that increase upgrade risk, including:
  - Gateway API / Envoy
  - Hubble
  - kube-proxy replacement / socket LB / routing mode
  - L2 announcements, LB IPAM, BGP, or external IP features
  - encryption, ClusterMesh, local redirect, host firewall, CNI chaining, or any non-default datapath modes
- any repo-managed `cilium.io/*` resources outside the bootstrap manifest

Search for Cilium dependencies and managed resources with `rg` before writing the plan.

### 1.5. Research prior knowledge and upstream changes

Before starting web research, check for prior experience and external intelligence:

0. **Check KB for existing research first:**
   Before any web research or doc scanning, run:
   ```
   kb.search("<from-version> <to-version> cilium upgrade")
   kb.search("cilium <to-version> breaking changes gateway api")
   ```
   If the KB returns recent (<30 days), grounded results covering the target version's breaking changes, eBPF datapath changes, and Gateway API behavior, use those findings directly and skip or reduce web research scope. After completing research, persist novel findings via `kb.create_source` and `kb.create_memo` so future upgrade plans can reuse them.

1. **Search existing docs for prior upgrade experience:**
   - Grep `docs/` for `cilium.*<target-version>` and related terms (postmortems, upgrade reports, debug logs)
   - Read any matching files to extract lessons learned
   - Check AGENTS.md §Hard Constraints for Cilium/Gateway API version-specific warnings

2. **Spawn the `researcher` agent for upstream intelligence:**

   > **Note (GitHub #10061 — Subagent Skill Scope Shadowing):** Subagents spawned via the
   > Agent tool cannot access `references/` files relative to the parent skill's directory.
   > Work around this by (a) passing the absolute path so the subagent can Read it directly,
   > and (b) inlining the load-bearing constraints into the spawn prompt.

   Before spawning, read the constraints file yourself:
   ```
   Read(".claude/skills/plan-cilium-upgrade/references/cilium-upgrade-constraints.md")
   ```
   Then spawn the `researcher` agent with this prompt (substitute resolved versions and the
   absolute repo path for `<repo-root>`):
   ```
   Research Cilium <from-version> to <to-version>: eBPF datapath changes,
   Gateway API behavioral changes, NetworkPolicy enforcement changes,
   embedded Envoy updates, macvlan interaction issues, known regressions
   on GitHub. Check Kubernetes version compatibility matrix.

   This repo's cluster constraints (read <repo-root>/.claude/skills/plan-cilium-upgrade/references/cilium-upgrade-constraints.md
   for the full list; key points inlined below):
   - Cilium supports only consecutive minor upgrades (e.g. 1.15→1.16, not 1.15→1.17).
     Multi-minor hops require a staged path. Flag any violation.
   - Never use --reuse-values when upgrading Cilium Helm charts; always diff and pass
     explicit values.
   - Run `cilium preflight check` before the upgrade.
   - Kubernetes compatibility matrix: https://docs.cilium.io/en/stable/network/kubernetes/compatibility/

   Cluster topology: Cilium WireGuard strict mode, hostNetwork Envoy (Gateway API),
   macvlan ingress-front on physical interface (LAN only), DRBD/LINSTOR storage (ports 7000-7999),
   NVIDIA GPU node (r8152 USB NIC). node-pi-01 (arm64) is the sole WAN entrypoint since
   2026-04-17 (hostNetwork nginx stream; FritzBox port-forward direct to Pi NIC) — any
   Cilium agent restart or hostNetwork Envoy reload on Pi is a WAN event. Flag any upstream
   change that interacts with these.

   Return max 2000 tokens: Sources, Findings, Confidence.
   ```
   Wait for the researcher to return before proceeding.

3. **Incorporate findings** into Steps 5-6 (release notes and cluster-specific impact analysis). Pay special attention to any findings about L7 filter behavior changes, DRBD port range conflicts (7000-7999), or macvlan eBPF interactions.

### 2. Resolve `from-version`
If `from-version` was provided, normalize it to `major.minor.patch` and use it.

If omitted, resolve in this order:
1. query the running cluster for the deployed Cilium version
2. compare that result with `talos/versions.mk`
3. if they differ, treat that as drift and include it as a first-class risk
4. if the cluster is unreachable, fail closed instead of guessing, unless the user explicitly allows repo-only planning

Preferred live checks:
```
resources_get(apiVersion="apps/v1", kind="DaemonSet", name="cilium", namespace="kube-system")
# Read .spec.template.spec.containers[0].image for the daemonset image tag.
# Fallback: KUBECONFIG=<kubeconfig> kubectl -n kube-system get ds cilium -o json

resources_get(apiVersion="apps/v1", kind="Deployment", name="cilium-operator", namespace="kube-system")
# Read .spec.template.spec.containers[0].image for the operator image tag.
# Fallback: KUBECONFIG=<kubeconfig> kubectl -n kube-system get deploy cilium-operator -o json

resources_get(apiVersion="v1", kind="ConfigMap", name="cilium-config", namespace="kube-system")
# Read .data for current Cilium configuration values.
# Fallback: KUBECONFIG=<kubeconfig> kubectl -n kube-system get cm cilium-config -o yaml
```
```bash
KUBECONFIG=<kubeconfig> cilium version
```

Use the daemonset image tag or `cilium version` output as the primary source. Do not rely only on labels.

### 3. Resolve `to-version`
If `to-version` was provided, normalize it to `major.minor.patch` and use it.

If omitted:
1. query `https://github.com/cilium/cilium/releases` or the GitHub releases API
2. choose the latest stable release
3. exclude pre-releases and release candidates
4. if multiple stable artifacts exist, pick the highest semantic version

Record the exact release URL used for the decision.

### 4. Validate the version hop
Before reading release notes, check:
- `from-version` exists and is not newer than `to-version`
- no downgrade is being planned
- whether the hop crosses one or more minor versions — **if the hop spans more than one minor version**, flag this explicitly. Cilium only supports consecutive minor releases for upgrade and rollback. Recommend a staged path (e.g., 1.16 → 1.17 → 1.18). See `references/cilium-upgrade-constraints.md`.
- whether the hop crosses a major version
- whether the repo’s Talos and Kubernetes versions are compatible with the target Cilium release (see compatibility matrix in `references/cilium-upgrade-constraints.md`)

At minimum, inspect Cilium’s documented compatibility notes for:
- supported Kubernetes versions
- kernel, eBPF, Envoy, and Hubble caveats
- Gateway API support changes

If the user requested a large skip, call that out explicitly and consider recommending a staged upgrade path if upstream guidance suggests it.

### 5. Read every intermediate release note
Read the release notes for every version `> from-version` and `<= to-version`.

Rules:
- include patch releases, not only minors
- use semver sorting
- prefer GitHub release notes plus linked upgrade or migration guides when referenced
- if a release note points to a dedicated upgrade guide, read that guide too
- track source links for every non-trivial claim

Capture per release:
- new requirements or compatibility windows
- breaking changes
- deprecated and removed flags, Helm values, CRDs, APIs, annotations, and metrics
- data-plane, control-plane, and observability changes
- operational prerequisites and post-upgrade actions

### 6. Perform cluster-specific impact analysis
Do not stop at upstream notes. Map them onto this repo and live cluster.

Check at least:
- Cilium feature flags in `kubernetes/bootstrap/cilium/cilium.yaml`
- Talos-managed bootstrap coupling through `extraManifests`
- Gateway API resources under `kubernetes/**/gateway-api/**`
- Hubble dashboards, ServiceMonitors, and policy-debug workflows in docs and manifests
- any `CiliumNetworkPolicy`, `CiliumClusterwideNetworkPolicy`, `CiliumLoadBalancerIPPool`, `CiliumL2AnnouncementPolicy`, `GatewayClass`, `Gateway`, `HTTPRoute`, or Envoy-related resources
- whether the running cluster has objects or flags that no longer exist in the target version
- whether the repo pins chart fields that changed semantics upstream

Also check for upgrade blast radius:
- control plane reachability during CNI restart
- service VIP continuity and Gateway API ingress disruption
- policy enforcement regressions
- Hubble relay or UI version skew
- metrics/dashboards/query drift

### 7. Build the migration plan
The plan must be execution-ready and ordered.

Include these sections:
- `Version Resolution`
- `Intermediate Releases Reviewed`
- `Cluster-Specific Findings`
- `Breaking Changes and Required Migrations`
- `Execution Plan`
- `Validation Plan`
- `Rollback and Recovery`
- `Risks and Open Questions`
- `Self-Review`

The execution plan must cover:
1. preflight checks (including `cilium preflight check` — see `references/cilium-upgrade-constraints.md`)
2. repo changes required before rollout — **never use `--reuse-values` when upgrading Cilium Helm charts** (silently drops new required values; see constraints reference)
3. validation of rendered manifests
4. commit/push expectations
5. node or cluster upgrade sequencing through the Talos workflow when required
6. post-upgrade verification
7. contingency actions

Use repo-accurate commands where relevant, for example:
```bash
make -C talos cilium-bootstrap
make -C talos cilium-bootstrap-check
make -C talos gen-configs
# Dry-run per node (CLI-only for planning skills — B2: no mutating MCP tools in plan skills)
for each node: talosctl apply-config -n <node-ip> -e <node-ip> -f talos/generated/<role>/<node>.yaml --dry-run
# Reconcile extraManifests (ensure cilium-bootstrap-check passed first — CLI-only: no MCP equivalent)
talosctl upgrade-k8s --to <kubernetes-version> -n <cp-node-1-ip> -e <cp-node-1-ip>
```
```
# Apply config per node (execute-cilium-upgrade uses MCP):
talos_apply_config(config_file="<abs-path>/talos/generated/<role>/<node>.yaml", dry_run=false, confirm=true, nodes=["<node-ip>"], mode="auto")
# Upgrade per node (execute-cilium-upgrade uses MCP — fires and returns, poll talos_health):
talos_upgrade(nodes=["<node-ip>"], image="<install-image>", preserve=true, confirm=true)
talos_health(nodes=["<cp-node-ip>"])
```
```
pods_list_in_namespace(namespace="kube-system", labelSelector="k8s-app=cilium")
# Check items[].status.phase — all should be "Running". Read items[].metadata.name for pod names.
# Fallback: KUBECONFIG=<kubeconfig> kubectl -n kube-system get pods -l k8s-app=cilium

resources_list(apiVersion="cilium.io/v2", kind="CiliumNode")
# Check items[].metadata.name and items[].status for node health fields.
# Fallback: KUBECONFIG=<kubeconfig> kubectl get ciliumnode
```

If the version bump changes `CILIUM_VERSION`, require the plan to address:
- regeneration of `kubernetes/bootstrap/cilium/cilium.yaml` via `make -C talos cilium-bootstrap`
- validation via `make -C talos cilium-bootstrap-check`
- reconciliation of Talos `extraManifests` state through `talosctl upgrade-k8s` (ensure `make -C talos cilium-bootstrap-check` passed first)

Do not imply that editing `kubernetes/bootstrap/cilium/cilium.yaml` alone completes rollout.

### 8. Include rollback and safety constraints
Always address:
- whether downgrade is supported or effectively unsupported
- how to preserve a copy of the pre-upgrade bootstrap manifest and repo version pin
- what health signals must be green before moving to the next node
- what to do if Cilium pods do not recover, Gateway traffic fails, or policy drops spike
- whether Talos node-by-node progression is required

Never recommend a rollback path that depends on direct apply drift against repo-owned steady state without making that tradeoff explicit.

### 9. Review before presenting
Critically review the draft plan before returning it.

Review checklist:
- every version between source and target was covered
- target release is truly stable, not RC or beta
- live cluster version and repo pin were compared
- Kubernetes and Talos compatibility were checked
- upgrade risks were mapped to this cluster’s enabled Cilium features
- commands align with this repo’s GitOps and Talos operating model
- no step relies on forbidden practices from `AGENTS.md`
- every major recommendation has at least one cited upstream source
- blockers and unknowns are explicit rather than hidden

If the review finds gaps, fix them before presenting the final plan. Do not present the unreviewed draft.

### 9.5. Adversarial risk assessment

Before presenting the plan, stress-test it through an adversarial lens:

1. **Breaking change failure scenarios** — For each breaking change, describe what happens if the migration step is missed. Focus on: Gateway API traffic loss, CiliumNetworkPolicy enforcement regressions, Hubble relay disruption.
2. **Blast radius estimation** — For each risk, classify:
   - **Node:** affects connectivity on one node (e.g., agent restart)
   - **Control plane:** affects kube-proxy replacement or API server reachability
   - **Full cluster:** affects all east-west or north-south traffic (e.g., eBPF map incompatibility)
3. **Most dangerous step** — Identify the single most dangerous step. For Cilium upgrades, this is typically the bootstrap manifest reconciliation via `talosctl upgrade-k8s`. Ensure rollback is possible (previous manifest preserved, `extraManifests` URL revertible).
4. **Mid-rollout interruption** — Can the cluster operate with mixed Cilium versions across nodes? Document the supported version skew window.
5. **Macvlan + Envoy interaction** — Specifically assess: does this upgrade change eBPF L7 filter behavior, hostNetwork Envoy port binding, or macvlan-to-remote-node routing? These are the highest-risk areas for this cluster.
6. **Unmitigated risks** — Flag as `BLOCKING — requires operator decision` if no mitigation exists.

### 10. Save the reviewed plan as a draft artifact
After the plan passes self-review, write it to:
- `docs/cilium-upgrade-plan-<from-version>-to-<to-version>-<yyyy-mm-dd>.md`

The file must begin with this frontmatter shape:
```yaml
---
plan_source: plan-cilium-upgrade
from_version: <from-version>
to_version: <to-version>
generated_at: <yyyy-mm-dd>
status: draft
approved_by:
approved_at:
---
```

Rules:
- `status` must be `draft` when the planning skill writes the file
- never mark the plan as approved automatically
- `approved_by` and `approved_at` must be left empty by the planning skill
- the body below the frontmatter must contain the reviewed plan using the required output sections

### 11. Tell the operator how to approve the plan
At the end of the response, instruct the operator to approve the plan by manually editing the frontmatter in the saved file:
```yaml
status: approved
approved_by: <operator-name>
approved_at: <yyyy-mm-dd>
```

Do not treat chat approval as sufficient. The approval lives in the plan file.

## Output Format
Write the reviewed plan file first, then present a concise summary in chat.

The saved plan file must contain these sections (matching the required plan structure):
- `Version Resolution`
- `Intermediate Releases Reviewed`
- `Cluster-Specific Findings`
- `Breaking Changes and Required Migrations`
- `Execution Plan`
- `Validation Plan`
- `Rollback and Recovery`
- `Risks and Open Questions`
- `Self-Review`

For `Reviewed Releases`, list each version with source links.

For `Self-Review`, state:
- what was checked
- what was uncertain
- whether the plan is safe to execute as written or needs more investigation

In the chat response, also include:
- the saved plan path
- that the plan is currently `draft`
- the exact frontmatter fields the operator must edit to approve it

## Hard Rules

On Kubernetes MCP tool failure: retry once, then run the `# Fallback:` kubectl command from the same step. Applies to all `mcp__kubernetes-mcp-server__*` calls in this skill.

## Failure Modes
- If cluster access is required to resolve `from-version` and it is unavailable, state that clearly and stop unless the user accepts repo-only planning.
- If GitHub release information cannot be retrieved, do not guess the target version.
- If the repo or running cluster shows unsupported skew, elevate that to a blocker.
- If the release notes are incomplete, say what was missing and what source was used instead.
