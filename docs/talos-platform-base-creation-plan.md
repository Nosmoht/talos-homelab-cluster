# Plan — Create `talos-platform-base` Repo from `Talos-Homelab` Snapshot

**Status**: Ready for execution
**Created**: 2026-04-29
**Source repo**: `github.com/Nosmoht/Talos-Homelab` (this repo, ref: `main` at commit `51aefde` post-PR#156-merge)
**Target repo**: `github.com/Nosmoht/talos-platform-base` (NEW, to be created)
**ADR reference**: `docs/adr-multi-repo-platform-split.md` §"Phase 3A — New base repo creation (non-destructive)"
**Tracking issue**: Talos-Homelab #148 (will be referenced; full body needs amendment after this plan merges — see §16)

> This plan is **execution-ready** for the current Claude Code session in `Talos-Homelab` cwd. The filter-repo work runs on a throwaway clone; the original repo is never modified. The new repo is pushed to a fresh GitHub origin, validated against acceptance criteria, and tagged for the first OCI publish.

---

## 1. Context

The amended ADR (PR #154 merged 2026-04-29) decided:

- A new repo `Nosmoht/talos-platform-base` is created from a `git filter-repo --invert-paths` snapshot of `Talos-Homelab`. The snapshot drops cluster-specific content; what remains is the cluster-agnostic platform base.
- Base content is consumed by cluster repos via **OCI artifact** at `ghcr.io/nosmoht/talos-platform-base:vX.Y.Z`. A GitHub Action publishes the artifact on every tag push.
- Day-0 mechanism: cluster repo's `make day0` runs `oras pull` into a gitignored `vendor/base/` directory, pinned via a one-line `.base-version` file.
- Day-2 mechanism: ArgoCD Multi-Source Application — `spec.sources[base, cluster]`.
- Migration is **non-destructive**: `Talos-Homelab` continues to drive the live homelab cluster while the new repo is validated end-to-end against a sacrificial test cluster (Phase 3C). Only after validation does a separate Phase 3D issue plan the live-cluster cutover.

Phase 1 (PR #153, merged 2026-04-28) already de-homelab-ified the base layer in the current repo: `talos/Makefile` reads from `cluster.yaml`, ArgoCD bootstrap manifests are templated via `envsubst`, hardcoded homelab IPs in `kubernetes/base/` are gone (verified — `git grep homelab` against `kubernetes/base/` and `talos/Makefile` returns empty post-merge). This means the source tree is already mostly clean; the filter operation is largely about **removing cluster-specific paths**, not editing remaining files in place.

**Phase 1 already cleanly separated PNI** (Platform Network Interface) into base + overlay. The base ships only the generic *pattern* — namespace/pod label conventions, Kyverno enforcement policies, the 18 capability CCNPs (whose CIDR rules use IANA-reserved RFC1918 blocks `10/8`, `172.16/12`, `192.168/16` as RFC-standard "private network" exclusions, NOT cluster-specific homelab values), and the empty `capability-registry-configmap`. The overlay carries the only cluster-specific value: `cluster-config-cm.yaml` with the homelab's `external_hostname_pattern`. **PNI stays in base** — it is the architectural heart of the platform's tenant-network contract and is correctly cluster-agnostic post-Phase-1.

One known leftover hardcode that this plan handles explicitly:
- `talos/patches/controlplane.yaml:7` references the cluster's own raw GitHub URL for `kubernetes/bootstrap/cilium/cilium.yaml` — this is a cluster-specific URL because the rendered cilium.yaml carries cluster-specific Hubble TLS certificates.

Addressed in §5.3 (controlplane mutation) and §7.4 (post-filter cleanup).

## 2. Goal

After execution:
1. `Nosmoht/talos-platform-base` repo exists on GitHub, public, Apache-2.0 licensed, with preserved git history for retained paths.
2. The repo contains **only cluster-agnostic content** suitable for any consumer cluster repo — homelab, future office-lab, or other tenants.
3. A GitHub Action `oci-publish.yml` publishes a versioned OCI artifact to `ghcr.io/nosmoht/talos-platform-base:<tag>` on every tag push.
4. Initial release `v0.1.0` is tagged; OCI artifact is fetched-able from a sandbox cluster-repo via `oras pull`.
5. CI pipelines (`gitops-validate`, `hard-constraints-check`) are present and green on the new repo.
6. README, AGENTS.md, CLAUDE.md, and cluster.yaml.example are rewritten as platform-base perspective (consumer-facing, not homelab-operator).
7. **No regression to `Talos-Homelab`**. The original repo is untouched throughout.

## 3. High-level top-level path classification

| Path | Classification | Notes |
|---|---|---|
| `Makefile` | **BASE** | Phase 1 already templated against `cluster.yaml` |
| `kubernetes/base/` | **BASE** | All bases are cluster-agnostic post-Phase-1 |
| `kubernetes/bootstrap/argocd/` | **BASE (templates only)** | `*.tmpl` files retained; `_out/` is gitignored |
| `kubernetes/bootstrap/cilium/` | **MIXED** | `values.yaml`, `extras.yaml` → BASE; `cilium.yaml` → STAY |
| `kubernetes/overlays/homelab/` | **STAY** | All cluster-specific |
| `talos/Makefile`, `talos/versions.mk`, `talos/.schematic-ids.mk` | **BASE** | Already cluster.yaml-driven |
| `talos/patches/` | **MIXED** | See §5.3 |
| `talos/nodes/` | **STAY** | Per-node patches reference physical hardware |
| `talos/secrets.yaml` | **STAY** | Cluster-specific SOPS bundle |
| `talos/talosconfig` | **STAY** | Cluster-specific access |
| `talos/talos-factory-schematic-*.yaml` | **STAY** | Cluster-specific Image Factory inputs |
| `talos/AGENTS.md` | **BASE** (rewritten) | Trim cluster-specifics |
| `cluster.yaml.example` | **BASE** | Schema; needs minor rewrite to remove homelab examples |
| `cluster.yaml` | **STAY** (gitignored) | Per-cluster |
| `AGENTS.md` | **SPLIT** (rewritten) | See §7.1 |
| `CLAUDE.md` | **SPLIT** (rewritten) | See §7.2 |
| `README.md` | **SPLIT** (rewritten) | See §7.3 |
| `kubernetes/AGENTS.md` | **BASE** (rewritten) | Generic Kubernetes guidance |
| `policies/` | **BASE** | conftest rego policies are cluster-agnostic |
| `scripts/` | **MIXED** | See §5.4 |
| `.github/workflows/` | **MIXED** | See §5.5 |
| `.claude/` | **STAY** | Plugin migration tracked separately in #147 |
| `.codex/` | **STAY** | Cluster tooling config |
| `Plans/` | **STAY** | Working directory, ephemeral |
| `tests/` | (empty) | No action |
| `package.json`, `package-lock.json` | **STAY** | Tooling-only |
| `node_modules/` | (gitignored) | No action |
| `docs/` | **MIXED** | See §5.6 |

## 4. Source-state pin

The filter-repo runs against `Talos-Homelab` `main` at commit `51aefde` (commit `c9e8b32` of ADR-amendment + commit of merged plan PR #156). Verify the SHA before starting:

```bash
cd ~/workspace/Talos-Homelab
git fetch origin && git checkout main && git pull --ff-only
git rev-parse HEAD                # expect: 51aefde or later main
```

Any commits after `51aefde` are fine — the snapshot moves forward — but the path classifications in §5 assume the post-PR-#156 state.

## 5. Detailed path classification

### 5.1 `kubernetes/base/`

**All retained, no mutation.**

Initial draft proposed removing `kubernetes/base/infrastructure/platform-network-interface/` based on suspected hardcoded CIDRs. Verification proved that suspicion wrong:

- `ccnp-pni-internet-egress-consumer-egress.yaml` excludes the three IANA-reserved RFC1918 blocks from internet egress — this is the **standard "don't dial into private networks" guard**, generic across any cluster.
- `ccnp-pni-controlplane-egress-consumer-egress.yaml` allows egress to the **default Kubernetes ServiceCIDR API IP** (`kubernetes.default.svc` ClusterIP at the Talos default ServiceCIDR). Generic across any Talos-default cluster.

PNI is a **platform architecture pattern** (namespace/pod label contract, Kyverno enforcement policies, capability registry) and belongs in base. The only homelab-specific value is `external_hostname_pattern` in `cluster-config-cm.yaml`, which is already correctly placed in `kubernetes/overlays/homelab/infrastructure/platform-network-interface/`.

Edge case: a future tenant cluster that uses a non-default ServiceCIDR would need to overlay-override the API ClusterIP literal in `ccnp-pni-controlplane-egress`. Document this in the `talos-homelab-cluster` AGENTS.md (Mini-Projekt 3 plan) as a caveat for future office-lab onboarding; do not pre-empt by removing the literal — the homelab cluster will keep its existing values.

### 5.2 `kubernetes/bootstrap/`

| Path | Disposition |
|---|---|
| `argocd/namespace.yaml` | BASE — generic |
| `argocd/root-application.yaml.tmpl` | BASE — already `${VAR}`-parameterized |
| `argocd/root-project.yaml.tmpl` | BASE — already parameterized |
| `argocd/_out/` | BASE — gitignored, but path retained (no-op) |
| `cilium/values.yaml` | BASE — base Helm values, cluster-agnostic |
| `cilium/extras.yaml` | BASE — base extras |
| `cilium/cilium.yaml` | **STAY** — generated per cluster (Hubble TLS certs are cluster-specific) |

The `cilium.yaml` file should be removed from the base repo via filter-repo. Cluster repos run `make cilium-bootstrap` themselves; the resulting URL referenced by Talos `extraManifests` points at the **cluster repo**, not the base repo (see §5.3).

### 5.3 `talos/patches/`

| Patch | Disposition | Rationale |
|---|---|---|
| `common.yaml` | BASE | NTP block already removed in Phase 1; rest is generic |
| `controlplane.yaml` | **MUTATE** | Contains `extraManifests` URL pointing at the source repo. Strip the `extraManifests` block from base; the cluster repo's Talos config layers it back. See §7.4. |
| `drbd.yaml` | BASE | DRBD/LINSTOR generic config |
| `worker-gpu.yaml` | BASE | Generic GPU node patch |
| `worker-gvisor.yaml` | BASE | Generic gVisor patch |
| `worker-kubevirt.yaml` | BASE | Generic KubeVirt patch |
| `worker-pi.yaml` | BASE (verify) | Generic Raspberry Pi worker patch — content-audit during execution to confirm no homelab IP / FritzBox specifics remain |
| `pi-firewall.yaml` | **STAY** | References specific FritzBox / public-ingress topology |
| `cluster.yaml.tmpl` | BASE | NTP envsubst template introduced in Phase 1 |

### 5.4 `scripts/`

| Script | Disposition |
|---|---|
| `check-codex-config-placeholders.sh` | BASE |
| `check-mcp-config-portable.sh` | BASE |
| `discover_kustomize_targets.sh` | BASE |
| `issue-state.sh` | BASE |
| `mcp-github-wrapper.sh` | BASE |
| `render-cilium-bootstrap.sh` | BASE |
| `render_kustomize_safe.sh` | BASE |
| `run_conftest.sh` | BASE |
| `verify_sops_files.sh` | BASE |
| `configure-sg3428-via-omada-api.sh` | **STAY** (TP-Link SG3428-specific) |
| `discover_argocd_apps.sh` | **STAY** (reads cluster-specific manifests) |
| `run_trivy.sh` | **STAY** (currently homelab-specific; verify) |

### 5.5 `.github/workflows/`

| Workflow | Disposition |
|---|---|
| `gitops-validate.yml` | BASE — kustomize-render + secret-scan, generic |
| `hard-constraints-check.yml` | BASE — enforces No-Ingress / No-Endpoints, universal |
| `skill-frontmatter-check.yml` | **STAY** — validates `.claude/skills/`, irrelevant to base post-#147 |
| `sysctl-baseline-check.yml` | **STAY** — Talos-specific live-cluster sysctl drift detector |

### 5.6 `docs/`

Conservative classification — anything cluster-specific stays.

**BASE (migrate, with possible rewrite)**:
- `mcp-setup.md` — MCP server config, generic
- `issue-workflow.md` — issue state machine, generic
- `primitive-contract.md` — Claude Code primitive contract, generic
- `claude-code-guide.md` — Claude Code overview
- `claude-code-stack-audit.md` — generic audit doc
- `tetragon-deployment-verification.md` — generic Tetragon verification (verify content)
- `trivy-policy.md` — generic Trivy policy (verify content)
- `adr-multi-repo-platform-split.md` — keep as historical record (the ADR that justified the split)

**STAY (drop in filter-repo)**:
- All `hardware-analysis-node-*.md` (8 files)
- All `cilium-debug-*.md` (3 files)
- All `cilium-upgrade-*.md` (2 files)
- All `talos-upgrade-*.md` (4 files)
- `2026-04-15-fritzbox-macvlan-port-forward-exhaustion.md`
- `adr-pi-sole-public-ingress.md`
- `adr-ingress-front-stable-mac.md`
- `adr-storage-vlan-and-encryption.md`
- `adr-tenant-cluster-exposure.md`
- `runbook-cold-cluster-cutover.md`
- `runbook-drbd-vlan-binding.md`
- `platform-network-interface.md`
- `postmortem-gateway-403-hairpin.md`
- `postmortem-piraeus-operator-lease-outage-2026-04-10.md`
- `diagnosis-node-03-nic-2026-04-11.md`
- `day0-setup.md` (homelab-specific Day-0)
- `day2-operations.md` (homelab-specific Day-2)
- `kubevirt-vlan-networking-approaches-2026-03-29.md`
- `kubevirt-vm-platform-alternatives-2026-03-29.md`
- `kernel-tuning.md`, `kernel-tuning-gpu.md`
- `talos-maintenance-node-gpu-01-2026-03-25.md`
- `network-policy-remediation-todo.md`
- `plan-pr-2b-drbd-transport-tls.md`
- `ui-loadbalancer-ip-plan.md`
- `external-secrets-customer-guide.md`
- `agent-harness-audit-prompt.md`
- `freeze-learnings.md`
- `harness-skill-migration-plan.md` (Talos-Homelab-side handoff doc)
- `talos-platform-base-creation-plan.md` (this very document — Talos-Homelab-side plan, irrelevant to base)
- `MOVED-enterprise-blueprint.md`
- `enterprise-network-blueprint-implementation-roadmap.md`
- `implementation-log-phase1-network-blueprint.md`
- `kubernetes-review.md`, `kubernetes-review-todo.md`
- `security-code-review.md`
- `vault-config-operator-pki-migration.md`
- `linstor-state-pre-migration.txt`
- `nic-baseline-netgear-20260415.txt`, `nic-baseline-sg3428-20260416.txt`
- `omada-controller-post-config.cfg`
- `migration-plans/` (subfolder if exists)

**Manual-review during execution**: any doc not listed above that is found at filter time → conservative default = STAY.

## 6. Filter-repo command

The filter-repo uses `--invert-paths` (drop the listed paths, keep the rest). One large invocation:

```bash
cd /tmp
rm -rf base-snapshot
git clone --no-local https://github.com/Nosmoht/Talos-Homelab.git base-snapshot
cd base-snapshot
git rev-parse HEAD                                  # record source commit

git filter-repo --invert-paths \
  --path kubernetes/overlays/homelab \
  --path kubernetes/bootstrap/cilium/cilium.yaml \
  --path talos/nodes \
  --path talos/patches/pi-firewall.yaml \
  --path talos/secrets.yaml \
  --path talos/talosconfig \
  --path talos/talos-factory-schematic.yaml \
  --path talos/talos-factory-schematic-gpu.yaml \
  --path talos/talos-factory-schematic-pi.yaml \
  --path scripts/configure-sg3428-via-omada-api.sh \
  --path scripts/discover_argocd_apps.sh \
  --path scripts/run_trivy.sh \
  --path .github/workflows/skill-frontmatter-check.yml \
  --path .github/workflows/sysctl-baseline-check.yml \
  --path .claude \
  --path .codex \
  --path .auto-claude \
  --path Plans \
  --path package.json \
  --path package-lock.json \
  --path tests \
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
  --path docs/harness-skill-migration-plan.md \
  --path docs/talos-platform-base-creation-plan.md \
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

Expected outcome: `git log --oneline | wc -l` shows fewer commits than source (any commit that touched ONLY dropped paths is removed from history). `du -sh .` should be substantially smaller than source.

**Verify cleanliness post-filter** (must return empty or only references in the ADR):

```bash
git grep -nE 'homelab|ntbc\.io|node-pi-01|Nosmoht/Talos-Homelab' \
  -- ':!docs/adr-multi-repo-platform-split.md'

# Plus a literal-IP scan against the documented homelab range
git grep -nE '192\.168\.2\.[0-9]+|192\.168\.0\.0/16' \
  -- ':!docs/adr-multi-repo-platform-split.md'
```

If non-empty: investigate each match, edit the file in a post-filter commit, re-run.

## 7. Post-filter manual cleanup

After filter-repo, six files need editing before the first push.

### 7.1 `AGENTS.md` rewrite

Drop these sections entirely (they are homelab-operational, not platform-generic):
- `## Cluster Overview` (homelab IP table, hardware list)
- `## Key Terms` — keep platform-generic terms (PNI definition, AppProject, sync-wave, schematic, CCNP/CNP); drop homelab-physical terms (FritzBox, pi-public-ingress, macvlan, DRBD specifics, references to `node-pi-01`)
- `## Operational Patterns` — homelab-specific runbook references
- `## Operational Runbooks (Skills)` — `.claude/skills/` is gone post-#147
- `## Session-Start Ritual (both agents)` — describes homelab session pattern
- Trim `## Deltas vs Claude Code` to keep only generic Codex notes

Keep + lightly edit:
- `## Project Structure & Module Organization` (replace homelab specifics with base-repo structure)
- `## Build, Test, and Development Commands` (remove `make argocd-install` / `make argocd-bootstrap` references that assume a cluster context)
- `## Coding Style & Naming Conventions`
- `## Testing Guidelines`
- `## Commit & Pull Request Guidelines`
- `## Codex CLI Operating Rules` (mostly generic)
- `## OpenCode Compatibility Notes`
- `## Validation Checklist For Codex Changes`
- `## Hard Constraints` (universal cluster invariants — the heart of the base AGENTS.md)
- `## Tool-Agnostic Safety Invariants`
- `## Domain Rules — On-Demand Reference` (replace with placeholder pointing at the harness plugin, since base ships no rules)
- `## MCP Server Configuration`

Add a new section near the top:
```
## Repository Purpose

This is the cluster-agnostic platform base for the Talos-on-Kubernetes
deployment family. It provides Helm-base manifests, Talos machine-
config patches, ArgoCD bootstrap templates, and the validation pipeline
that any consumer cluster repo (e.g. talos-homelab-cluster,
talos-office-lab-cluster) builds upon via OCI artifact consumption.

It is NOT a runnable cluster. It does NOT contain cluster identity,
node IPs, secrets, or environment-specific overrides. Those live in
consumer cluster repos that pin a specific tag of this base.
```

### 7.2 `CLAUDE.md` rewrite

`CLAUDE.md` imports `AGENTS.md` and adds Claude-Code-specific bits. After §7.1 the import still works. Trim:
- `### Path-Scoped Auto-Loaded Rules` — `.claude/rules/*` will not exist post-#147; reword as "future plugin-shipped rules will register here"
- `### Hooks (PreToolUse / PostToolUse enforcement)` — drop the homelab-specific table or note plugin-source
- `### Subagents` — drop or note plugin-source
- `### Context Architecture` — trim homelab-specifics

The base-repo `CLAUDE.md` is short (~40 lines after trim) and points to the harness plugin for runtime extensions.

### 7.3 `README.md` rewrite

```markdown
# talos-platform-base

Cluster-agnostic GitOps platform base for Talos-on-Kubernetes deployments.

## What this provides

- Talos machine-config patches (control-plane, workers, GPU, KubeVirt, gVisor)
- Talos Makefile with cluster.yaml-driven multi-cluster generation
- Helm bases for ArgoCD, Cilium, Piraeus, Kyverno, cert-manager, vault, dex,
  kube-prometheus-stack, alloy, loki, NFD, KubeVirt-CDI, Tetragon, MinIO,
  Strimzi, CloudNativePG, Redis, Local-Path Provisioner, Metrics Server,
  NVIDIA-DCGM, NVIDIA Device Plugin, Omada Controller (parameterized)
- Parameterized ArgoCD bootstrap (root-application.yaml.tmpl, root-project.yaml.tmpl)
- conftest policies, validate-gitops pipeline, hard-constraints checks
- Pre-commit hooks for SOPS encryption + secret-scan

## What this does NOT provide

- Cluster identity (IPs, FQDNs, OIDC issuers)
- Node configurations
- SOPS-encrypted secrets
- Environment overrides (Helm value overrides, kustomize patches)
- Live ArgoCD or live cluster

Those live in **consumer cluster repos**.

## How consumers use this

Consumer cluster repos (e.g. talos-homelab-cluster, future
talos-office-lab-cluster) pin a specific tag of this base via:

1. A one-line `.base-version` file (e.g. `v0.1.0`)
2. A `scripts/bootstrap-base.sh` that runs `oras pull
   ghcr.io/nosmoht/talos-platform-base:<v>` into a gitignored
   `vendor/base/` directory
3. ArgoCD Multi-Source Application manifests with `spec.sources[]`
   listing both the cluster repo and this base repo

See: [ADR — Multi-Repo Platform Split](./docs/adr-multi-repo-platform-split.md).

## Versioning

Tags follow `vMAJOR.MINOR.PATCH`. Each tag triggers a GitHub Action
that publishes the OCI artifact to
`ghcr.io/nosmoht/talos-platform-base:<tag>` (and `:latest`).

Breaking changes bump MAJOR. New components or new patch options bump
MINOR. Helm-base value-default changes that are not breaking bump
PATCH.

## License

Apache-2.0.
```

### 7.4 `talos/patches/controlplane.yaml` mutation

Strip the `extraManifests:` block. The base repo's controlplane patch should not assume any specific Cilium-bootstrap URL. The consumer cluster repo applies a layer over this patch with its own `extraManifests:` block pointing at its own rendered cilium.yaml.

Before:
```yaml
machine:
  install:
    extraKernelArgs: ...
cluster:
  inlineManifests: ...
  extraManifests:
    - https://raw.githubusercontent.com/<source-repo>/main/kubernetes/bootstrap/cilium/cilium.yaml?v=<version>
```

After (in base):
```yaml
machine:
  install:
    extraKernelArgs: ...
cluster:
  inlineManifests: ...
  # extraManifests is set by the consumer cluster repo's controlplane patch overlay.
  # See the consumer's docs/day0-setup.md for the layering pattern.
```

### 7.5 `cluster.yaml.example` rewrite

Verify the example uses **placeholder** values, not homelab specifics. If currently it shows literal RFC1918 IPs from the homelab range, replace with comments like `<api-vip>`, `<ntp-ip>`, `<node-name>`. Output of `cat cluster.yaml.example` after rewrite must contain no literal IP from any RFC1918 range; only placeholders.

### 7.6 `kubernetes/AGENTS.md` rewrite

Currently this file is a sub-AGENTS.md focused on `kubernetes/` directory rules. Trim homelab-specifics if any, otherwise retain.

## 8. New files to add post-filter

### 8.1 `LICENSE`

Apache-2.0 license text (not currently present in source). Match the harness repo's choice.

### 8.2 `CHANGELOG.md`

Initial entry:
```markdown
# Changelog

## v0.1.0 — 2026-04-29

Initial release. Snapshot of Talos-Homelab `main` at commit `<source-sha>`,
filtered to retain only cluster-agnostic content per
`docs/adr-multi-repo-platform-split.md`.

### Components

- 24 Helm-base infrastructure components (see `kubernetes/base/infrastructure/`)
- Talos machine-config patches: common, controlplane (without extraManifests),
  drbd, worker-{gpu,gvisor,kubevirt,pi}, cluster.yaml.tmpl
- Talos Makefile with multi-cluster generation
- ArgoCD bootstrap templates (parameterized via envsubst)
- conftest policies (k8s.rego, argocd.rego)
- gitops-validate + hard-constraints-check CI workflows
- 9 cluster-agnostic scripts

### Removed from source

- All homelab-specific overlays, node configs, encrypted bundles, talosconfig
- Homelab-specific docs (hardware analyses, cilium-debug logs, ADRs)
- Homelab-specific scripts (configure-sg3428, run_trivy)
- Homelab-specific workflows (skill-frontmatter-check, sysctl-baseline-check)
- `.claude/`, `.codex/`, `Plans/` (tooling dirs, not platform content)
```

### 8.3 `.github/workflows/oci-publish.yml`

```yaml
name: Publish OCI artifact

on:
  push:
    tags:
      - 'v*'

permissions:
  contents: read
  packages: write

jobs:
  publish:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Resolve tag
        id: tag
        run: echo "tag=${GITHUB_REF_NAME}" >> $GITHUB_OUTPUT

      - name: Install oras
        uses: oras-project/setup-oras@v1
        with:
          version: 1.2.0

      - name: Login to ghcr.io
        run: |
          echo "${{ secrets.GITHUB_TOKEN }}" \
            | oras login ghcr.io -u ${{ github.actor }} --password-stdin

      - name: Build tarball
        run: |
          mkdir -p _release
          tar --exclude='./.git' \
              --exclude='./.github' \
              --exclude='./_release' \
              -czf "_release/talos-platform-base-${{ steps.tag.outputs.tag }}.tar.gz" .

      - name: Generate checksums
        working-directory: _release
        run: sha256sum *.tar.gz > checksums.txt

      - name: Push OCI artifact
        working-directory: _release
        run: |
          oras push \
            "ghcr.io/${{ github.repository_owner }}/talos-platform-base:${{ steps.tag.outputs.tag }}" \
            --artifact-type "application/vnd.talos-platform-base.v1+tar" \
            "talos-platform-base-${{ steps.tag.outputs.tag }}.tar.gz:application/gzip" \
            "checksums.txt:text/plain"

      - name: Tag :latest
        run: |
          oras tag \
            "ghcr.io/${{ github.repository_owner }}/talos-platform-base:${{ steps.tag.outputs.tag }}" \
            latest
```

### 8.4 `.github/CODEOWNERS` (optional)

```
* @Nosmoht
```

## 9. Execution mechanics

The order matters; each block is verified before the next runs.

### 9.1 Throwaway clone + filter-repo

```bash
cd /tmp
rm -rf base-snapshot
git clone --no-local https://github.com/Nosmoht/Talos-Homelab.git base-snapshot
cd base-snapshot
echo "Source commit: $(git rev-parse HEAD)"

# §6 filter-repo block
git filter-repo --invert-paths \
  --path kubernetes/overlays/homelab \
  ... (full list from §6)

# Verify cleanliness
git grep -nE 'homelab|ntbc\.io|node-pi-01|Nosmoht/Talos-Homelab' \
  -- ':!docs/adr-multi-repo-platform-split.md' || echo "CLEAN-1"
git grep -nE '192\.168\.2\.[0-9]+|192\.168\.0\.0/16' \
  -- ':!docs/adr-multi-repo-platform-split.md' || echo "CLEAN-2"
```

### 9.2 Post-filter cleanup commits

```bash
# §7.4 controlplane patch mutation
$EDITOR talos/patches/controlplane.yaml   # strip extraManifests block per §7.4
git commit -s talos/patches/controlplane.yaml \
  -m "chore(talos): strip cluster-specific extraManifests from controlplane base

The Cilium bootstrap manifest URL is cluster-specific because the
rendered cilium.yaml carries cluster-specific Hubble TLS certificates.
Consumer cluster repos layer their own controlplane patch with the
appropriate extraManifests block."

# §7.1, §7.2, §7.3, §7.5, §7.6 doc rewrites
$EDITOR AGENTS.md CLAUDE.md README.md cluster.yaml.example kubernetes/AGENTS.md
git add AGENTS.md CLAUDE.md README.md cluster.yaml.example kubernetes/AGENTS.md
git commit -s -m "docs: rewrite AGENTS/CLAUDE/README for platform-base perspective"

# §8.1, §8.2 new files
$EDITOR LICENSE CHANGELOG.md
git add LICENSE CHANGELOG.md
git commit -s -m "chore: add LICENSE (Apache-2.0) and initial CHANGELOG"

# §8.3 OCI publish workflow
mkdir -p .github/workflows
$EDITOR .github/workflows/oci-publish.yml
git add .github/workflows/oci-publish.yml
git commit -s -m "ci: add oci-publish workflow for ghcr.io tag releases"
```

### 9.3 Create + push to new GitHub origin

```bash
gh repo create Nosmoht/talos-platform-base --public \
  --description "Cluster-agnostic Talos-on-Kubernetes platform base"
git remote add origin git@github.com:Nosmoht/talos-platform-base.git
git push -u origin main
```

### 9.4 Verify CI on initial main push

```bash
gh run list --repo Nosmoht/talos-platform-base --limit 5
gh run watch
```

`gitops-validate.yml` and `hard-constraints-check.yml` should both run and pass.

### 9.5 Tag v0.1.0 and trigger OCI publish

```bash
git tag -a v0.1.0 -m "v0.1.0 — initial release from Talos-Homelab snapshot"
git push origin v0.1.0
gh run watch  # observe oci-publish.yml run
```

After completion:
```bash
oras manifest fetch ghcr.io/nosmoht/talos-platform-base:v0.1.0 | jq .
oras pull ghcr.io/nosmoht/talos-platform-base:v0.1.0 --output /tmp/oci-pulled
ls /tmp/oci-pulled
sha256sum /tmp/oci-pulled/*.tar.gz
diff <(grep talos-platform-base /tmp/oci-pulled/checksums.txt) \
     <(cd /tmp/oci-pulled && sha256sum *.tar.gz | grep talos-platform-base)
```

### 9.6 Sandbox consumption test

```bash
mkdir -p /tmp/sandbox-cluster
cd /tmp/sandbox-cluster
git init -q
echo "v0.1.0" > .base-version

cat > scripts/bootstrap-base.sh <<'SCRIPT'
#!/bin/bash
set -euo pipefail
VERSION=$(cat .base-version)
mkdir -p vendor
cd vendor
oras pull ghcr.io/nosmoht/talos-platform-base:"$VERSION"
tar xzf talos-platform-base-"$VERSION".tar.gz -C .
mv ./* base/ 2>/dev/null || true
SCRIPT
chmod +x scripts/bootstrap-base.sh
./scripts/bootstrap-base.sh

ls vendor/base/                 # should show kubernetes/, talos/, Makefile, etc.
make -C vendor/base/talos --dry-run gen-configs ENV=$(pwd)/cluster.yaml \
  || echo "Expected: missing cluster.yaml — proves the Makefile reads from ENV"
```

The sandbox test is a smoke-test only; full Day-0 verification happens in Mini-Projekt 3 against `talos-homelab-cluster`.

## 10. Acceptance criteria

1. `Nosmoht/talos-platform-base` repo exists on GitHub, public, with branch `main`
2. `git log --oneline | wc -l` on the new repo > 0 and < source repo's count
3. Cleanliness greps from §6 return empty (modulo the documented ADR exception)
4. `make -C talos --dry-run gen-configs ENV=/tmp/sandbox-cluster.yaml` succeeds with a hand-written sandbox `cluster.yaml`
5. `kubectl kustomize kubernetes/base/infrastructure/<each-component>/` succeeds for all 24 components
6. CI workflows `gitops-validate.yml` and `hard-constraints-check.yml` are green on initial main push
7. Tag `v0.1.0` exists; `oci-publish.yml` workflow run succeeds
8. `oras manifest fetch ghcr.io/nosmoht/talos-platform-base:v0.1.0` returns a manifest
9. `oras pull` extracts a tarball that contains `Makefile`, `kubernetes/base/`, `talos/Makefile`, `talos/patches/common.yaml`, etc.
10. SHA256 of the extracted tarball matches the published `checksums.txt`
11. `:latest` tag points at `v0.1.0` after publish
12. README, AGENTS.md, CLAUDE.md, cluster.yaml.example all contain platform-base perspective (no homelab specifics)
13. `kubernetes/base/infrastructure/platform-network-interface/` is **PRESENT** in the new repo (PNI is the platform's tenant-network-contract pattern, kept in base)
14. `talos/patches/controlplane.yaml` does not contain `extraManifests:` block
15. `Talos-Homelab` repo unchanged: `git log` on `Talos-Homelab/main` shows the same commits before and after this work

## 11. Rollback path

The throwaway clone is in `/tmp/base-snapshot`. Until §9.3 (`gh repo create + git push`) runs, rollback is `rm -rf /tmp/base-snapshot` — no remote state.

After §9.3 but before §9.5: `gh repo delete Nosmoht/talos-platform-base --yes` reverses the push.

After §9.5 (tag + OCI artifact published): rollback is more involved.
- Delete the tag: `git push --delete origin v0.1.0 && git tag -d v0.1.0`
- Delete the OCI artifact via ghcr.io UI or `gh api`
- Optional `gh repo delete` for full removal

Any consumer pinning `v0.1.0` after publication is unaffected by tag/artifact deletion in the sense that their `oras pull` will fail; no silent rollback. Coordinate with consumer-side state if any consumers exist; in the migration scope, no consumer exists yet (the cluster repo is Mini-Projekt 3, downstream).

`Talos-Homelab` is **never modified** by any step in this plan.

## 12. Connection to Mini-Projekt 3

Mini-Projekt 3 (Talos-Homelab #148, post-amendment) creates the consumer cluster repo. It needs to:

- Pin `.base-version` to whatever this plan tags (initially `v0.1.0`)
- Layer its own `talos/patches/controlplane.yaml` over the base controlplane patch, providing the cluster-specific `extraManifests:` URL pointing at the consumer's own rendered `cilium.yaml`
- Carry `kubernetes/overlays/homelab/infrastructure/platform-network-interface/` (the cluster-specific PNI overlay: Application CR, kustomization, `cluster-config-cm.yaml` with the homelab `external_hostname_pattern`). The base PNI components are consumed via Multi-Source Application; the overlay only adds cluster-specific values.
- Carry `talos/nodes/`, all cluster-specific encrypted bundles (talosconfig, the SOPS-encrypted secrets file under `talos/`), all homelab-specific docs from the §5.6 STAY list, all homelab-specific scripts and workflows
- Author Multi-Source Application manifests for each component in `kubernetes/overlays/homelab/infrastructure/<comp>/application.yaml`

Mini-Projekt 3 is a separate plan in this same `docs/` directory, written next.

## 13. Out of scope (explicit)

- **Removing migrated content from `Talos-Homelab`**. The original repo stays untouched. Cleanup is a follow-up in Phase 3D, after live cluster cutover stabilizes.
- **Live cluster cutover.** Tracked separately in Talos-Homelab #155.
- **Office-lab repo creation** (Talos-Homelab #150). Out of scope per amended ADR.
- **Plugin migration** (Talos-Homelab #147). Handed off to harness-cwd session per separate plan.

## 14. Risks + mitigations

| Risk | Mitigation |
|---|---|
| filter-repo silently corrupts file content (rare with `--path-glob`) | Spot-check 5 random files post-filter; verify size + sha256 against source |
| `oras push` permission failure (GHCR_TOKEN scoping) | Workflow uses built-in `secrets.GITHUB_TOKEN` with `packages: write` |
| `worker-pi.yaml` retains homelab-specific iptables / IPs | §5.3 mandates content-audit during execution; if found, classify STAY |
| Phase-1 cleanup missed a hardcoded reference | Cleanliness grep in §6 catches it; manual edit in post-filter cleanup |
| Cilium bootstrap URL in cluster repo points at the OLD source URL after Mini-Projekt 3 starts | Mini-Projekt 3's own filter+post-mutation handles this; this plan only ensures the URL is gone from base |
| Future tenant cluster uses non-default ServiceCIDR | `ccnp-pni-controlplane-egress` API IP literal must be overlay-overridden; document as caveat in Mini-Projekt 3 plan |
| `gh repo create` fails due to user-org mismatch | Run `gh auth status` first; ensure default account is `Nosmoht` |

## 15. Verification grep helpers

```bash
# Hardcoded homelab strings
git grep -nE 'homelab|ntbc\.io|node-(01|02|03|04|05|06|gpu-01|pi-01)|Nosmoht/Talos-Homelab' \
  -- ':!docs/adr-multi-repo-platform-split.md'

# RFC1918-IP literals (homelab range)
git grep -nE '192\.168\.2\.[0-9]+|192\.168\.0\.0/16' \
  -- ':!docs/adr-multi-repo-platform-split.md'

# Stale references to removed paths
git grep -nE 'configure-sg3428|run_trivy\.sh|cilium\.yaml.*v=' \
  -- ':!docs/adr-multi-repo-platform-split.md'

# Conftest+kustomize sanity (CI mirrors this)
make validate-gitops || true

# Per-base-component kustomize render sanity
ls kubernetes/base/infrastructure | while read c; do
  echo "=== $c ==="
  kubectl kustomize "kubernetes/base/infrastructure/$c/" >/dev/null && echo OK
done
```

## 16. Issue updates after this plan merges

- **Talos-Homelab #148** body: rewrite per amended ADR (Phase 3A is now non-destructive base creation, not homelab-cluster split). Reference this plan. Set `status: ready`.
- **Talos-Homelab #155** body: ensure the `extraManifests:` URL discussion mentions the new base repo URL (raw.githubusercontent.com path under the new `talos-platform-base` repo) instead of the source repo's URL.
- **No new issues** are created by this plan.

## 17. Author note

This plan is written by the Talos-Homelab Claude Code session in the source-repo cwd. Execution stays in the same session — no handoff needed (unlike the harness migration plan), because the operation is filter-repo + push to a new GitHub repo, both of which the source-repo session can perform with its own permissions.
