# ADR: Multi-Repo Platform Split for Multi-Cluster Reuse

**Status**: Accepted
**Date**: 2026-04-27 (initial), amended 2026-04-29 (consumption mechanism + non-destructive migration)
**Supersedes**: implicit single-repo assumption in #66, #67, #84

## Context

This repository began as a single-cluster homelab GitOps tree. With the addition
of a second cluster (`office-lab`, corporate site, internal-only, 3 control-plane
+ 4 worker, no GPU, no WAN edge), the single-overlay / single-repo model becomes
insufficient:

1. Cluster identity (IPs, FQDNs, OIDC issuers, SOPS keys) is hardcoded in
   56+ files across `kubernetes/overlays/homelab/**`, making add-cluster a
   copy-paste exercise that drifts over time.
2. Tooling (28 skills, 6 agents, 7 hooks, 9 scripts) lives in `.claude/**`
   of this repo, but should be reused across both clusters without manual sync.
3. Issues #66 (cross-cluster trust model) and #67 (multi-cluster service
   consumption / PNI evolution) require an explicit federation model before
   further architectural commitment.

## Decision

Split the platform into **three logically distinct repositories**, created via
`git filter-repo` from snapshots of the existing `Talos-Homelab` repo. The
existing `Talos-Homelab` repo is **preserved unchanged as the source of truth
during migration** — it is not renamed and not destructively modified. The new
repos are validated end-to-end (full Day-0 bootstrap + Day-2 reconciliation)
before any decision about the original repo's fate is taken.

| Repo (target name) | Owner | Visibility | Contents |
|---|---|---|---|
| **`talos-platform-base`** (new repo, filter-repo snapshot of Talos-Homelab) | Nosmoht | personal | Talos templates, Cilium/Piraeus/KubeVirt/Kyverno/cert-manager Helm bases, ArgoCD bootstrap (parameterized), AGENTS.md core constraints. NO cluster identity. Published as OCI artifact at `ghcr.io/nosmoht/talos-platform-base:vX.Y.Z` on tag push. |
| **`kube-agent-harness`** (existing private repo, extended via filter-repo merge) | devobagmbh | private | `.claude/{skills,agents,rules,references,hooks}` extracted from `Talos-Homelab` snapshot + existing harness content. Acts as Claude-Code plugin for both cluster repos. |
| **`talos-homelab-cluster`** (new repo, filter-repo snapshot of Talos-Homelab) | Nosmoht | personal | `kubernetes/overlays/homelab/**`, `talos/nodes/`, `cluster.yaml` (cluster-identity SOT at repo root), homelab-specific ADRs. Consumes base via OCI artifact + plugin via `claude plugin install`. |
| **`talos-office-lab-cluster`** (new repo, scaffold from template) | corporate / devobagmbh | private | Office-lab cluster identity. Consumes base + plugin. **Out of scope for the current migration wave.** |
| **`Talos-Homelab`** (existing, unchanged during migration) | Nosmoht | personal | Source of truth for filter-repo snapshots. Continues to drive the live homelab cluster until the new `talos-homelab-cluster` is verified end-to-end. Fate decided in a separate follow-up after cutover. |

