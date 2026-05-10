# Repository Guidelines

## Project Structure & Module Organization
- `kubernetes/base/infrastructure/`: base Helm values and namespace/kustomization manifests per infrastructure component.
- `kubernetes/overlays/homelab/`: environment-specific Argo CD Applications, project definitions, Gateway API resources, and app/infrastructure overlays.
- `kubernetes/bootstrap/argocd/`: bootstrap manifests applied before GitOps reconciliation.
- `talos/`: Talos machine config inputs (`nodes/`, `patches/`), generated outputs, and Talos lifecycle automation.
- `docs/`: operational runbooks, reviews, and hardware/kernel notes.

## Build, Test, and Development Commands
- `make argocd-install`: installs Argo CD and required SOPS key secret.
- `make argocd-bootstrap`: installs Argo CD, then applies root project/application.
- `make -C talos cilium-bootstrap`: renders `kubernetes/bootstrap/cilium/cilium.yaml` from the Cilium chart using `CILIUM_VERSION` in `talos/versions.mk`.
- `make -C talos cilium-bootstrap-check`: validates bootstrap Cilium manifest has no static Hubble TLS secret resources.
- `make -C talos gen-configs`: generates Talos node configs.
- `make -C talos apply-all`: applies generated Talos configs to all nodes.
- `make -C talos dry-run-all`: validates Talos config application without changing nodes.
- `make -C talos schematics`: creates Talos Image Factory schematic IDs.

Example flow:
```bash
make -C talos gen-configs
make -C talos apply-node-01
make argocd-bootstrap
```

## Coding Style & Naming Conventions
- Use YAML with 2-space indentation; keep keys and list nesting consistent with existing manifests.
- Prefer one component per directory (`.../component/{application.yaml,kustomization.yaml,values.yaml}`).
- Name commits and change scopes by subsystem (`argocd`, `dex`, `monitoring`, `cilium`, `talos`).
- Keep secrets in `*.sops.yaml`; do not commit decrypted secret material.

## Testing Guidelines
- There is no formal unit-test framework in this repo; validation is manifest and apply focused.
- Before opening a PR, run relevant dry-runs and reconcile checks:
  - `make -C talos dry-run-all`
  - `kubectl kustomize kubernetes/overlays/homelab` (or equivalent local render)
- For monitoring/network policy/dashboard changes, include evidence from runtime validation (e.g., Argo CD sync state or scrape success).

## Commit & Pull Request Guidelines
- Follow the observed Conventional Commit style: `type(scope): short imperative summary` (e.g., `fix(dex): remove hostedDomains to avoid hd claim failures`).
- Keep commits focused and logically grouped; avoid mixing Talos, bootstrap, and app changes without a clear reason.
- PRs should include:
  - what changed and why,
  - impacted paths/components,
  - rollout/verification steps,
  - linked issue (if applicable),
  - screenshots only for UI/visual dashboard changes.

## Codex CLI Operating Rules (Important)
- This file (`AGENTS.md`) is the canonical source of truth. See §Hard Constraints below for cluster-wide invariants.
- Never `kubectl apply` Argo CD-managed resources for rollout; commit to git and let Argo CD reconcile.
- The only direct-apply exception is bootstrap content under `kubernetes/bootstrap/`.
- Keep secrets encrypted in `*.sops.yaml`; never add plaintext secret material to git.
- For Talos operations, use explicit node endpoint flags (`talosctl -n <node-ip> -e <node-ip>`) when running commands manually.
- Keep one taint policy on GPU node `node-gpu-01`: `nvidia.com/gpu=present:NoSchedule`; avoid broad tolerations beyond documented patterns.

## Platform Network Interface (PNI) Rules
- Default to PNI for consumer-to-platform connectivity; do not begin with ad-hoc custom CNPs for managed services.
- Consumer namespace contract (namespace-level labels):
  - `platform.io/network-interface-version: v1`
  - `platform.io/network-profile: restricted|managed|privileged`
  - explicit capability opt-in labels: `platform.io/consume.<capability>: "true"`
