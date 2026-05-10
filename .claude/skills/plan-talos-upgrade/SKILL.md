---
name: plan-talos-upgrade
description: Build a repo-specific Talos upgrade and migration plan for this homelab cluster by resolving current and target Talos versions, reading all intermediate release notes and upgrade guidance, identifying cluster-specific risks, and saving a reviewed draft plan for manual approval.
argument-hint: [from-version] [to-version]
allowed-tools: Bash, Read, Grep, Glob, Write, WebSearch, WebFetch, Agent, mcp__talos__talos_version, mcp__talos__talos_health, mcp__talos__talos_etcd, mcp__talos__talos_get, mcp__talos__talos_validate, mcp__kubernetes-mcp-server__pods_list_in_namespace
---

# Plan Talos Upgrade

## Environment Setup

Read `cluster.yaml` to load cluster-specific values (node IPs, kubeconfig path, cluster name).
If the file is missing, tell the user: "Copy `cluster.yaml.example` to `cluster.yaml` and fill in your cluster details."

Use throughout this skill:
- `-n <node-ip> -e <node-ip>` for all `talosctl` commands targeting a node
- Node inventory from `nodes.control_plane`, `nodes.workers`, `nodes.gpu_workers`, `nodes.pi_nodes`

Use this skill when asked to plan a Talos upgrade for this cluster. This skill produces a migration plan only. It does not upgrade nodes unless the user explicitly asks for execution afterward.

## Inputs
- Optional `from-version`
- Optional `to-version`

Argument handling:
- two arguments: treat them as `from-version` then `to-version`
- one argument: treat it as `to-version`; resolve `from-version` from the running cluster
- zero arguments: resolve both versions automatically

Examples:
```text
plan-talos-upgrade 1.12.4 1.12.6
plan-talos-upgrade 1.13.0   # interpreted as to-version
plan-talos-upgrade
```

## Bash Usage Constraints
This skill is read-only. For live cluster queries, prefer MCP tools over CLI:
- `talos_version(nodes=[...])` — live Talos version (preferred over `talosctl version`)
- `talos_health(nodes=[...])` — cluster health check
- `talos_etcd(subcommand="members"|"status", nodes=[...])` — etcd quorum
- `talosctl apply-config ... --dry-run` — validation only (no MCP equivalent; CLI only — B2)
- `talosctl validate --config <file> --mode metal --strict` — offline validation (CLI only)
- `curl` / `wget` — fetching upstream release metadata
- `git log` / `git diff` / `git status` — repo history
Do NOT run any mutating commands (`talosctl upgrade`, `talosctl apply-config` without `--dry-run`, `kubectl drain`, `kubectl delete`) during planning.

## Repository Facts You Must Respect
- Talos version intent is pinned in `talos/versions.mk` as `TALOS_VERSION := ...`.
- Node install images are derived from `talos/.schematic-ids.mk` and `TALOS_VERSION` in `talos/Makefile`.
- Cluster-wide Talos upgrades run one node at a time through direct `talosctl apply-config` + `talosctl upgrade` commands.
- Changes to boot args or extensions may require `make -C talos schematics` before node upgrades.
- `talosctl apply-config --dry-run` and manual operations must use explicit node endpoints, not the VIP, when reliability matters.
- Do not edit `talos/generated/**` directly.
- Do not mix Talos upgrades with unrelated repo changes.

## Required Outcome
Produce a comprehensive upgrade plan that includes:
1. resolved source and target Talos versions, with how each was determined
2. all intermediate Talos releases in semver order
3. a concise summary of important changes per release
4. breaking changes, migration requirements, deprecations, and operator actions
5. cluster-specific impact analysis for this repo, hardware mix, and runtime
6. a staged execution plan with validation, sequencing, and recovery considerations
7. explicit risks, blockers, and open questions
8. a self-review section performed before the final plan is presented
9. a saved plan file under `docs/` with approval metadata initialized to `draft`

## Workflow

### 1. Load repo context first
Read at minimum:
- `AGENTS.md`
- `README.md`
- `docs/day2-operations.md`
- `talos/Makefile`
- `talos/versions.mk`
- `talos/patches/common.yaml`
- `talos/patches/controlplane.yaml`
- `talos/patches/worker-gpu.yaml`
- `talos/talos-factory-schematic.yaml`
- `talos/talos-factory-schematic-gpu.yaml`
- `talos/talos-factory-schematic-pi.yaml`

