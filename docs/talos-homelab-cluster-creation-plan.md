# Plan — Create `talos-homelab-cluster` Repo from `Talos-Homelab` Snapshot

**Status**: Ready for execution (after `talos-platform-base` v0.1.0 OCI artifact exists)
**Created**: 2026-04-29
**Source repo**: `github.com/Nosmoht/Talos-Homelab` (this repo, ref: `main` at commit `0def395` post-PR#157-merge)
**Target repo**: `github.com/Nosmoht/talos-homelab-cluster` (NEW, to be created)
**Depends on**: `talos-platform-base` execution per `docs/talos-platform-base-creation-plan.md` (PR #157 merged), with at least `v0.1.0` tag published as OCI artifact at `ghcr.io/nosmoht/talos-platform-base:v0.1.0`
**ADR reference**: `docs/adr-multi-repo-platform-split.md` §"Phase 3B — New cluster repo creation (non-destructive)"
**Tracking issue**: Talos-Homelab #148 (the existing Phase-3A issue is repurposed under the amended ADR — see §17)

> This plan is **execution-ready** for the current Claude Code session in `Talos-Homelab` cwd. The filter-repo work runs on a throwaway clone of `Talos-Homelab`; the original repo is never modified. The new repo is pushed to a fresh GitHub origin. End-to-end verification happens against a sacrificial test cluster (Phase 3C in the ADR), NOT against the live homelab cluster — the live cluster remains driven by `Talos-Homelab` until a separate Phase 3D issue plans the cutover.

---

## 1. Context

The amended ADR (PR #154) and base-creation plan (PR #157) decided:

- New repo `Nosmoht/talos-homelab-cluster` is created from a `git filter-repo` snapshot of `Talos-Homelab`. Filter keeps **cluster-specific paths**, drops base content (which lives in `talos-platform-base`).
- Day-0 consumption: `make day0` runs `oras pull` of `talos-platform-base:v0.1.0` into a gitignored `vendor/base/` tree, pinned via a single-line `.base-version` file. Top-level Makefile delegates to `vendor/base/Makefile` and `vendor/base/talos/Makefile`.
- Day-2 consumption: existing 34 ArgoCD Applications remain `spec.sources[]` Multi-Source, but the two `Talos-Homelab.git` source URLs split into two distinct repo URLs:
  - `talos-platform-base.git@v0.1.0` for the `$values/kubernetes/base/...` path (helm valueFiles)
  - `talos-homelab-cluster.git@HEAD` for the `kubernetes/overlays/homelab/...` path (cluster overlay values + extra resources)
- AppProjects' `sourceRepos` lists both repo URLs (dual-listing), already required by the existing AppProject pattern.
- A CI drift gate enforces that `.base-version` and `targetRevision` for the base source in every Application stay synchronized.

**Migration is non-destructive.** `Talos-Homelab` continues to drive the live homelab cluster throughout this plan's execution and through Phase 3C verification. The live cutover is filed separately as Phase 3D (Talos-Homelab #155).

## 2. Goal

After execution:
1. `Nosmoht/talos-homelab-cluster` exists on GitHub, public-or-private (homelab is public; office-lab will be private — match existing `Talos-Homelab` visibility = public), with preserved git history for retained paths.
2. `git clone` followed by `make day0` against a sacrificial test cluster (or VM-Talos lab) produces a working ArgoCD-bootstrapped cluster within ~10 minutes wall-clock.
3. All 34 ArgoCD Applications reconcile against the dual-source layout without `ComparisonError` and without manual intervention.
4. CI drift gate `check-base-pin-drift.sh` is green on initial main push.
5. `Talos-Homelab` repo unchanged throughout.

## 3. Source-state pin

Filter-repo runs against `Talos-Homelab` `main` at commit `0def395` (post-PR-#157 merge of the base-creation plan). Verify before starting:

```bash
cd ~/workspace/Talos-Homelab
git fetch origin && git checkout main && git pull --ff-only
git rev-parse HEAD                # expect: 0def395 or later main
```

Snapshot moves forward freely. The path classifications below assume the post-PR-#157 state.

## 4. Content classification (cluster-repo INCLUDE list)

Everything in `Talos-Homelab` falls into one of three buckets relative to this plan:
- **KEEP** — must be in the new cluster repo
- **NEW** — does not exist in source; created post-filter
- **DROP** — covered by the platform-base repo, not duplicated here

### 4.1 KEEP — directly retained from source

| Path | Notes |
|---|---|
| `kubernetes/overlays/homelab/` | All 34 Applications + projects + kustomizations + resources |
| `kubernetes/bootstrap/cilium/cilium.yaml` | 2359-line rendered manifest with cluster-specific Hubble TLS certs |
| `talos/nodes/` | 8 node configs (node-01..06, node-gpu-01, node-pi-01) |
| `talos/patches/pi-firewall.yaml` | FritzBox/Pi-public-ingress firewall rules |
| `talos/secrets.yaml` | SOPS-encrypted cluster secrets bundle |
| `talos/talosconfig` | Cluster-access config |
| `talos/talos-factory-schematic.yaml`, `talos/talos-factory-schematic-gpu.yaml`, `talos/talos-factory-schematic-pi.yaml` | Talos Image Factory inputs (per-cluster schematic IDs) |
| `talos/AGENTS.md` | Cluster-specific operational notes (Phase 1 left it minimal but homelab-relevant) |
| `cluster.yaml.example` | Schema (also kept in base; cluster repo carries its own copy as documentation aid) |
| `cluster.yaml` | Per-cluster, gitignored — does not transfer via filter-repo, but the path is reserved |
| Top-level `AGENTS.md`, `CLAUDE.md`, `README.md` | Rewritten post-filter for cluster perspective (§7.1–7.3) |
| `kubernetes/AGENTS.md` | Trim to homelab-overlay-specific; mention base via plugin-link |
| `policies/conftest/argocd.rego`, `k8s.rego`, `policies/conftest/README.md` | conftest policies — **DROP** (covered by base) — see §4.3 |
| `scripts/configure-sg3428-via-omada-api.sh` | TP-Link switch config |
| `scripts/discover_argocd_apps.sh` | Reads cluster manifests |
| `scripts/run_trivy.sh` | Currently homelab-specific |
| `scripts/issue-state.sh` | DROP (covered by base) — see §4.3 |
| `scripts/mcp-github-wrapper.sh`, `check-mcp-config-portable.sh` | DROP (covered by base) — see §4.3 |
| `.github/workflows/skill-frontmatter-check.yml` | Validates `.claude/skills/` (covers content not yet migrated to plugin per #147) |
| `.github/workflows/sysctl-baseline-check.yml` | Live-cluster sysctl drift detector |
| `.github/workflows/gitops-validate.yml` | DROP-or-KEEP decision (see §4.3.bonus) |
| `.github/workflows/hard-constraints-check.yml` | DROP (covered by base CI) |
| `Plans/` | Working dir, retained transparently |
| `.claude/` | Retained until #147 plugin migration runs (carve-out §4.4) |
| `.codex/` | Retained until #147 plugin migration runs |
| `package.json`, `package-lock.json` | Tooling; retained as-is |
| `tests/` | Empty, retained but no-op |
| All STAY docs from base-plan §5.6 | All `hardware-analysis-*`, `cilium-debug-*`, `cilium-upgrade-*`, `talos-upgrade-*`, `postmortem-*`, runbooks, ADRs (pi/ingress/storage/tenant), `2026-04-15-fritzbox-*`, `kernel-tuning*`, `platform-network-interface.md`, `freeze-learnings.md`, `enterprise-network-blueprint-*`, `kubernetes-review*`, `external-secrets-customer-guide.md`, `agent-harness-audit-prompt.md`, `MOVED-enterprise-blueprint.md`, `linstor-state-pre-migration.txt`, `nic-baseline-*.txt`, `omada-controller-post-config.cfg`, `network-policy-remediation-todo.md`, `plan-pr-2b-drbd-transport-tls.md`, `ui-loadbalancer-ip-plan.md`, `vault-config-operator-pki-migration.md`, `talos-maintenance-*`, `diagnosis-node-*`, `kubevirt-*`, `runbook-*` |

### 4.2 NEW — added post-filter

| Path | Purpose |
|---|---|
| `.base-version` | Single line: `v0.1.0`. Source-of-truth for which base tag the repo pins. |
| `.gitignore` (extension) | Add `vendor/base/`, `_release/` if not already present |
| `scripts/bootstrap-base.sh` | `oras pull` driver: reads `.base-version`, fetches OCI artifact, extracts to `vendor/base/`, locks read-only |
| `scripts/check-base-pin-drift.sh` | CI gate: cross-checks `.base-version` against every `targetRevision` for the base source in `kubernetes/overlays/homelab/**/application.yaml` |
| `Makefile` (top-level rewrite) | Thin delegator: `bootstrap-base`, `gen-configs`, `apply`, `argocd-install`, `argocd-bootstrap`, `day0` meta-target |
| `talos/patches/controlplane.yaml` (cluster-overlay version) | Full `extraManifests:` block: gateway-api upstream URL + cluster-rendered cilium.yaml URL |
| `talos/Makefile` (cluster-side wrapper) | Delegates to `vendor/base/talos/Makefile`, sets `EXTRA_PATCHES_DIR=$(PWD)/talos/patches`, `NODES_DIR=$(PWD)/talos/nodes` |
| `.github/workflows/check-base-pin-drift.yml` | CI workflow invoking the drift script |
| `.github/workflows/cluster-validate.yml` | CI workflow: `make bootstrap-base` then `kubectl kustomize kubernetes/overlays/homelab/` (replaces base's `gitops-validate.yml` for the cluster repo) |
| `LICENSE` | Apache-2.0 (match base) |
| `CHANGELOG.md` | Initial entry referencing source-snapshot SHA + base-version pin |

### 4.3 DROP — covered by base, not duplicated here

| Path | Reason |
|---|---|
| `kubernetes/base/` | Lives in `talos-platform-base`; cluster fetches via OCI |
| `kubernetes/bootstrap/argocd/` (templates) | Lives in base; cluster's `make argocd-bootstrap` invokes `vendor/base/.argocd-bootstrap-render` |
| `kubernetes/bootstrap/cilium/values.yaml`, `extras.yaml` | Live in base |
| `talos/Makefile` (top-level) | Lives in base; cluster's `talos/Makefile` is a thin wrapper |
| `talos/patches/common.yaml`, `controlplane.yaml` (base version), `drbd.yaml`, `worker-*.yaml`, `cluster.yaml.tmpl` | Base patches; cluster `talos/patches/controlplane.yaml` is the cluster-overlay layer that **adds** to base patches via Talos config layering |
| `talos/versions.mk`, `talos/.schematic-ids.mk` | Base; cluster references via `vendor/base/talos/...` |
| `Makefile` (top-level base targets) | Replaced with thin delegator (§4.2) |
| `policies/conftest/` | Lives in base |
| `scripts/check-codex-config-placeholders.sh`, `check-mcp-config-portable.sh`, `discover_kustomize_targets.sh`, `issue-state.sh`, `mcp-github-wrapper.sh`, `render-cilium-bootstrap.sh`, `render_kustomize_safe.sh`, `run_conftest.sh`, `verify_sops_files.sh` | All base scripts |
| `.github/workflows/gitops-validate.yml`, `hard-constraints-check.yml` | Base CI workflows. Cluster has its own CI (see §4.2). |
| Generic docs from base-plan BASE bucket: `mcp-setup.md`, `issue-workflow.md`, `primitive-contract.md`, `claude-code-guide.md`, `claude-code-stack-audit.md`, `tetragon-deployment-verification.md`, `trivy-policy.md`, `adr-multi-repo-platform-split.md` | These are platform-generic; available via `vendor/base/docs/` after bootstrap |
| Top-level `Makefile` (current full-fat version) | Replaced |

**Bonus § 4.3.A — gitops-validate workflow split decision.** The current `.github/workflows/gitops-validate.yml` runs `kubectl kustomize` + secret-scan. In the multi-repo world:
- **Base** validates `kubernetes/base/...` renders cleanly (pinned to a known cilium chart, kyverno chart, etc.).
- **Cluster** must validate `kubernetes/overlays/homelab/` renders against its **specific** pinned base version.

The cluster needs its own `cluster-validate.yml` that: (1) runs `make bootstrap-base` to fetch `vendor/base/`, (2) runs `kubectl kustomize` against `kubernetes/overlays/homelab/`. This catches drift that base-CI cannot see (e.g., overlay references a base path that no longer exists in the pinned base version).

### 4.4 Carve-out — `.claude/` and `.codex/` while #147 is pending

The harness-skill-migration (Talos-Homelab #147) is in handoff state. Until that work executes against `kube-agent-harness`, the cluster repo carries the full current `.claude/` and `.codex/` directories so the cluster Claude Code experience is functional from day one. After #147 lands and the harness publishes its v0.2.0 release:

1. The cluster repo's `.claude/` is replaced with a `claude plugin install kube-agent-harness@<version>` reference + thin `.claude/CLAUDE.md` + `.claude/harness.yaml` (capability declaration: `gitops: argocd`, `csi: linstor`).
2. Talos-/Cilium-/PNI-specific skills/rules that stayed with the cluster (per harness migration plan §6/§9) live under `.claude/skills/` and `.claude/rules/` in the cluster repo.
3. Stay-in-cluster agents (e.g., `talos-sre`) live under `.claude/agents/`.

This carve-out is documented in the cluster's AGENTS.md (§7.1) so a future contributor understands why both `.claude/` and harness-plugin-install coexist transitionally.

## 5. Filter-repo command

The filter-repo uses **positive paths** (keep these, drop everything else). All 34 Application paths under `kubernetes/overlays/homelab/` survive transparently because the parent `kubernetes/overlays/homelab` is in the keep list.

```bash
cd /tmp
rm -rf cluster-snapshot
git clone --no-local https://github.com/Nosmoht/Talos-Homelab.git cluster-snapshot
cd cluster-snapshot
git rev-parse HEAD                                  # record source commit

git filter-repo \
  --path kubernetes/overlays/homelab \
  --path kubernetes/bootstrap/cilium/cilium.yaml \
  --path talos/nodes \
  --path talos/patches/pi-firewall.yaml \
  --path talos/secrets.yaml \
  --path talos/talosconfig \
  --path talos/talos-factory-schematic.yaml \
  --path talos/talos-factory-schematic-gpu.yaml \
  --path talos/talos-factory-schematic-pi.yaml \
  --path talos/AGENTS.md \
  --path scripts/configure-sg3428-via-omada-api.sh \
  --path scripts/discover_argocd_apps.sh \
  --path scripts/run_trivy.sh \
  --path .github/workflows/skill-frontmatter-check.yml \
  --path .github/workflows/sysctl-baseline-check.yml \
  --path .claude \
  --path .codex \
  --path Plans \
  --path package.json \
  --path package-lock.json \
  --path tests \
  --path AGENTS.md \
  --path CLAUDE.md \
  --path README.md \
  --path kubernetes/AGENTS.md \
  --path cluster.yaml.example \
  --path docs/2026-04-15-fritzbox-macvlan-port-forward-exhaustion.md \
  --path docs/adr-pi-sole-public-ingress.md \
  --path docs/adr-ingress-front-stable-mac.md \
  --path docs/adr-storage-vlan-and-encryption.md \
  --path docs/adr-tenant-cluster-exposure.md \
  --path docs/runbook-cold-cluster-cutover.md \
  --path docs/runbook-drbd-vlan-binding.md \
  --path docs/platform-network-interface.md \
  --path docs/diagnosis-node-03-nic-2026-04-11.md \
  --path docs/day0-setup.md \
  --path docs/day2-operations.md \
  --path docs/kubevirt-vlan-networking-approaches-2026-03-29.md \
  --path docs/kubevirt-vm-platform-alternatives-2026-03-29.md \
  --path docs/kernel-tuning.md \
  --path docs/kernel-tuning-gpu.md \
  --path docs/talos-maintenance-node-gpu-01-2026-03-25.md \
  --path docs/network-policy-remediation-todo.md \
  --path docs/plan-pr-2b-drbd-transport-tls.md \
  --path docs/ui-loadbalancer-ip-plan.md \
  --path docs/external-secrets-customer-guide.md \
  --path docs/agent-harness-audit-prompt.md \
  --path docs/freeze-learnings.md \
  --path docs/MOVED-enterprise-blueprint.md \
  --path docs/enterprise-network-blueprint-implementation-roadmap.md \
  --path docs/implementation-log-phase1-network-blueprint.md \
  --path docs/kubernetes-review.md \
  --path docs/kubernetes-review-todo.md \
  --path docs/security-code-review.md \
  --path docs/vault-config-operator-pki-migration.md \
  --path docs/linstor-state-pre-migration.txt \
  --path docs/nic-baseline-netgear-20260415.txt \
  --path docs/nic-baseline-sg3428-20260416.txt \
  --path docs/omada-controller-post-config.cfg \
  --path-glob 'docs/hardware-analysis-*' \
  --path-glob 'docs/cilium-debug-*' \
  --path-glob 'docs/cilium-upgrade-*' \
  --path-glob 'docs/talos-upgrade-*' \
  --path-glob 'docs/postmortem-*' \
  --path-glob 'docs/migration-plans/*'
```

Expected outcome: `git log --oneline | wc -l` ≥ source commits that touched any kept path. `du -sh .` substantially smaller than source (no `kubernetes/base/`, no top-level Makefile, no policies/conftest etc.).

**Verify cleanliness post-filter** — that nothing pointing at base content remains broken:

```bash
# Reference base paths that no longer exist in this repo
git grep -nE 'kubernetes/base/|policies/conftest/|talos/Makefile' \
  -- ':!kubernetes/overlays/homelab/**/application.yaml'

# kustomization.yaml entries pointing at removed parents
find . -name kustomization.yaml -exec grep -l 'resources:.*base/' {} +
```

The first grep MUST exclude application.yaml files because they correctly reference base paths via `$values/kubernetes/base/...` (Multi-Source pattern). The second must show no surviving references to `kubernetes/base/` from kustomization parents — those were dropped.

## 6. Multi-Source Application re-targeting

Each of the 34 `kubernetes/overlays/homelab/{infrastructure,apps}/<comp>/application.yaml` files currently has 2 sources pointing at `Talos-Homelab.git` (one for `$values`, one for `path: .../resources`). Both must be updated:

**Before** (current homelab Application CR):
```yaml
spec:
  sources:
    - repoURL: https://argoproj.github.io/argo-helm   # external Helm chart repo
      chart: argo-cd
      targetRevision: 9.4.5
      helm:
        valueFiles:
          - $values/kubernetes/base/infrastructure/argocd/values.yaml
          - $values/kubernetes/overlays/homelab/infrastructure/argocd/values.yaml
    - repoURL: https://github.com/Nosmoht/Talos-Homelab.git
      targetRevision: main
      ref: values
    - repoURL: https://github.com/Nosmoht/Talos-Homelab.git
      targetRevision: main
      path: kubernetes/overlays/homelab/infrastructure/argocd/resources
```

**After** (cluster Application CR with split sources):
```yaml
spec:
  sources:
    - repoURL: https://argoproj.github.io/argo-helm
      chart: argo-cd
      targetRevision: 9.4.5
      helm:
        valueFiles:
          - $base/kubernetes/base/infrastructure/argocd/values.yaml
          - $cluster/kubernetes/overlays/homelab/infrastructure/argocd/values.yaml
    - repoURL: https://github.com/Nosmoht/talos-platform-base.git
      targetRevision: v0.1.0
      ref: base
    - repoURL: https://github.com/Nosmoht/talos-homelab-cluster.git
      targetRevision: HEAD
      ref: cluster
    - repoURL: https://github.com/Nosmoht/talos-homelab-cluster.git
      targetRevision: HEAD
      path: kubernetes/overlays/homelab/infrastructure/argocd/resources
```

Key changes:
1. The `$values` ref is split into `$base` (pinned to `v0.1.0`) and `$cluster` (HEAD).
2. The `path:` source for `resources/` re-targets to the cluster repo, HEAD revision.
3. Where the original used `ref: values` for both, the new uses `ref: base` and `ref: cluster` separately.

**Driver script** for the per-Application rewrite (to be authored as `scripts/migrate-application-multisource.sh` and run during execution):

```bash
#!/usr/bin/env bash
set -euo pipefail
BASE_REPO_URL="https://github.com/Nosmoht/talos-platform-base.git"
CLUSTER_REPO_URL="https://github.com/Nosmoht/talos-homelab-cluster.git"
BASE_PIN="v0.1.0"

find kubernetes/overlays/homelab -name application.yaml -type f | while read -r f; do
  # Replace the two existing $values-style entries with the new dual-ref pattern.
  # yq is purpose-built for this; use it instead of sed.
  yq -i '
    .spec.sources |= [
      .[] | select(.ref != "values" and (.path // "") | (test("^kubernetes/overlays/homelab/.*/resources$") | not))
    ] + [
      {"repoURL": "'"$BASE_REPO_URL"'",    "targetRevision": "'"$BASE_PIN"'", "ref": "base"},
      {"repoURL": "'"$CLUSTER_REPO_URL"'", "targetRevision": "HEAD",          "ref": "cluster"}
    ]
  ' "$f"
  # Append the resources path source (still cluster-side)
  yq -i '
    .spec.sources += [{
      "repoURL": "'"$CLUSTER_REPO_URL"'",
      "targetRevision": "HEAD",
      "path": "kubernetes/overlays/homelab/" + (.metadata.labels."app.kubernetes.io/component" // "infrastructure") + "/" + .metadata.name + "/resources"
    }]
  ' "$f"
  # Replace $values/ prefix with $base/ or $cluster/ in valueFiles
  yq -i '
    (.spec.sources[] | select(.helm.valueFiles).helm.valueFiles) |=
      [.[] |
        sub("^\\$values/kubernetes/base/"; "$base/kubernetes/base/") |
        sub("^\\$values/kubernetes/overlays/"; "$cluster/kubernetes/overlays/")
      ]
  ' "$f"
done
```

**This script is hand-verified against 3 Applications first** (one infrastructure, one app, one with no `resources/` directory) before running across all 34. yq edge cases — Helm chart entries vs. plain Git entries, components without overlay values.yaml, components without `resources/` directory — must be tested.

**AppProjects' `sourceRepos` list** must also update from a single `Talos-Homelab.git` URL to both new URLs. Files: `kubernetes/overlays/homelab/projects/{infrastructure,apps,root-bootstrap}.yaml`. yq edit pattern:

```bash
for proj in kubernetes/overlays/homelab/projects/*.yaml; do
  yq -i '
    .spec.sourceRepos |= ([.[] | select(. != "https://github.com/Nosmoht/Talos-Homelab.git")] + [
      "https://github.com/Nosmoht/talos-platform-base.git",
      "https://github.com/Nosmoht/talos-homelab-cluster.git"
    ] | unique)
  ' "$proj"
done
```

## 7. Post-filter manual cleanup

After filter-repo and the §6 Multi-Source rewrite, six files need editing.

### 7.1 `AGENTS.md` rewrite

Drop these sections (they are platform-base content; covered by `vendor/base/AGENTS.md` after bootstrap):
- `## Build, Test, and Development Commands` (replaced with thin delegator equivalents — see §7.3 README)
- `## Hard Constraints` (lives in base)
- `## Tool-Agnostic Safety Invariants` (base)
- `## MCP Server Configuration` (base)
- `## Domain Rules — On-Demand Reference` (base)
- `## Validation Checklist For Codex Changes` (base)

Keep + tighten:
- `## Cluster Overview` (the homelab table — IPs, hardware, FritzBox, Pi-public-ingress, gateway VIP, PodCIDR, storage, networking)
- `## Key Terms` (PNI overlay reference, FritzBox, pi-public-ingress, macvlan, DRBD specifics)
- `## Operational Patterns` (homelab-specific runbook references — pre-operation review, dual-perspective analysis, full-cluster cutover runbook reference, MCP-first patterns)
- `## Operational Runbooks (Skills)` (table of skills present in this repo's `.claude/skills/` until #147 plugin migration moves them out)
- `## Session-Start Ritual` (homelab-specific GitHub backlog scan)
- `## Deltas vs Claude Code (For Codex CLI Users)` (full)
- `## Codex CLI Operating Rules`
- `## OpenCode Compatibility Notes`

Add a new section near the top:
```
## Repository Purpose

This is the homelab cluster repo. It carries the per-cluster identity,
node configurations, encrypted secrets bundle, overlay values, and the
ArgoCD Application manifests that consume the cluster-agnostic
`talos-platform-base` (pinned via `.base-version`).

It is NOT a generic Kubernetes platform. It encodes a specific
hardware+network topology — Lenovo M910q control plane, Talos workers,
Raspberry Pi WAN edge with FritzBox port-forward, Cilium WireGuard
strict mode, LINSTOR/Piraeus DRBD storage on NVMe nodes.

For platform-generic content, see the OCI artifact pulled into
`vendor/base/` by `make bootstrap-base`. The base provides Helm bases,
Talos patch templates, the ArgoCD bootstrap mechanism, and conftest
policies. The cluster overlay provides only what differs.
```

Add a `## Base consumption` section explaining `.base-version`, `make day0`, the OCI mechanic, and the drift gate.

### 7.2 `CLAUDE.md` rewrite

`CLAUDE.md` continues to import `AGENTS.md` (now the cluster's). Trim/adjust:
- `### Path-Scoped Auto-Loaded Rules` — references `.claude/rules/*.md` which still live in cluster repo (per harness migration carve-out for paths-frontmatter rules). Keep.
- `### Hooks (PreToolUse / PostToolUse enforcement)` — reword: most hooks now ship from harness plugin; only the ones flagged STAY-IN-CLUSTER per harness migration plan §8 remain in `.claude/hooks/`.
- `### Subagents` — same: most agents from harness plugin (when #147 lands), Talos-/Cilium-bound agents stay in cluster `.claude/agents/`.
- `### Context Architecture` — keep, update count of skills/rules/agents/hooks present in cluster repo (will change after #147 migrates the generic ones).

### 7.3 `README.md` rewrite

```markdown
# talos-homelab-cluster

GitOps cluster repo for the homelab Talos-on-Kubernetes deployment.
Consumes `talos-platform-base` via OCI artifact at
`ghcr.io/nosmoht/talos-platform-base`.

## What this provides

- Cluster identity (`cluster.yaml` per-host, `cluster.yaml.example` schema)
- 8 Talos node configurations (3 control-plane, 4 workers, 1 GPU, 1 Pi WAN edge)
- 34 ArgoCD Applications across infrastructure + apps + projects
- Cluster-rendered Cilium bootstrap manifest (Hubble TLS certs)
- Cluster-specific Talos patches (pi-firewall, cluster.yaml NTP)
- Encrypted secrets bundle (SOPS/AGE)
- Overlay-specific Helm value overrides per component
- Homelab-specific ADRs, runbooks, postmortems, hardware analyses

## Day-0 bootstrap

Prerequisites:
- `oras` CLI: `brew install oras` (macOS) or per-distro equivalent
- Talos `talosctl`, `kubectl`, `helm`, `yq`, `sops` (with AGE key)
- A populated `cluster.yaml` (gitignored; copy from `cluster.yaml.example`)

```bash
make day0
```

This runs in order:
1. `make bootstrap-base` — `oras pull` of `talos-platform-base:$(.base-version)` into `vendor/base/`
2. `make gen-configs` — Talos machine configs in `talos/_out/<cluster>/`
3. `make apply` — `talosctl` push to all nodes
4. `make argocd-install` — Helm install of ArgoCD
5. `make argocd-bootstrap` — apply root Application CR

## Day-2 operations

ArgoCD reconciles all Applications via Multi-Source pattern: each
Application references `talos-platform-base.git` for base values
(pinned to `.base-version`) and this repo's `kubernetes/overlays/homelab/`
for cluster overrides.

Bumping the base pin: edit `.base-version`, then run
`scripts/check-base-pin-drift.sh` to update every
`spec.sources[].targetRevision` for the base source in lock-step. CI
enforces the drift gate.

## Repository structure

- `.base-version` — single line: tag of `talos-platform-base` to consume
- `vendor/base/` — gitignored; populated by `make bootstrap-base`
- `cluster.yaml` — cluster identity (gitignored, populate from `cluster.yaml.example`)
- `kubernetes/overlays/homelab/` — 34 Applications + projects + per-component overlay values + extra resources
- `kubernetes/bootstrap/cilium/cilium.yaml` — cluster-rendered manifest with Hubble TLS certs
- `talos/nodes/` — per-node Talos patches
- `talos/patches/controlplane.yaml` — cluster-specific Talos patch overlay (gateway-api + cilium extraManifests)
- `talos/patches/pi-firewall.yaml` — Pi WAN edge firewall rules
- `scripts/bootstrap-base.sh`, `scripts/check-base-pin-drift.sh` — base-consumption tooling
- `docs/` — homelab-specific documentation (ADRs, runbooks, postmortems, hardware analyses)
- `.claude/`, `.codex/` — Claude Code / Codex CLI integration (transitional; some content moves to `kube-agent-harness` plugin per Talos-Homelab #147)

## License

Apache-2.0.
```

### 7.4 `talos/patches/controlplane.yaml` (new cluster-overlay version)

The base ships its `controlplane.yaml` without `extraManifests:`. The cluster layers a patch that adds the cluster-specific ones:

```yaml
# Cluster-overlay layer over vendor/base/talos/patches/controlplane.yaml.
# Adds the cluster-specific extraManifests (gateway-api CRDs + this cluster's
# rendered Cilium bootstrap with Hubble TLS certs).
cluster:
  extraManifests:
    - https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/experimental-install.yaml
    # Cache-busting: bump the v= query param when bumping the Cilium chart
    # version in vendor/base/talos/versions.mk
    - https://raw.githubusercontent.com/Nosmoht/talos-homelab-cluster/main/kubernetes/bootstrap/cilium/cilium.yaml?v=1.19.2-9
```

The cluster's `talos/Makefile` (§7.6) ensures Talos `gen-configs` reads this overlay AFTER `vendor/base/talos/patches/controlplane.yaml`, so the `extraManifests:` array in base (empty) merges with this overlay (two URLs). Verify with `--dry-run` post-edit.

**Note on Plan #1 §7.4:** The base-creation plan strips the *entire* `extraManifests:` block, including the upstream `gateway-api/.../experimental-install.yaml` URL. That is more aggressive than strictly required (gateway-api is also generic), but the cluster overlay puts both URLs back, so functionally there is no regression. A future minor refinement to base could restore gateway-api in the base patch and let the cluster overlay add only cilium — out of scope here.

### 7.5 `cluster.yaml.example` retain as-is

This file already documents the schema. Verify it has no homelab-specific defaults baked in — if literal homelab IPs appear (rather than placeholders), edit to placeholders. The cluster's actual `cluster.yaml` is gitignored; consumers populate it from this example.

### 7.6 `talos/Makefile` (cluster-side wrapper)

A short Makefile that delegates to base:

```makefile
# Cluster-side Talos Makefile — thin wrapper that delegates to vendor/base
# while pointing at this repo's nodes/ + patches/.

ENV ?= $(PWD)/cluster.yaml
BASE := $(PWD)/vendor/base

.PHONY: gen-configs apply-all dry-run-all schematics validate-generated cilium-bootstrap

gen-configs:
	$(MAKE) -C $(BASE)/talos gen-configs \
	  ENV=$(ENV) \
	  EXTRA_PATCHES_DIR=$(PWD)/talos/patches \
	  NODES_DIR=$(PWD)/talos/nodes \
	  OUTPUT_ROOT=$(PWD)/talos/_out

apply-all:
	$(MAKE) -C $(BASE)/talos apply-all OUTPUT_ROOT=$(PWD)/talos/_out

dry-run-all:
	$(MAKE) -C $(BASE)/talos dry-run-all OUTPUT_ROOT=$(PWD)/talos/_out

schematics:
	$(MAKE) -C $(BASE)/talos schematics

validate-generated:
	$(MAKE) -C $(BASE)/talos validate-generated OUTPUT_ROOT=$(PWD)/talos/_out

cilium-bootstrap:
	$(MAKE) -C $(BASE)/talos cilium-bootstrap \
	  OUTPUT=$(PWD)/kubernetes/bootstrap/cilium/cilium.yaml
```

The base Makefile's existing variables (`EXTRA_PATCHES_DIR`, `NODES_DIR`, `OUTPUT_ROOT`) need to honor caller-provided values. **Audit during execution**: if base's `talos/Makefile` hardcodes those paths, file a follow-up issue against the base repo to parameterize them. (Phase 1 already did most of this, but verify.)

## 8. New top-level files post-filter

### 8.1 `Makefile` (top-level rewrite)

Replaces the old base-side Makefile with a cluster-side delegator:

```makefile
# Cluster-side top-level Makefile.

ENV ?= $(PWD)/cluster.yaml
BASE := $(PWD)/vendor/base
BASE_VERSION := $(shell cat .base-version)

.PHONY: bootstrap-base gen-configs apply argocd-install argocd-bootstrap day0 \
        validate-gitops check-base-pin-drift

bootstrap-base:
	./scripts/bootstrap-base.sh

gen-configs: bootstrap-base
	$(MAKE) -C talos gen-configs ENV=$(ENV)

apply: gen-configs
	$(MAKE) -C talos apply-all

argocd-install: bootstrap-base
	$(MAKE) -C $(BASE) argocd-install

argocd-bootstrap: bootstrap-base
	$(MAKE) -C $(BASE) argocd-bootstrap ENV=$(ENV)

day0: bootstrap-base gen-configs apply argocd-install argocd-bootstrap
	@CLUSTER_NAME=$$(yq -e '.cluster.name' $(ENV)); \
	echo "Cluster $$CLUSTER_NAME bootstrapped against talos-platform-base $(BASE_VERSION)."

validate-gitops: bootstrap-base
	$(BASE)/scripts/render_kustomize_safe.sh kubernetes/overlays/homelab

check-base-pin-drift:
	./scripts/check-base-pin-drift.sh
```

### 8.2 `scripts/bootstrap-base.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

if ! command -v oras >/dev/null 2>&1; then
  echo "ERROR: 'oras' CLI not found. Install: brew install oras (macOS) or per-distro." >&2
  exit 1
fi

VERSION=$(cat .base-version)
ARTIFACT="ghcr.io/nosmoht/talos-platform-base:${VERSION}"
DEST="vendor/base"

if [[ -f "${DEST}/.version" ]] && [[ "$(cat "${DEST}/.version")" == "${VERSION}" ]]; then
  echo "vendor/base already at ${VERSION}; skipping pull."
  exit 0
fi

echo "Pulling ${ARTIFACT} into ${DEST}..."
rm -rf "${DEST}"
mkdir -p "${DEST}"
TMPDIR=$(mktemp -d)
trap 'rm -rf "${TMPDIR}"' EXIT
oras pull --output "${TMPDIR}" "${ARTIFACT}"

# Verify checksums
( cd "${TMPDIR}" && sha256sum -c checksums.txt ) >/dev/null 2>&1 || {
  echo "ERROR: checksum verification failed for ${ARTIFACT}" >&2
  exit 1
}

# Extract tarball
tar xzf "${TMPDIR}"/talos-platform-base-*.tar.gz -C "${DEST}" --strip-components=0

# Lock read-only to flag accidental edits
chmod -R a-w "${DEST}"

echo "${VERSION}" > "${DEST}/.version"
chmod a+w "${DEST}/.version"           # allow next bump to overwrite
echo "vendor/base ready at ${VERSION}."
```

### 8.3 `scripts/check-base-pin-drift.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

PIN=$(cat .base-version)
DRIFT=0

while IFS= read -r f; do
  # Extract every targetRevision for the base source URL
  while IFS= read -r rev; do
    if [[ "${rev}" != "${PIN}" ]]; then
      echo "DRIFT: ${f} references base @ ${rev}, but .base-version says ${PIN}"
      DRIFT=1
    fi
  done < <(yq '.spec.sources[]? | select(.repoURL | test("talos-platform-base")) | .targetRevision' "${f}")
done < <(find kubernetes/overlays/homelab -name application.yaml -type f)

# Also check AppProjects
while IFS= read -r f; do
  if ! yq -e '.spec.sourceRepos[] | select(. == "https://github.com/Nosmoht/talos-platform-base.git")' "${f}" >/dev/null 2>&1; then
    echo "WARN: ${f} does not list talos-platform-base.git in sourceRepos"
    DRIFT=1
  fi
done < <(find kubernetes/overlays/homelab/projects -name '*.yaml' -type f)

if [[ ${DRIFT} -ne 0 ]]; then
  echo "Drift detected. Either bump .base-version + targetRevision in lock-step, or add the missing AppProject sourceRepos entry."
  exit 1
fi

echo "All Applications pin base @ ${PIN}; AppProjects list both repo URLs."
```

### 8.4 `.github/workflows/check-base-pin-drift.yml`

```yaml
name: Base pin drift gate

on:
  pull_request:
    paths:
      - '.base-version'
      - 'kubernetes/overlays/homelab/**/application.yaml'
      - 'kubernetes/overlays/homelab/projects/*.yaml'
      - 'scripts/check-base-pin-drift.sh'

jobs:
  drift:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install yq
        run: |
          sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
          sudo chmod +x /usr/local/bin/yq
      - name: Run drift check
        run: ./scripts/check-base-pin-drift.sh
```

### 8.5 `.github/workflows/cluster-validate.yml`

```yaml
name: Cluster overlay validate

on:
  pull_request:
    paths:
      - 'kubernetes/overlays/homelab/**'
      - '.base-version'

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install oras
        uses: oras-project/setup-oras@v1
        with:
          version: 1.2.0
      - name: Install kubectl + yq + kustomize
        run: |
          curl -fsSL -o /usr/local/bin/kubectl "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
          curl -fsSL -o /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
          chmod +x /usr/local/bin/kubectl /usr/local/bin/yq
      - name: Bootstrap base
        run: |
          chmod +x scripts/bootstrap-base.sh
          ./scripts/bootstrap-base.sh
      - name: Render overlay
        run: kubectl kustomize kubernetes/overlays/homelab/ > /tmp/rendered.yaml
      - name: Sanity check render
        run: |
          [ -s /tmp/rendered.yaml ] || { echo "Empty render"; exit 1; }
          grep -q "kind: Application" /tmp/rendered.yaml
```

### 8.6 `LICENSE`

Apache-2.0 license text.

### 8.7 `CHANGELOG.md`

```markdown
# Changelog

## v0.1.0 — 2026-04-29

Initial cluster repo. Snapshot of `Talos-Homelab` `main` at commit `<source-sha>`,
filtered to retain only cluster-specific content per
`docs/adr-multi-repo-platform-split.md`.

Pinned to `talos-platform-base` v0.1.0
(`ghcr.io/nosmoht/talos-platform-base:v0.1.0`).

### Cluster-specific content

- 34 ArgoCD Applications (infrastructure + apps), Multi-Source-rewritten
  to consume base via `$base` ref + cluster overlay via `$cluster` ref
- 8 Talos node configurations (control-plane × 3, workers × 4, GPU × 1, Pi WAN edge × 1)
- Cluster-rendered `kubernetes/bootstrap/cilium/cilium.yaml` (Hubble TLS certs)
- Cluster Talos patch: `talos/patches/controlplane.yaml` overlay layer
  with gateway-api + cilium extraManifests
- Cluster Talos patch: `talos/patches/pi-firewall.yaml` (FritzBox / Pi-public-ingress)
- Encrypted secrets: `talos/secrets.yaml` (SOPS-AGE)
- Talos Image Factory schematics: `talos/talos-factory-schematic*.yaml`
- Homelab-specific docs (ADRs for Pi/ingress/storage/tenant, runbooks, postmortems, hardware analyses)
- Homelab-specific scripts (configure-sg3428, discover_argocd_apps, run_trivy)
- Homelab-specific CI workflows (skill-frontmatter-check, sysctl-baseline-check)

### New cluster-side mechanics

- `.base-version` pinning
- `make day0` meta-target
- `scripts/bootstrap-base.sh` (oras pull driver)
- `scripts/check-base-pin-drift.sh` + CI gate
- `cluster-validate.yml` workflow
- Top-level `Makefile` thin delegator
- `talos/Makefile` thin delegator

### Removed from snapshot

- `kubernetes/base/` (in `talos-platform-base`)
- Top-level base Makefile, talos base Makefile, talos base patches
- Base scripts and base CI workflows
- Generic docs (covered by base via `vendor/base/docs/`)
```

## 9. Execution mechanics

### 9.1 Throwaway clone + filter-repo

```bash
cd /tmp
rm -rf cluster-snapshot
git clone --no-local https://github.com/Nosmoht/Talos-Homelab.git cluster-snapshot
cd cluster-snapshot
echo "Source commit: $(git rev-parse HEAD)"

# §5 filter-repo block (positive paths)
git filter-repo \
  --path kubernetes/overlays/homelab \
  ... (full list from §5)

# Verify cleanliness — no stale refs to dropped paths
git grep -nE 'kubernetes/base/|policies/conftest/|talos/Makefile' \
  -- ':!kubernetes/overlays/homelab/**/application.yaml' || echo "CLEAN-1"
find . -name kustomization.yaml -exec grep -l 'resources:.*base/' {} +
```

### 9.2 Multi-Source Application + AppProject re-targeting

```bash
# §6 driver script
$EDITOR scripts/migrate-application-multisource.sh   # author per §6
chmod +x scripts/migrate-application-multisource.sh

# Hand-verify against 3 representative Applications first
./scripts/migrate-application-multisource.sh \
  kubernetes/overlays/homelab/infrastructure/argocd/application.yaml
git diff kubernetes/overlays/homelab/infrastructure/argocd/application.yaml | head -40
# Inspect; confirm correctness before iterating

# Apply to all 34
find kubernetes/overlays/homelab -name application.yaml -type f \
  -exec ./scripts/migrate-application-multisource.sh {} \;

# AppProject sourceRepos update (§6)
$EDITOR kubernetes/overlays/homelab/projects/  # apply yq snippet from §6

# Commit the rewrite
git add kubernetes/overlays/homelab/{infrastructure,apps,projects} scripts/migrate-application-multisource.sh
git commit -s -m "feat(argocd): split Application sources into base + cluster repos

All 34 Applications and 3 AppProjects re-targeted from a single
Talos-Homelab.git URL to dual sources: talos-platform-base.git pinned
to .base-version + talos-homelab-cluster.git at HEAD. Helm valueFiles
use $base/ for base values and $cluster/ for overlay values."
```

### 9.3 Post-filter cleanup commits

```bash
# §7.4 cluster controlplane patch overlay
$EDITOR talos/patches/controlplane.yaml
git add talos/patches/controlplane.yaml
git commit -s -m "feat(talos): cluster controlplane overlay with extraManifests"

# §7.6 cluster talos/Makefile wrapper
$EDITOR talos/Makefile
git add talos/Makefile
git commit -s -m "feat(talos): cluster-side Makefile wrapper"

# §8.1 top-level Makefile rewrite
$EDITOR Makefile
git add Makefile
git commit -s -m "feat(make): cluster-side top-level Makefile (day0 meta-target)"

# §8.2, §8.3 bootstrap + drift scripts
$EDITOR scripts/bootstrap-base.sh scripts/check-base-pin-drift.sh
chmod +x scripts/bootstrap-base.sh scripts/check-base-pin-drift.sh
git add scripts/bootstrap-base.sh scripts/check-base-pin-drift.sh
git commit -s -m "feat(scripts): bootstrap-base + check-base-pin-drift"

# §8.4, §8.5 CI workflows
mkdir -p .github/workflows
$EDITOR .github/workflows/check-base-pin-drift.yml .github/workflows/cluster-validate.yml
git add .github/workflows/check-base-pin-drift.yml .github/workflows/cluster-validate.yml
git commit -s -m "ci: drift gate + cluster overlay validate"

# .base-version
echo "v0.1.0" > .base-version
git add .base-version
git commit -s -m "chore: pin talos-platform-base to v0.1.0"

# .gitignore extension
$EDITOR .gitignore   # add 'vendor/base/', '_release/'
git add .gitignore
git commit -s -m "chore: gitignore vendor/base/, _release/"

# §7.1, §7.2, §7.3 doc rewrites + §8.6 LICENSE + §8.7 CHANGELOG
$EDITOR AGENTS.md CLAUDE.md README.md kubernetes/AGENTS.md LICENSE CHANGELOG.md
git add AGENTS.md CLAUDE.md README.md kubernetes/AGENTS.md LICENSE CHANGELOG.md
git commit -s -m "docs: rewrite for cluster-repo perspective; add LICENSE + CHANGELOG"
```

### 9.4 Create + push to new GitHub origin

```bash
gh repo create Nosmoht/talos-homelab-cluster --public \
  --description "Homelab cluster overlay for the Talos-on-Kubernetes platform"
git remote add origin git@github.com:Nosmoht/talos-homelab-cluster.git
git push -u origin main
```

### 9.5 Verify CI on initial main push

```bash
gh run list --repo Nosmoht/talos-homelab-cluster --limit 5
gh run watch
```

`check-base-pin-drift.yml` and `cluster-validate.yml` should run and pass.

### 9.6 End-to-end Day-0 test against sacrificial cluster

This is the **gate** that determines whether Phase 3D (live cutover) is allowed to proceed.

```bash
# Stand up a test cluster (Talos-in-VM lab or sacrificial hardware)
# Populate cluster.yaml for the test environment

cd ~/sandbox/talos-homelab-cluster
git clone https://github.com/Nosmoht/talos-homelab-cluster.git .
$EDITOR cluster.yaml      # test-env values

make day0                 # full bootstrap

# Verify
kubectl get applications -A
argocd app list
# All 34 Applications must report Synced + Healthy within ~10 min
```

If any Application reports `ComparisonError` or stays `OutOfSync` past auto-sync retry exhaustion: investigate, fix, re-test before promoting Phase 3D.

## 10. Acceptance criteria

1. `Nosmoht/talos-homelab-cluster` repo exists on GitHub with branch `main` and history preserved for retained paths
2. `git log --oneline | wc -l` > 0 and < source `Talos-Homelab` count
3. `.base-version` exists, content is `v0.1.0`
4. `scripts/bootstrap-base.sh` is executable; running it from a fresh checkout pulls and extracts the `v0.1.0` artifact into `vendor/base/`
5. `scripts/check-base-pin-drift.sh` is executable and exits 0 against the migrated tree
6. All 34 `kubernetes/overlays/homelab/**/application.yaml` files have `spec.sources[]` with at least 3 entries: external Helm chart, `talos-platform-base.git@v0.1.0`, `talos-homelab-cluster.git@HEAD`
7. All 3 AppProjects in `kubernetes/overlays/homelab/projects/*.yaml` list both repo URLs in `spec.sourceRepos`
8. `talos/patches/controlplane.yaml` contains an `extraManifests:` block with the gateway-api URL + the new cluster's raw GitHub URL for `cilium.yaml`
9. CI workflows `check-base-pin-drift.yml` and `cluster-validate.yml` are green on initial main push
10. From a sacrificial test cluster: `make day0` completes successfully; all 34 Applications reach Synced + Healthy within 10 min wall-clock
11. README, AGENTS.md, CLAUDE.md updated for cluster perspective
12. `.gitignore` includes `vendor/base/`
13. `Talos-Homelab` repo unchanged: `git log` on `Talos-Homelab/main` shows the same commits before and after this work

## 11. Rollback path

The throwaway clone is in `/tmp/cluster-snapshot`. Until §9.4 (`gh repo create + git push`) runs, rollback is `rm -rf /tmp/cluster-snapshot`.

After §9.4 but before any consumer pins the new repo: `gh repo delete Nosmoht/talos-homelab-cluster --yes`.

After §9.6 test-cluster provisioning: the new repo is consumed by the test cluster only — no production impact. Rollback = tear down test cluster and `gh repo delete`.

`Talos-Homelab` is **never modified** by any step in this plan, so there is no source-side rollback obligation.

## 12. Connection to Phase 3D (live cutover)

Phase 3D (Talos-Homelab #155) plans the cutover of the live homelab cluster's ArgoCD root Application from `Talos-Homelab.git` to `talos-homelab-cluster.git`. That work is **strictly downstream** of this plan, with these prerequisites:

1. This plan executed; `talos-homelab-cluster` exists and is verified end-to-end against a test cluster (§9.6 acceptance gate)
2. Drift between `Talos-Homelab` and `talos-homelab-cluster` is < 1 week (any deferred fixes either backported manually or batched into the cutover commit)
3. The runtime probes listed in #155 body (pi-public-ingress, ingress-front, vault, dex, cert-manager, kube-prometheus-stack, hook safety) are scripted and ready to run

This plan **does not** cut over the live cluster.

## 13. Out of scope (explicit)

- **Live homelab cluster cutover** (Phase 3D / #155)
- **Source-side cleanup of `Talos-Homelab`** — happens later, after Phase 3D stabilizes
- **Office-lab repo creation** (Talos-Homelab #150) — out of scope per amended ADR
- **Plugin migration of `.claude/*` to `kube-agent-harness`** (Talos-Homelab #147) — handed off to harness-cwd session per separate plan
- **Adding new `os-talos` / `cni-cilium` provider plugins** to harness — roadmap, separate work

## 14. Risks + mitigations

| Risk | Mitigation |
|---|---|
| `migrate-application-multisource.sh` yq snippet misses an edge case (e.g., Application without `resources/` directory, helm chart with no overlay values) | Hand-verify against 3 representative Applications first; spot-check 5 random outputs after batch run |
| `oras pull` fails in CI (registry permission, network) | Built-in `secrets.GITHUB_TOKEN` should cover; fallback: provide a locked-down read-only token per repo |
| `vendor/base/` chmod -R a-w blocks subsequent oras pulls | bootstrap-base.sh re-chmods writable before extraction; verify on macOS + Linux |
| Test cluster diverges from production homelab in subtle ways (different disk layout, missing GPU, no Pi WAN edge), masking real cutover risk | Use sacrificial hardware that mirrors production where possible; if not, document cutover-time runtime probes (Phase 3D §"Runtime probes") to catch divergence at cutover |
| Talos `extraManifests` array merge between base + cluster patch overlay does not behave as expected | Verify with `make -C talos --dry-run gen-configs` post-edit; inspect the rendered controlplane config to confirm both URLs appear |
| `make day0` partially fails halfway through (e.g., apply succeeds but argocd-install times out) | All targets are idempotent; re-running `make day0` should resume cleanly. Document this in README. |
| Talos-Homelab and talos-homelab-cluster diverge during Phase 3C verification window | Limit window to ≤7 days; freeze non-critical PRs to Talos-Homelab during the test-cluster validation |

## 15. Verification grep helpers

```bash
# All Applications must reference both repos
grep -lE 'talos-platform-base\.git' kubernetes/overlays/homelab/**/application.yaml | wc -l   # expect 34
grep -lE 'talos-homelab-cluster\.git' kubernetes/overlays/homelab/**/application.yaml | wc -l # expect 34

# No Application should still reference the source repo
grep -rE 'Talos-Homelab\.git' kubernetes/overlays/homelab/   # expect empty

# .base-version contents
cat .base-version                                            # expect v0.1.0

# AppProjects dual-listing
for p in kubernetes/overlays/homelab/projects/*.yaml; do
  echo "=== $p ==="
  yq '.spec.sourceRepos' "$p"
done

# Vendor base read-only check
ls -la vendor/base/Makefile 2>/dev/null  # expect -r--r--r--
```

## 16. Issue updates after this plan merges

- **Talos-Homelab #148** body: rewrite to match the amended ADR — Phase 3B = non-destructive cluster repo creation. Reference this plan. Set `status: ready` once PR review of THIS plan is complete.
- **Talos-Homelab #155** body: ensure cilium-bootstrap URL discussion mentions the new repo URL (`raw.githubusercontent.com/Nosmoht/talos-homelab-cluster/...`).
- **No new issues** are created by this plan.

## 17. Author note

This plan is written by the Talos-Homelab Claude Code session in source-repo cwd. Execution stays in the same session — no handoff needed (unlike harness migration), because the operation is filter-repo + push + new GitHub repo creation, all of which the source-repo session can perform with its own permissions.

The plan is intentionally **gated on `talos-platform-base` v0.1.0 OCI artifact existing**, because §9.6 acceptance criterion #10 requires `make day0` to actually succeed end-to-end. The execution sequence for both plans is therefore:

1. Plan #1 (talos-platform-base) PR merge ✓ (done)
2. Plan #2 (this plan) PR review + merge ⏳
3. Plan #1 execution: filter-repo, gh repo create, tag v0.1.0, OCI publish ⏳
4. Plan #2 execution: filter-repo, multi-source rewrite, gh repo create, push, test-cluster verification ⏳
5. Phase 3D follow-up (Talos-Homelab #155) plans the live cutover ⏳