- **Consumer pod contract (pod-level labels, in addition to namespace labels):**
  - Every pod that consumes a PNI capability must carry `platform.io/capability-consumer.<capability>: "true"` on the pod template (not only the namespace).
  - Namespace labels gate the `network-profile` posture; pod-level `capability-consumer.*` labels are matched by each CCNP's `endpointSelector` to actually allow the traffic.
  - Missing pod-level label → Cilium drops outbound traffic with "Policy denied" even if the namespace is correctly labeled. This failure mode is invisible until strict enforcement activates (e.g. after a Cilium agent restart).
  - Set via Helm `podLabels` / `podMetadata.labels` in values; see `kubernetes/overlays/homelab/infrastructure/kube-prometheus-stack/values.yaml` and `kubernetes/base/infrastructure/loki/values.yaml` for reference patterns.
- Treat `network-profile` as baseline posture only; core service access must be capability-scoped.
- Never set provider-reserved labels in consumer manifests: `platform.io/provider`, `platform.io/managed-by`, `platform.io/capability`.
- Keep reusable capability policies platform-owned under infrastructure overlays; avoid creating per-consumer policy copies in operator namespaces.
- If a workload does not use PNI, require self-managed CNP/KNP ownership and make that tradeoff explicit in docs/PR.
- For new capabilities or behavior changes, update `docs/platform-network-interface.md` in the same change.

## OpenCode Compatibility Notes
- OpenCode agents should follow the same PNI contract and capability opt-in flow as Codex/Claude.
- Keep agent instructions tool-agnostic: enforce labels/capabilities and policy ownership boundaries, not agent-specific command wrappers.

## Validation Checklist For Codex Changes
- For overlay/root changes, run:
  - `kubectl kustomize kubernetes/overlays/homelab`
  - `kubectl apply -k kubernetes/overlays/homelab --dry-run=client`
- If editing Kyverno `ClusterPolicy` resources, run:
  - `make validate-kyverno-policies`
- For Talos config changes, run:
  - `make -C talos gen-configs`
  - `make -C talos dry-run-all` (or affected node dry-run target)
- If editing kustomizations that use KSOPS generators, validate with plugin-enabled kustomize (`--enable-alpha-plugins --enable-exec`) where required.
- Include runtime verification evidence for network policy/monitoring changes (Argo CD sync status, scrape success, policy-drop checks).

## Cilium Bootstrap/Talos Nuance
- `kubernetes/bootstrap/cilium/cilium.yaml` is tied to Talos `extraManifests`; avoid ad-hoc `kubectl apply` drift fixes.
- Reconcile Cilium bootstrap changes via Talos workflow (`make -C talos upgrade-k8s`) so control plane `extraManifests` stay consistent.
- If this file contains generated TLS artifacts (for example Hubble cert secrets), track expiry and rotate before expiration as part of planned maintenance.

---

## Hard Constraints

CLAUDE.md imports this file via `@AGENTS.md`. Both tools treat this section as canonical. Do NOT relax these without repo-maintainer approval.

- **No SecureBoot** — `metal-installer-secureboot` causes boot loops; always use `metal-installer`
- **No `debugfs=off`** — causes "failed to create root filesystem" boot loop in Talos
- **Gateway API only** — no `kind: Ingress` or Ingress controllers; use HTTPRoute/TLSRoute
- **EndpointSlices only** — `kind: Endpoints` deprecated since Kubernetes v1.33.0; use `EndpointSlice`
- **Commit and push every successful tested change immediately** — do not batch at end of session
- **NEVER `kubectl apply` ArgoCD-managed resources** — commit to git, push, let ArgoCD sync; only exception: one-time bootstrap AppProjects (`kubernetes/bootstrap/`)
- **Kubernetes recommended labels on all resources** — `app.kubernetes.io/{name,instance,version,component,part-of,managed-by}`
- **File naming conventions** — `cnp-<component>.yaml`, `ccnp-<description>.yaml`; component dirs must match ArgoCD Application name
- **PNI first** for consumer-to-platform connectivity — do not begin with ad-hoc CNPs for managed platform services
  - Consumer labels: `platform.io/network-interface-version: v1`, `platform.io/network-profile: restricted|managed|privileged`, `platform.io/consume.<capability>: "true"`
  - Never set provider-reserved labels in consumer manifests: `platform.io/provider`, `platform.io/managed-by`, `platform.io/capability`