Search for Talos-sensitive features and operational dependencies with `rg` before writing the plan.

Extract and record:
- repo-pinned Talos version from `talos/versions.mk`
- Kubernetes and Cilium versions pinned alongside Talos
- node inventory, roles, and upgrade order from `talos/Makefile` and docs
- whether current patches imply install image, kernel argument, or extension changes
- whether any schematic files or patch files changed semantics across the target version hop
- whether `talos/patches/controlplane.yaml` `extraManifests` cache-busting behavior introduces coupled Cilium work
- operational constraints around DRBD, GPU node handling, Pi node handling, and control-plane health

### 1.5. Research prior knowledge and upstream changes

Before starting web research, check for prior experience and external intelligence:

0. **Check KB for existing research first:**
   Before any web research or doc scanning, run:
   ```
   kb.search("<from-version> <to-version> talos upgrade")
   kb.search("talos <to-version> breaking changes")
   ```
   If the KB returns recent (<30 days), grounded results covering the target version's breaking changes and compatibility notes, use those findings directly and skip or reduce web research scope. After completing research, persist novel findings via `kb.create_source` and `kb.create_memo` so future upgrade plans can reuse them.

1. **Search existing docs for prior upgrade experience:**
   - Grep `docs/` for `talos.*<target-version>` and related terms (postmortems, upgrade reports, maintenance logs)
   - Read any matching files to extract lessons learned
   - Check AGENTS.md §Hard Constraints for version-specific warnings