**Per-cluster trust model** (resolves #66): Each cluster is a self-rooted peer.
No shared CA, no shared SOPS key, no shared Vault. Per-cluster break-glass
kubeconfig.

**Per-cluster service consumption** (resolves #67): All capabilities are
cluster-local. The "shared platform service" class is intentionally empty.
PNI labels remain cluster-scoped.

**Codex CLI is no longer a primary support target for skills.** Claude Code's
plugin mechanism (project-level `claude plugin install` + global
`~/.claude/plugins/`) is the canonical distribution path. Codex users who want
skill access must clone `kube-agent-harness` separately and symlink — manual
fallback only.

## Component Classification — Consumer-in-Base / Backend-in-Overlay

Added 2026-04-30 as part of Phase 1.5 (#160) after Phase 1 (#146 / PR #153)
exposed a structural defect: the original Phase-1 classification used
**directory location** as the criterion (`kubernetes/base/` = base,
`kubernetes/overlays/<cluster>/` = cluster), which left six backend providers
parked in `base/` and three platform-generic components parked in overlay-only.

The corrected classification rule, adopted as a binding architectural
principle:

> Authentication and Observability are platform concerns and belong in base.
> Their backend storage is a tenant choice and belongs in overlay.

| Layer | Lives in | Examples |
|---|---|---|
| **Platform Consumer** (the *what*) | `talos-platform-base` | Dex (auth), Loki / Grafana / kube-prometheus-stack / Tetragon / Alloy (observability) |
| **Backend Provider** (the *how*) | per-cluster repo overlay | cloudnative-pg → Postgres for Dex; minio → S3 for Loki; redis-operator / strimzi-kafka-operator / omada-controller → tenant workloads |

PNI is the contract layer between the two. Base consumers declare a capability
via PNI labels (`platform.io/consume.cnpg-postgres`,
`platform.io/consume.s3-object`); the overlay binds the capability to a
concrete backend (cnpg cluster + secret, MinIO tenant + credentials).

**Corollary on PNI itself:** PNI is platform architecture and stays in base.
The RFC1918 except-lists in PNI egress CCNPs
(`ccnp-pni-internet-egress-consumer-egress.yaml` excluding `10/8`,
`172.16/12`, `192.168/16` from `0.0.0.0/0`) are the standard "don't reach
private networks" guard, generic across all clusters — they are NOT
homelab-specific hardcodes. The default Kubernetes ServiceCIDR API IP allowed
in `ccnp-pni-controlplane-egress-consumer-egress.yaml` is generic across
Talos-default clusters.

**Corollary on hardcoded backend coordinates:** No file under
`kubernetes/base/` may contain a concrete backend coordinate (Service DNS,
endpoint URL, credential secret name). Phase 1 missed
`kubernetes/base/infrastructure/loki/values.yaml:17` (`endpoint:
minio.minio.svc.cluster.local:443`); Phase 1.5 fixes this by moving the
endpoint into the overlay Helm-values patch.

This principle governs all future component-classification decisions: the
question is never "where does the directory live today?" but "is this the
platform's *what* or the tenant's *how*?"

## Consumption Mechanism — Day-0 Bootstrap vs. Day-2 Reconciliation

Cluster repos must consume the base repo at two distinct phases with
fundamentally different runtime contexts:

- **Day-0 (bootstrap)** — workstation-only, no in-cluster ArgoCD yet. Local
  `make` / `talosctl` / `kubectl` / `helm` calls read base files directly from
  the local filesystem (e.g. `talos/patches/common.yaml`,
  `kubernetes/bootstrap/argocd/root-application.yaml.tmpl`,
  `kubernetes/base/infrastructure/argocd/values.yaml`). Any consumption
  mechanism that requires a running ArgoCD is by definition unusable here.
- **Day-2 (reconciliation)** — ArgoCD is alive in the target cluster and
  reconciles app manifests against base + cluster overrides.

Day-0 mechanism: **OCI artifact published to `ghcr.io`, fetched by the cluster
repo's `make day0` into a gitignored `vendor/base/` directory.**

- On every tag push (`vX.Y.Z`) on `talos-platform-base`, a GitHub Action
  (`.github/workflows/oci-publish.yml`) packages the repo and pushes it as an
  OCI artifact to `ghcr.io/nosmoht/talos-platform-base:vX.Y.Z` (and
  `:latest`). Authentication via the workflow's built-in `GITHUB_TOKEN`.
- Each cluster repo carries a single-line `.base-version` file (e.g.
  `v1.2.3`). This is the SOT for the base pin in that cluster repo.
- `scripts/bootstrap-base.sh` reads `.base-version`, runs
  `oras pull ghcr.io/nosmoht/talos-platform-base:<v>` into `vendor/base/`,
  records the resolved version in `vendor/base/.version`, and `chmod -R a-w`
  the tree to flag it as read-only. The script is idempotent (no-op when the
  pinned version already matches).
- The cluster repo's top-level `Makefile` is a thin delegator that invokes
  `make -C vendor/base/talos gen-configs ENV=$(PWD)/cluster.yaml ...`. A
  `make day0` meta-target chains `bootstrap-base → gen-configs → apply →
  argocd-install → argocd-bootstrap` for new-cluster setup.
- `oras` CLI (https://oras.land) is a hard prerequisite on the workstation.
  `make` validates its presence before bootstrap.

Day-2 mechanism: **ArgoCD Multi-Source Application.** Each component
Application carries `spec.sources[]` with two entries:

- Source `base`: `repoURL: github.com/nosmoht/talos-platform-base.git`,
  `targetRevision: vX.Y.Z`, with a named `ref: base` and a path into
  `kubernetes/base/infrastructure/<comp>/`.
- Source `cluster`: `repoURL: github.com/nosmoht/talos-homelab-cluster.git`,
  `targetRevision: main`, path into `kubernetes/overlays/<tenant>/<comp>/`,
  with `helm.valueFiles` referencing `$base/values.yaml` plus
  `values-<tenant>.yaml` from the cluster repo.

The component's AppProject lists **both** repo URLs in `sourceRepos` (this is
the dual-listing pattern referenced in the original Phase-3A discussion).

Pin-drift between Day-0 (`.base-version`) and Day-2
(`spec.sources[base].targetRevision`) is checked in CI by
`scripts/check-base-pin-drift.sh` in the cluster repo. The check fails the
build when the two pins diverge.

### Alternatives considered (consumption mechanism)

| Alternative | Why rejected |
|---|---|
| **Git submodule** in cluster repo pointing at base | Solves Day-0 + Day-2 with one mechanism, but operational drag (`git submodule update --init` discipline, version bumps in two commits, ArgoCD `submoduleEnabled` global toggle). Not automatable cleanly. |
| **Kustomize remote URL** (`resources: [https://github.com/.../base.git/...?ref=vX]`) | Solves Day-2 cleanly but **fails Day-0**: `make`, `helm`, `yq` all read filesystem paths, not HTTP. Talos `make gen-configs` cannot consume a remote URL. |
| **Convention: parallel local clones** (`BASE_REPO_PATH ?= ../talos-platform-base`) | Solves Day-0 via convention but cluster repo is no longer self-containing — `git clone` alone is insufficient, the user must clone two repos in correct relative paths. Documentation burden, no enforcement. |
| **Git subtree** | Base files committed into cluster repo. Self-containing, but version bumps are merge-conflict-prone, repo size grows linearly with each bump, and `git log` mixes cluster + base history. |
| **Tarball download via curl + checksum** (no OCI) | Functionally identical to OCI but without the registry's content-addressable storage and signing primitives. Weaker integrity guarantees, no built-in version listing (`oras repo tags`). |

## Consequences

### Positive
- Cluster identity isolation matches per-cluster security boundary (per-repo
  SOPS, per-repo CI access, per-repo PR review).
- Skills/agents update once → both clusters benefit.
- Adding cluster N+1 = scaffold from template + per-cluster repo; no base-repo
  edits.
- Aligns with industry GitOps-fleet patterns (Flux fleet-infra, ArgoCD
  ApplicationSet-of-cluster-repos).
- Resolves long-standing Issues #66 and #67 with a concrete trust + consumption
  decision.

### Negative
- Up to 4 repos for 2 clusters = coordination overhead. Bumping a base
  component requires: (1) tag-push on `talos-platform-base` (CI auto-publishes
  OCI artifact), (2) `.base-version` bump + Argo `targetRevision` bump in each
  cluster repo. CI drift check enforces both pins move together.
- `git filter-repo` runs are required to materialize the new repos, but they
  operate on **throwaway clones** of `Talos-Homelab` — the original repo is
  not history-rewritten and remains a safe rollback target.
- `kubernetes/base/` and `talos/patches/common.yaml` cleanup of hardcoded
  homelab IPs was completed in Phase 1 (PR #153, merged 2026-04-28).
- AGENTS.md / CLAUDE.md split requires careful import structure (host repo
  `@`-imports plugin docs).
- Codex CLI user experience for skills degrades to "manual symlink".
- `oras` CLI is a new prerequisite on every cluster-repo developer
  workstation. `make` validates its presence at bootstrap-base time with a
  clear install hint (`brew install oras`).
- During the migration window (Phase 3A-3C) the live cluster runs from
  `Talos-Homelab` while the new repos exist in parallel — any commits to
  `Talos-Homelab` after the filter-repo snapshot are not reflected in the new
  repos until manually reconciled. Mitigation: keep the migration window
  short (~1 week) and freeze non-critical PRs to `Talos-Homelab` during
  Phase 3C verification.

### Neutral / Out of scope
- ArgoCD ApplicationSet-of-clusters not adopted — each cluster runs its own
  ArgoCD pointing at its own repo. Manageable for ≤5 clusters.
- Service mesh federation explicitly NOT planned.
- Cross-cluster Vault/Dex/SSO explicitly NOT planned.
- Office-lab has no WAN edge by design (internal-only); the homelab's
  `pi-public-ingress` architecture is homelab-specific and stays in
  `talos-homelab-cluster`. No "shared edge ingress" capability across clusters.

## Migration Plan (Phases)

**Migration strategy (amended 2026-04-29):** the existing `Talos-Homelab` repo
is **not modified destructively** during this migration. New repos are
created from `git filter-repo` *snapshots* of `Talos-Homelab` (clone → filter
→ push to new origin), leaving the original tree intact. The original repo
continues to drive the live homelab cluster until the new
`talos-homelab-cluster` repo passes a verified end-to-end Day-0 bootstrap
and Day-2 reconciliation in a separate validation pass. Only after that
verification does a follow-up issue decide the original repo's fate
(archive, rename, or retire). The 24-hour PR/branch freeze required by the
original ADR is therefore **not needed** — work on `Talos-Homelab` may
continue concurrently with migration.

### Phase 1 — Base de-homelab-ification (in current repo, ~1.5–2 weeks) — DONE 2026-04-28 (PR #153)

**Scope (initial discovery via pre-merge review of this ADR):**
- `talos/patches/common.yaml` — NTP/gateway IPs.
- `talos/Makefile:1-21` — `CLUSTER_NAME`, `ENDPOINT`, IP_node-XX map.
- `kubernetes/base/infrastructure/argocd/values.yaml` — hardcoded ArgoCD FQDN.
- `kubernetes/base/infrastructure/alloy/values.yaml` — hardcoded `cluster = "homelab"` Loki label.
- `kubernetes/base/infrastructure/**/namespace.yaml` and PNI CCNP files — `instance: homelab`, `part-of: homelab` labels (~14 files).
- `kubernetes/bootstrap/argocd/root-application.yaml` — hardcoded `repoURL` and `path` (raw YAML, not a template).

**Cluster-identity SOT location**: A single `cluster.yaml` at the repo **root** (gitignored) carries cluster name, API VIP, repo URL, overlay name, NTP server, node IPs, and hardware hints. `cluster.yaml.example` is committed as the schema template. The path is tool-agnostic — the repo must work with vanilla `make` + `kubectl` + `talosctl` even without any AI tooling installed; therefore the SOT does NOT live under `.claude/` (that namespace is reserved for tool integration only). This relocation from `cluster.yaml` is part of Phase 1.

**Parameterization mechanisms:**
- Talos Makefile reads from `cluster.yaml` via `yq -e` (no parallel `.mk` files; Makefile becomes a first-class consumer of the same SOT that ArgoCD Application CRs use). Multi-cluster usage: `make ENV=<path> gen-configs`. `ENV ?= ../cluster.yaml`.
- ArgoCD root-application: single template (`root-application.yaml.tmpl`) rendered via `envsubst` from `cluster.yaml` values into gitignored `_out/`. Template variables: `${REPO_URL}`, `${OVERLAY}`, `${CLUSTER_NAME}`, `${TARGET_REVISION:-main}`. Validation via `yq -e` (fail-fast on missing keys).
- NTP: per-cluster required value in `cluster.yaml` (`cluster.ntp_server`); `talos/patches/common.yaml` loses its `TimeSyncConfig` block; per-cluster patch template applies the value at gen-config time. Rejected sane-public-default: silent fallback when corporate firewall blocks public NTP would mask real time-sync breakage.
- Helm values cluster-specific tokens: extract into per-overlay `values-<cluster>.yaml` or kustomize `patchesStrategicMerge` overlays.
- Namespace labels: `instance:` and `part-of:` become per-overlay kustomize patches against base namespace manifests.

**Acceptance gate:** `grep -rn "homelab\|<homelab-mgmt-prefix>\|ntbc.io" kubernetes/base/ talos/Makefile` returns zero matches.

### Phase 2 — Plugin extraction (~1 week)

**Prerequisite spike (must complete before any history rewrite):**
- Verify Claude Code's plugin distribution schema actually supports: (a) `.claude/hooks/*.sh` registration through plugin install, (b) `paths:`-frontmatter rules with host-repo path resolution. If either is unsupported, hooks and `paths:`-rules stay per-host-repo (carve-out exception); only `paths:`-agnostic skills/agents/refs/rules ship in the plugin. Spike outcome documented in Phase-2 sub-issue.

**Migration steps (non-destructive against `Talos-Homelab`):**
- Clone `Talos-Homelab` into a throwaway directory.
- In that clone: `git filter-repo --path .claude/skills/ --path .claude/agents/ --path .claude/rules/ --path .claude/references/ --path .claude/hooks/` (carve-out paths trimmed per spike outcome).
- Push the filtered result as a new remote into `kube-agent-harness` via temporary branch + manual conflict resolution against existing harness content. Naming collisions resolved via explicit prefix rename map (e.g. `gitops-health-triage` → `homelab-gitops-health-triage` if duplicate).
- The original `Talos-Homelab` is not touched — `.claude/**` remains there for live operations until the new cluster repo replaces it.

**Operational note:** No freeze window is required. The filter-repo runs on a throwaway clone; the live `Talos-Homelab` repo continues to accept commits.

### Phase 3 — Cluster split + office-lab scaffold (~2 weeks)

**3A: New base repo creation (non-destructive)**
- Clone `Talos-Homelab` into throwaway dir.
- `git filter-repo --invert-paths --path kubernetes/overlays/homelab --path talos/nodes --path talos/patches/pi-firewall.yaml --path talos/patches/homelab.yaml --path docs/adr-pi-sole-public-ingress.md` (and other homelab-specific paths) — i.e. **keep base content, drop cluster-specific content**.
- Push as new repo `Nosmoht/talos-platform-base`.
- Add GitHub Action `.github/workflows/oci-publish.yml`: on tag push, build tarball + `oras push ghcr.io/nosmoht/talos-platform-base:<tag>` using `GITHUB_TOKEN`.
- Tag initial release `v0.1.0`.

**3B: New cluster repo creation (non-destructive)**
- Clone `Talos-Homelab` into separate throwaway dir.
- `git filter-repo --path kubernetes/overlays/homelab --path talos/nodes --path talos/patches/pi-firewall.yaml --path talos/patches/homelab.yaml --path docs/adr-pi-sole-public-ingress.md --path docs/runbook-cold-cluster-cutover.md --path docs/2026-04-15-fritzbox-macvlan-port-forward-exhaustion.md --path cluster.yaml.example` — i.e. **keep cluster-specific content, drop base content**.
- Push as new repo `Nosmoht/talos-homelab-cluster`.
- Add `.base-version` file pinning to `talos-platform-base@v0.1.0`.
- Add `scripts/bootstrap-base.sh` (oras pull → `vendor/base/`).
- Add thin top-level `Makefile` delegating to `vendor/base/Makefile` and `vendor/base/talos/Makefile`.
- Add `make day0` meta-target.
- Convert each `kubernetes/overlays/homelab/.../<comp>/application.yaml` from single-source to multi-source form (`spec.sources[base, cluster]`).
- Update each AppProject `sourceRepos` to list both `talos-platform-base.git` AND `talos-homelab-cluster.git`.

**3C: End-to-end verification (no live-cluster cutover yet)**
- Stand up a sacrificial test cluster (or use a Talos-in-VM lab) using only the new `talos-homelab-cluster` repo + OCI base.
- Verify `make day0` succeeds: `bootstrap-base → gen-configs → apply → argocd-install → argocd-bootstrap`.
- Verify ArgoCD reconciles all Multi-Source Applications without `ComparisonError`.
- Verify Cilium bootstrap manifest URL (raw.githubusercontent.com path) resolves correctly from the new base repo.
- Document outcome on the migration tracking issue. Only after this gate passes are the live-homelab-cutover steps below considered.

**3D: Live-cluster cutover (separate follow-up issue, NOT part of this ADR's current scope)**
The original `Talos-Homelab`-driven live cluster continues to operate during 3A/3B/3C. The cutover from `Talos-Homelab` repoURL → `talos-homelab-cluster` repoURL on the live ArgoCD `root` Application is filed as a **follow-up issue** with its own runtime-probe gate (pi-public-ingress / vault / dex / cert-manager / prometheus / hooks — see "Verification gate (Phase 3A done)" below for the probe list). This separation isolates migration risk: if 3C surfaces unexpected problems, the live cluster is unaffected.

**3E: Office-lab scaffold — OUT OF SCOPE for the current migration wave.**
Originally listed as Phase 3C; deferred until the homelab-cluster path is verified end-to-end. Will be tracked separately when office-lab hardware arrives.

### Verification gate (live cutover — Phase 3D follow-up)

These probes apply to the future live-cluster cutover (Phase 3D, separate follow-up issue), not to the test-cluster verification in Phase 3C. `argocd app diff` is necessary but **not sufficient** — it compares manifests, not running state. The cutover must additionally verify these never-blip services with external runtime probes:

- **pi-public-ingress** — external `curl -I https://<homelab-public-fqdn>/` returns 200/302 before/during/after cutover.
- **ingress-front** — internal LAN curl against gateway VIP returns 200.
- **vault** — `kubectl -n vault exec ... vault status` reports unsealed throughout.
- **dex** — OIDC discovery endpoint returns 200, kubectl OIDC login still succeeds.
- **cert-manager** — `kubectl get clusterissuer -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}'` is `True True` for all issuers.
- **kube-prometheus-stack** — `up{job="..."}` query against Prometheus shows continuous scrape (no gap > 60s).
- **PreSync/PostSync hooks** in vault-config-operator and similar must not re-run unintentionally; check `kubectl get jobs -A` before/after for unexpected new job creations.

If any probe shows degradation > 60s, abort the cutover and roll back via `kubectl patch application root` to the old repoURL.

### Verification gate (Phase 3A/3B/3C done — current ADR scope)
- `talos-platform-base` repo exists; tag `v0.1.0` published to `ghcr.io/nosmoht/talos-platform-base:v0.1.0` via OCI publish workflow.
- `kube-agent-harness` plugin installable via `claude plugin install`; Skill smoke-test passes from a clean clone.
- `talos-homelab-cluster` repo exists; `make day0` succeeds end-to-end against a test cluster; all Multi-Source Applications reconcile without `ComparisonError`; CI drift check between `.base-version` and Argo `targetRevision` is green.
- Original `Talos-Homelab` repo continues to drive the live homelab cluster, untouched.

### Verification gate (Phase 3D — live cutover, future)
- Existing homelab cluster reconciled by ArgoCD from new homelab-cluster repo with zero degradation > 60s on any of the runtime-probe services listed above.
- Original `Talos-Homelab` repo's fate (archive / rename / retire) decided in a separate follow-up after stable operation > 7 days on the new repo.

## Alternatives Considered

| Alternative | Why rejected |
|---|---|
| Multiple overlays in single repo (`overlays/homelab/`, `overlays/office-lab/`) | User explicitly judged unrealistic — too many homelab-specific concerns leak through cluster boundary; access control is per-repo on GitHub. |
| ArgoCD ApplicationSet-of-clusters in one repo | Same coupling concerns. ApplicationSet pattern works well at scale (≥10 clusters); for 2 clusters it's overkill and bundles unrelated trust domains. |
| Helm values branching per cluster | Doesn't address Talos node-config separation, doesn't address SOPS-key per-cluster, doesn't address PR-review boundary. |
| Keep monolith, defer multi-cluster | Postpones the problem; office-lab bringup blocks on this anyway. |

## References
- Issues: #66 (cross-cluster trust), #67 (multi-cluster service consumption),
  #84 (Claude harness primitives epic), #142 (closed — recent CI work that
  established the pattern of issue-driven changes)
- Memory: `feedback_harness_composition.md`, `feedback_harness_capability_driven.md`,
  `reference_harness_service_model.md`, `project_multi_repo_split_decided.md`
- External: ArgoCD ApplicationSet patterns
  (https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/),
  Flux fleet-infra reference architecture
  (https://github.com/fluxcd/flux2-multi-tenancy)