## Cluster Overview

Software versions pinned in `talos/versions.mk`. Full topology in `cluster.yaml` (gitignored — schema: `cluster.yaml.example`).

**Codex CLI**: read `cluster.yaml` at session start — contains node IPs, hardware layout, network topology. Claude Code loads this on demand via skill references.

| Role | Nodes | IPs | Hardware |
|------|-------|-----|----------|
| Control Plane | node-01..03 | 192.168.2.61-63 | Lenovo ThinkCentre M910q |
| Workers | node-04..06 | 192.168.2.64-66 | M910q (04-05), M920q (06) |
| GPU Worker | node-gpu-01 | 192.168.2.67 | Custom build, r8152 USB NIC |
| Pi / WAN Edge | node-pi-01 | per `cluster.yaml` | Raspberry Pi 4B, arm64 — sole WAN entrypoint since 2026-04-17, taint-isolated |

- API VIP: `192.168.2.60` · Gateway VIP: `192.168.2.70` · PodCIDR: `10.244.0.0/16`
- Storage: LINSTOR/Piraeus CSI (DRBD, NVMe nodes via NFD label `feature.node.kubernetes.io/storage-nvme.present=true`)
- Networking: Cilium WireGuard strict mode · Gateway API (hostNetwork Envoy) · WAN via `pi-public-ingress` on `node-pi-01` (hostNetwork nginx stream, since 2026-04-17) · LAN via macvlan `ingress-front` (internal VIP for `*.homelab.local` / `*.lan.homelab.ntbc.io`)
- GitOps: ArgoCD with Kustomize base/overlays · sync-wave: projects(-1) → infrastructure(0) → apps(1)
- Required tools: `talosctl`, `kubectl`, `kubectl linstor`, `make`, `sops` (AGE), `yq`, `curl`, `jq`
- Exclude from search: `kubevirt-operator.yaml` (7669 lines), `cdi-operator.yaml` (5486 lines), `bootstrap/cilium/cilium.yaml` (generated), `.auto-claude/worktrees/`

## Key Terms

- **PNI** — Platform Network Interface: Kyverno-enforced namespace contract for platform service access. See `docs/platform-network-interface.md`.
- **AppProject** — ArgoCD RBAC boundary scoping repos/namespaces an Application can deploy to.
- **Sync-wave** — ArgoCD annotation for deploy order: `-1` (AppProjects) → `0` (infra) → `1` (apps).
- **Schematic** — Talos Image Factory spec embedding system extensions into installer images. See `talos/.schematic-ids.mk`.
- **CCNP/CNP** — CiliumClusterwideNetworkPolicy / CiliumNetworkPolicy. Named `ccnp-*.yaml` / `cnp-*.yaml`.
- **macvlan** — Virtual NIC on physical interface; used for `ingress-front` stable-MAC LAN VIP. *macvlan-on-pod + FritzBox port-forward is structurally unsupported on FRITZ!OS ≥ 8.25* — see `docs/2026-04-15-fritzbox-macvlan-port-forward-exhaustion.md`. WAN ingress uses `pi-public-ingress` hostNetwork instead.
- **pi-public-ingress** — hostNetwork nginx stream pod on `node-pi-01`; sole WAN entrypoint since 2026-04-17. FritzBox port-forwards TCP/443 directly to the Pi's NIC (no macvlan). Performs SNI allowlist filtering against `*.homelab.ntbc.io` and L4-proxies to gateway worker nodes. Node is cordoned via `homelab.io/pi-reserved=true:NoSchedule` taint. See `docs/adr-pi-sole-public-ingress.md`.
- **DRBD** — Distributed Replicated Block Device — LINSTOR replication layer for persistent storage.