2. **Spawn the `researcher` agent for upstream intelligence:**

   > **Note (GitHub #10061 — Subagent Skill Scope Shadowing):** Subagents spawned via the
   > Agent tool cannot access files relative to the parent skill's directory. Work around
   > this by inlining the load-bearing cluster constraints into the spawn prompt directly.
   > Read AGENTS.md §Hard Constraints and §Cluster Overview before spawning to extract
   > the current values.

   Use the Agent tool to spawn the `researcher` agent with subagent_type "researcher" (or
   general-purpose with the researcher persona) and this prompt (substitute resolved versions):
   ```
   Research Talos <from-version> to <to-version>: breaking changes, extension
   compatibility with DRBD/LINSTOR and NVIDIA, known issues on GitHub, CVE
   advisories. Check Talos and Kubernetes version compatibility matrix.

   This repo's cluster constraints (inlined from AGENTS.md §Hard Constraints):
   - NEVER use metal-installer-secureboot — causes boot loops; always metal-installer.
   - NEVER set debugfs=off — causes "failed to create root filesystem" boot loop.
   - Cluster uses Cilium WireGuard strict mode, hostNetwork Envoy (Gateway API),
     macvlan ingress-front (LAN only), DRBD/LINSTOR storage (DRBD 9 kernel module extension).
   - node-pi-01 (Raspberry Pi 4B, arm64) is the **sole WAN entrypoint** since 2026-04-17:
     hostNetwork nginx stream pod, FritzBox port-forwards TCP/443 directly to the Pi's
     NIC. Any node-pi-01 reboot or Talos upgrade is a WAN outage event — flag it.
   - GPU node (node-gpu-01) uses r8152 USB NIC and nvidia-container-toolkit extension.
   - Pi nodes require separate schematic (no GPU/DRBD extensions).
   - Talos extensions in use: drbd, nvidia-container-toolkit. Flag any extension API or
     schematic changes in the target version that affect these.
   - Kubernetes version pinned in talos/versions.mk — flag any k8s compatibility window
     the Talos target version imposes.

   Return max 2000 tokens: Sources, Findings, Confidence.
   ```
   Wait for the researcher to return before proceeding.

3. **Incorporate findings** into Steps 5-6 (release notes and cluster-specific impact analysis). Flag any researcher finding that contradicts upstream release notes.

### 2. Resolve `from-version`
If `from-version` was provided, normalize it to `major.minor.patch` and use it.

If omitted, resolve in this order:
1. query the running cluster for the deployed Talos version
2. compare that result with `talos/versions.mk`
3. if they differ, treat that as drift and include it as a first-class risk
4. if the cluster is unreachable, fail closed instead of guessing, unless the user explicitly allows repo-only planning

Preferred live checks — use control-plane node IPs from `cluster.yaml`:
```
talos_version(nodes=["<cp-node-1-ip>", "<cp-node-2-ip>", "<cp-node-3-ip>"])
# Fallback: talosctl -n <cp-node-1-ip> -e <cp-node-1-ip> version
```
```bash
kubectl get nodes -o wide
# ^ CLI-Only: token-negative; see .claude/rules/kubernetes-mcp-first.md §CLI-Only
```

Use `talosctl version` against at least one control-plane node as the primary source. If nodes differ, record the skew and stop treating the cluster as a clean baseline.

### 3. Resolve `to-version`
If `to-version` was provided, normalize it to `major.minor.patch` and use it.

If omitted:
1. resolve the latest stable Talos release from the upstream releases page or API
2. exclude pre-releases and release candidates
3. if multiple stable artifacts exist, pick the highest semantic version

Record the exact release URL used for the decision.

### 4. Validate the version hop
Before reading release notes, check:
- `from-version` exists and is not newer than `to-version`
- no downgrade is being planned
- whether the hop crosses one or more minor versions
- whether the hop crosses a major version
- whether the target Talos release supports the repo’s target Kubernetes version
- whether Cilium or bootstrap workflows are coupled to the Talos hop

At minimum, inspect upstream compatibility and upgrade guidance for:
- supported Kubernetes versions
- changed kernel, containerd, kubelet, or bootstrap behaviors
- changed image factory, schematic, or extension mechanics
- changed config schema or deprecated machine configuration fields
- upgrade-order constraints for control-plane nodes and etcd

If the user requested a large skip, call that out explicitly and recommend a staged path if upstream guidance suggests it.

### 5. Read every intermediate release note
Read the release notes and upgrade notes for every version `> from-version` and `<= to-version`.

Rules:
- include patch releases, not only minors
- use semver sorting
- prefer upstream Talos release notes plus linked migration or upgrade docs
- if a release note points to a dedicated upgrade guide, read that guide too
- track source links for every non-trivial claim

Capture per release:
- new requirements or compatibility windows
- breaking changes and changed defaults
- deprecated or removed config fields, flags, extensions, or commands
- changes affecting machine config generation or install images
- changes affecting reboot behavior, etcd, kubelet, networking, or observability
- operational prerequisites and post-upgrade actions

### 6. Perform cluster-specific impact analysis
Do not stop at upstream notes. Map them onto this repo and live cluster.

Check at least:
- `talos/versions.mk`
- `talos/Makefile` image construction and node ordering
- schematic files for standard, GPU, and Pi nodes
- Talos patch files that may interact with version-specific schema or defaults
- control-plane patch coupling to Kubernetes, Cilium, Gateway API, and observability
- whether `talos/patches/controlplane.yaml` `extraManifests` URLs or `?v=` query parameters need coordinated updates
- repo-documented gotchas around DRBD shutdown hangs, etcd recovery, CSR approval, and direct endpoint requirements

Also check for upgrade blast radius:
- etcd quorum loss during control-plane upgrade
- CNI and API reachability after control-plane and worker reboots
- DRBD-backed storage risk during node reboots
- GPU or Pi node image path divergence
- kubelet CSR or bootstrap token issues after reboot
- generated config drift caused by version variable changes

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
1. preflight checks, including:
   - etcd snapshot: `talos_etcd_snapshot(nodes=["<cp-node-ip>"], path="/tmp/etcd-backup-<date>.snapshot")`
   - verify snapshot file size is non-zero before proceeding
   - confirm `talosctl version --client` matches or exceeds the target Talos version (CLI-only)
2. repo changes required before rollout
3. config generation and validation
4. commit/push expectations
5. node-by-node upgrade sequencing
6. per-node and per-stage verification
7. contingency actions and stop conditions

Use repo-accurate commands where relevant, for example:
```bash
make -C talos schematics
make -C talos gen-configs
# Validate generated configs (CLI — no MCP equivalent for file-based validation)
find talos/generated -type f -name '*.yaml' | sort | while read f; do talosctl validate --config "$f" --mode metal --strict; done
# Dry-run per node (CLI-only for planning skills — B2: no mutating MCP tools in plan skills)
talosctl apply-config -n <node-ip> -e <node-ip> -f talos/generated/<role>/<node>.yaml --dry-run
```
```
# Apply config per node (execute-talos-upgrade uses MCP):
talos_apply_config(config_file="<abs-path>/talos/generated/<role>/<node>.yaml", dry_run=false, confirm=true, nodes=["<node-ip>"], mode="auto")
# Upgrade per node (execute-talos-upgrade uses MCP — fires and returns, poll talos_health):
talos_upgrade(nodes=["<node-ip>"], image="<install-image>", preserve=true, confirm=true)
talos_health(nodes=["<cp-node-ip>"])
```
```bash
kubectl get nodes -o wide
# ^ CLI-Only: token-negative (no selector); see .claude/rules/kubernetes-mcp-first.md §CLI-Only
kubectl linstor node list
# ^ CLI-Only: kubectl plugin, no MCP surface
```
```
pods_list_in_namespace(namespace="kube-system", labelSelector="k8s-app=cilium")
# Check items[].status.phase — all should be "Running". Read items[].metadata.name for pod names.
# Fallback: KUBECONFIG=<kubeconfig> kubectl -n kube-system get pods -l k8s-app=cilium
```

Require the plan to address:
- whether `TALOS_VERSION` alone changes, or whether Kubernetes/Cilium/schematics also change
- whether `make -C talos schematics` is required before config generation
- whether coupled Cilium work requires updating `talos/patches/controlplane.yaml` `?v=` and re-rendering bootstrap Cilium manifests
- control-plane node upgrade order (from `nodes.control_plane` in cluster.yaml)
- worker node upgrade order: standard workers first, then GPU workers, then Pi nodes (from cluster.yaml)
- health gates before proceeding to the next node

### 8. Include rollback and safety constraints
Always address:
- whether downgrade is supported, unsupported, or materially risky
- how to preserve the pre-upgrade repo version pins and schematic IDs
- what health signals must be green before moving to the next node
- what to do if a node is stuck shutting down, fails to rejoin etcd, or loses networking
- what to do if kubelet CSR approval or Cilium recovery blocks readiness

Never pretend rollback is symmetric if it requires disruptive re-imaging, reset flows, or other exceptional recovery.

### 9. Review before presenting
Critically review the draft plan before returning it.

Review checklist:
- every version between source and target was covered
- target release is truly stable, not RC or beta
- live cluster version and repo pin were compared
- Kubernetes compatibility and coupled version impacts were checked
- upgrade risks were mapped to this cluster’s hardware, storage, and control-plane topology
- commands align with this repo’s Talos and GitOps operating model
- no step relies on forbidden practices from `AGENTS.md`
- every major recommendation has at least one cited upstream source
- blockers and unknowns are explicit rather than hidden

If the review finds gaps, fix them before presenting the final plan. Do not present the unreviewed draft.

### 9.5. Adversarial risk assessment

Before presenting the plan, stress-test it through an adversarial lens:

1. **Breaking change failure scenarios** — For each breaking change identified, describe what happens if the migration step is missed or executed incorrectly. Be specific: "If X is not done, then Y breaks because Z."
2. **Blast radius estimation** — For each cluster-specific risk, classify blast radius:
   - **Node:** affects one node only (e.g., GPU extension mismatch)
   - **Control plane:** affects etcd quorum or API server availability
   - **Full cluster:** affects all workloads (e.g., CNI incompatibility, storage mesh failure)
3. **Most dangerous step** — Identify the single most dangerous step in the execution plan. Ensure its rollback path is explicit, tested, and does not require the step itself to have succeeded.
4. **Mid-rollout interruption** — What happens if the upgrade is interrupted after node N of 8? Is the cluster in a valid mixed-version state? Can it serve traffic? Can the upgrade resume?
5. **Unmitigated risks** — If any risk has no mitigation path, flag it as `BLOCKING — requires operator decision` and do not mark the plan as ready.

### 10. Save the reviewed plan as a draft artifact
After the plan passes self-review, write it to:
- `docs/talos-upgrade-plan-<from-version>-to-<to-version>-<yyyy-mm-dd>.md`

The file must begin with this frontmatter shape:
```yaml
---
plan_source: plan-talos-upgrade
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
- If upstream release information cannot be retrieved, do not guess the target version.
- If the repo or running cluster shows unsupported skew, elevate that to a blocker.
- If the release notes are incomplete, say what was missing and what source was used instead.