## Operational Patterns

- **Upgrade planning**: Use `/plan-talos-upgrade` or `/plan-cilium-upgrade` skills — include automated research and risk assessment. Do not skip for ad-hoc upgrades.
- **Pre-operation review**: Before disruptive changes, invoke `platform-reliability-reviewer` with prefix `pre-operation:` for adversarial risk assessment.
- **Architecture decisions**: Spawn `talos-sre` + `platform-reliability-reviewer` with the same question for dual-perspective analysis.
- **After incidents**: Update §Hard Constraints above if the lesson is universal. Write postmortem to `docs/` for complex incidents.
- **Full-cluster cold cutover**: follow `docs/runbook-cold-cluster-cutover.md` (drain order, shutdown-umount escape hatch, drain-only ArgoCD interaction, NVMe-label pinning trap, hook interaction).
- **Talos MCP-first**: Use Talos MCP tools for all supported operations instead of `talosctl` CLI. CLI-only: `upgrade-k8s`, `config backup to file`, `client version`. See `.claude/rules/talos-mcp-first.md`.
- **Kubernetes MCP-first**: Use `mcp__kubernetes-mcp-server__*` tools for all supported read operations instead of `kubectl`. CLI-only: write ops, exec, drain, describe, logs-follow, kustomize, kubectl-linstor, token-negative reads. See `.claude/rules/kubernetes-mcp-first.md`.
- **Talos-Kubernetes interface gotchas**:
  - Cilium deployed via Talos `extraManifests` — reconcile drift with `make -C talos upgrade-k8s`, NOT `kubectl apply`
  - `extraManifests` does NOT garbage-collect: removing resources from `cilium.yaml` does NOT delete them — orphans must be `kubectl delete`d manually
  - Apply Talos configs BEFORE `upgrade-k8s`: reads extraManifests URLs from LIVE node config — apply to all CP nodes first
  - `upgrade-k8s` does NOT reliably update existing ConfigMaps: use `kubectl apply --server-side --force-conflicts --field-manager=talos`
  - `extraManifests` are URL-cached per full URL (incl. query string): editing `kubernetes/bootstrap/cilium/cilium.yaml` content alone is invisible to nodes. Bump the `?v=<version>-<n>` cache-bust marker in `talos/patches/controlplane.yaml`, regenerate configs, and re-apply to ALL control-plane nodes BEFORE `upgrade-k8s` — otherwise nodes serve the stale manifest and any admission denial (Kyverno, etc.) reappears unchanged.

## Tool-Agnostic Safety Invariants

Enforcement layers that apply regardless of which AI tool is used:

| Safety Gate | Enforced via | Fail Reason |
|---|---|---|
| Plaintext write to `*.sops.yaml` (Write/Edit) | Claude PreToolUse hook `check-sops.sh` | Plaintext secrets must never reach git |
| Bash redirect/heredoc to `*.sops.yaml` | Claude PreToolUse hook `check-sops-bash.sh` | Bypasses file-write gate via shell redirect |
| SOPS encryption state of all `*.sops.yaml` | pre-commit hook wrapping `scripts/verify_sops_files.sh` | Tool-agnostic; enforced at `git commit` time |
| AWS/GitHub tokens in any file | pre-commit `gitleaks` hook | Credential leak prevention |
| Literal tokens in `.codex/config.toml` | pre-commit `check-codex-config-placeholders.sh` | Env vars must use `${VAR}` expansion, not literals |
| `git commit --no-verify` bypass | CI `gitleaks` CLI in `gitops-validate.yml` `secret-scan` job (required PR check) | Last backstop — blocks merge even if local hooks bypassed |
| Forbidden Kubernetes kinds (Ingress, Endpoints) | CI `hard-constraints-check.yml` (required PR check) | Server-side enforcement of §Hard Constraints |

**Codex CLI note**: No PreToolUse hooks fire under Codex. SOPS protection begins at `git commit` via pre-commit framework. Run `make install-pre-commit` after cloning.

## Domain Rules — On-Demand Reference

Claude Code auto-loads each rule via `paths:` frontmatter. **Codex CLI**: scan this table before editing files in the listed context and read the rule file with the Read tool.

| Editing context | Rule file |
|---|---|
| ArgoCD sync, App/Project drift, reconcile ops | `.claude/rules/argocd-troubleshooting.md` |
| Cilium bootstrap via Talos `extraManifests` (Hubble cert-gen, ConfigMap update gotcha) | `.claude/rules/cilium-bootstrap.md` |
| Cilium Gateway API, HTTPRoute, TLSPolicy | `.claude/rules/cilium-gateway-api.md` |
| CiliumNetworkPolicy (`cnp-*.yaml`, `ccnp-*.yaml`) | `.claude/rules/cilium-network-policy.md` |
| Cilium agent / service BPF-map desync, ClusterIP timeouts | `.claude/rules/cilium-service-sync.md` |
| ArgoCD Application/Kustomize overlays | `.claude/rules/argocd-structure.md` |
| Generic CSI patterns (driver-agnostic mount/unmount, Talos-upgrade unmount-deadlock) | `.claude/rules/k8s-csi.md` |
| Generic CNI patterns (Multus / secondary networks, CNI-agnostic eBPF/policy semantics) | `.claude/rules/k8s-cni.md` |
| LINSTOR/Piraeus/DRBD storage changes | `.claude/rules/linstor-storage-guardrails.md` |
| MinIO tenant/operator changes, S3 backend proposals | `.claude/rules/minio-exit.md` |
| Manifest quality (labels, naming conventions) | `.claude/rules/manifest-quality.md` |
| Prometheus, Grafana, kube-prometheus-stack | `.claude/rules/monitoring-observability.md` |
| Glob/Grep search scope | `.claude/rules/search-scope.md` |
| Talos machine config / patches / lifecycle / API behaviour / node recovery | `.claude/rules/talos-config.md` |
| Talos Image Factory / schematics | `.claude/rules/talos-image-factory.md` |
| Talos MCP-vs-CLI tool policy + parameter defaults | `.claude/rules/talos-mcp-first.md` |
| Talos node inventory / endpoint flags | `.claude/rules/talos-nodes.md` |
| Kubernetes operations (prefer MCP over kubectl) | `.claude/rules/kubernetes-mcp-first.md` |

## Operational Runbooks (Skills)

Claude Code dispatches skills via `/skill-name` or intent matching (except Manual-only). **Codex CLI**: use the trigger phrase; Codex reads the SKILL.md as a Markdown runbook. Skills with Refs load additional context from their `references/` subdir.

| Trigger phrase | Skill path | Notes |
|---|---|---|
| analyze node hardware | `.claude/skills/analyze-node-hardware/` | Manual-only |
| audit IRQ affinity | `.claude/skills/irq-affinity-auditor/` | Manual-only (Phase-1a primitive) |
| audit kernel parameters | `.claude/skills/kernel-param-auditor/` | Manual-only, Refs (Phase-1a primitive) |
| audit NIC health | `.claude/skills/nic-health-audit/` | Manual-only, Refs (Phase-1a primitive) |
| debug Cilium policy | `.claude/skills/cilium-policy-debug/` | Manual-only, Refs |
| detect link flaps | `.claude/skills/link-flap-detector/` | Manual-only, Refs (Phase-1a primitive) |
| cluster health snapshot | `.claude/skills/cluster-health-snapshot/` | Manual-only |
| execute Cilium upgrade | `.claude/skills/execute-cilium-upgrade/` | Manual-only |
| execute Talos upgrade | `.claude/skills/execute-talos-upgrade/` | Manual-only |
| gitops health triage | `.claude/skills/gitops-health-triage/` | Manual-only, Refs |
| linstor storage triage | `.claude/skills/linstor-storage-triage/` | Manual-only |
| linstor volume repair | `.claude/skills/linstor-volume-repair/` | Manual-only, Refs |
| onboard workload namespace | `.claude/skills/onboard-workload-namespace/` | Manual-only |
| optimize node kernel | `.claude/skills/optimize-node-kernel/` | Manual-only |
| plan Cilium upgrade | `.claude/skills/plan-cilium-upgrade/` | High-privilege (Bash+Write+Agent), Refs |
| plan Talos upgrade | `.claude/skills/plan-talos-upgrade/` | High-privilege (Bash+Write+Agent) |
| PNI capability add | `.claude/skills/pni-capability-add/` | Manual-only |
| argocd app unstick | `.claude/skills/argocd-app-unstick/` | Manual-only |
| etcd snapshot restore | `.claude/skills/etcd-snapshot-restore/` | Manual-only |
| hubble cert rotate | `.claude/skills/hubble-cert-rotate/` | Manual-only |
| sops key rotate | `.claude/skills/sops-key-rotate/` | Manual-only |
| talos apply | `.claude/skills/talos-apply/` | Manual-only, Refs |
| talos config diff | `.claude/skills/talos-config-diff/` | Manual-only |
| talos node maintenance | `.claude/skills/talos-node-maintenance/` | Manual-only, Refs |
| talos upgrade | `.claude/skills/talos-upgrade/` | Manual-only |
| update schematics | `.claude/skills/update-schematics/` | Manual-only |
| validate gitops | `.claude/skills/validate-gitops/` | Manual-only |
| verify component deployment | `.claude/skills/verify-component-deployment/` | Manual-only |

**Manual-only**: `disable-model-invocation: true` — only runnable via `/skill-name`, never auto-dispatched. **High-privilege**: has Bash+Write+Agent tools — confirm each destructive step under Codex (no runtime `allowed-tools` enforcement).

## MCP Server Configuration

All three MCP servers (github, kubernetes-mcp-server, talos) use **bare PATH-resolved command names**
in both `.mcp.json` and `.codex/config.toml`. Run `make mcp-install` once after cloning to install
the binaries and register the wrapper symlink. See [`docs/mcp-setup.md`](docs/mcp-setup.md) for full
instructions, per-OS install details, and troubleshooting.

**Why bare commands?** Codex CLI does not expand `${VAR}` in `command`/`args` — PATH resolution is
the only portable approach that works in both Claude Code and Codex without per-developer edits.

### Repo-local (both agents)

`.mcp.json` (Claude Code) and `.codex/config.toml` (Codex CLI) in the repo root both use:
- `mcp-github-wrapper` — PATH-installed symlink pointing to `scripts/mcp-github-wrapper.sh`
- `kubernetes-mcp-server` — Homebrew (macOS) or npm binary
- `talos-mcp` — npm binary

The wrapper fetches the GitHub token from `gh auth token` at spawn time and injects it only into
the `github-mcp-server` child process — the token is never exported to the shell environment.

`approval_policy = "on-request"` is hard-pinned in `.codex/config.toml` — do not relax.

### User-global fallback (`~/.codex/config.toml`)

If you prefer global configuration, use bare commands here too — no absolute paths:

```toml
[mcp_servers.github]
command = "mcp-github-wrapper"
args = []

[mcp_servers.kubernetes-mcp-server]
command = "kubernetes-mcp-server"
args = ["--read-only", "--disable-multi-cluster"]

[mcp_servers.talos]
command = "talos-mcp"
args = []
env = { TALOS_CONTEXT = "homelab", TALOS_MCP_ALLOWED_PATHS = "/proc,/sys,/var/log,/run,/usr/local/etc,/etc/os-release" }
```

## Session-Start Ritual (both agents)

At session start, scan the GitHub Issues backlog before doing any work. Use the `github` MCP server (see §MCP Server Configuration above) — fall back to `gh` CLI only if the MCP tool errors.

> **Full lifecycle reference**: see `docs/issue-workflow.md` for state-machine diagram, `scripts/issue-state.sh` invocation contract, subagent dispatch points, and the `/implement-issue` Skill phase mapping.

1. `mcp__github__list_issues(state="open", labels=["status: ready"])` — identify issues marked ready for work
2. `mcp__github__list_issues(state="open", labels=["status: in-progress"])` — resume anything started but not finished
3. **Status gate**: only the `status: ready` label authorizes work to begin. Issues without `status: ready` (proposals, drafts, untriaged, `status: triage`) must NOT be started without explicit user authorization — ask first.
4. During work: create GitHub Issues for bugs found (`bug` label + `severity/*`) and emerging tasks (no `status: ready` label until triaged).
5. When completing work: close the issue with a commit reference in the close comment.

**Risk classification** (set during triage alongside `status: ready`):
- `risk: low` — reversible, narrow scope, portable; routine path with single human gate at PR review
- `risk: medium` — touches multiple subsystems OR has rollback cost; requires SPEC-approval gate before `status: ready`
- `risk: high` — infra-mutating, secret-touching, production-impacting; requires SPEC-approval + secondary signature from a domain reviewer (`talos-sre` for Talos, `platform-reliability-reviewer` for cluster-wide changes)

**Lifecycle states** (label-driven):
- (no status label) — backlog, not yet triaged
- `status: triage` — being triaged
- `status: ready` — authorized for agent or human pickup
- `status: in-progress` — actively being worked
- `status: needs-review` — implementation complete, awaiting review
- `status: blocked` — stuck on dependency or external factor (preserves full context for human untangling)

**Fallback** (MCP unavailable): `gh issue list --state open --label "status: ready"` and `gh issue list --state open --label "status: in-progress"`.

## Deltas vs Claude Code (For Codex CLI Users)

These differences are permanent by design. They are documented here, not hidden.

1. **No PreToolUse interception**: SOPS protection fires at `git commit` (pre-commit framework), not during editing. Plaintext in `*.sops.yaml` during the session is not blocked — only caught before commit. Run `make install-pre-commit` after cloning.
2. **No auto-subagent dispatch**: `platform-reliability-reviewer`, `talos-sre`, `gitops-operator`, `researcher`, `builder-implementer`, `builder-evaluator` run only on explicit request. For pre-merge review, ask: *"Run platform-reliability-reviewer on this diff."* The builder-implementer / builder-evaluator subagents have no Codex CLI equivalent — Codex falls back to inline implementation with reduced Anthropic-Principle-1 guarantee (logged warning); see `docs/issue-workflow.md` §Codex CLI compatibility.
3. **No automatic `cluster.yaml` load**: Read this file explicitly at session start for cluster topology.
4. **No `paths:` rule auto-loading**: See §Domain Rules above — scan the table before editing files in a listed context and read the rule with the Read tool.
5. **`--no-verify` bypass is possible locally**: Required PR checks (`gitleaks` CLI in `gitops-validate.yml`, `hard-constraints-check`) block merge server-side. Local hooks are defense-in-depth, not the last line.
6. **GitHub Push Protection** must be enabled in repo settings (one-time manual step): Settings → Code security → Push protection → Enable. This is a hard prerequisite for server-side secret blocking.
