# Trivy Policy

Local and CI Trivy scanning for Kubernetes misconfigurations.

## Gate layers

| Layer | Where | Behaviour | Bypass |
|---|---|---|---|
| **Pre-commit hook** | `.pre-commit-config.yaml` (`trivy-config`) | Runs `scripts/run_trivy.sh` when a kubernetes/**.yaml file is staged. Blocks the commit on HIGH/CRITICAL findings. | `SKIP=trivy-config git commit …` |
| **Makefile** | `make validate-gitops` → `./scripts/run_trivy.sh` | Runs as part of the full validation target. | Run `make validate-gitops` without bypass; runs on demand. |
| **CI** | `.github/workflows/gitops-validate.yml:Trivy config scan` | Uses `aquasecurity/trivy-action@v0.34.0` with the same `.trivyignore.yaml` and skip-files as local. Failures block PR merge. | Not bypassable (required PR check). |

All three layers share `scripts/run_trivy.sh` and `.trivyignore.yaml` so
they cannot drift.

## Prerequisites

Install Trivy locally so the pre-commit hook works:

- macOS: `brew install aquasecurity/trivy/trivy`
- Linux: see <https://aquasecurity.github.io/trivy/latest/getting-started/installation/>

**Pinned version**: `.trivy-version` at the repo root is the single
source of truth for both CI (via `aquasecurity/setup-trivy` input)
and `scripts/run_trivy.sh` (which warns on mismatch). To match CI
exactly, install the pinned version:

```bash
cat .trivy-version  # e.g. v0.69.2
# then install that specific version — brew tap ships the latest,
# asdf/mise/devbox readers consume .trivy-version directly
```

Mismatched local versions produce a warning (not an error) so you can
still test upgrade candidates before bumping the pin.

## Exception file

`.trivyignore.yaml` (repo root) catalogues every accepted exception.

### Required fields per entry

| Field | Required | Purpose |
|---|---|---|
| `id` | yes | `AVD-KSV-xxxx` check ID |
| `paths` | yes | List of files this exception scopes to |
| `statement` | yes | Human-readable justification — explain WHY accepted and what breaks if "fixed" |
| `expired_at` | yes | ISO date (`YYYY-MM-DD`) forcing review |

### Adding a new exception

1. Decide if the finding is truly un-fixable in the given scope:
   - Can the upstream manifest be patched via Kustomize? Prefer that.
   - Is the RBAC/capability genuinely required by the workload? If yes,
     an ignore is legitimate.
2. Add an entry to `.trivyignore.yaml` under the appropriate category
   comment block.
3. Write the `statement` field as if explaining the acceptance to a
   future maintainer who has not seen this PR. Reference upstream
   version + specific source file when possible.
4. Set `expired_at` ≤ 12 months from today.
5. Run `./scripts/run_trivy.sh` locally and confirm `0 HIGH/CRITICAL
   findings`.
6. Reference the reason (finding IDs + why) in the commit message.

### Review cadence

- **Annual review**: look at entries where `expired_at` is within 60 days.
  For each, determine whether the underlying justification still holds:
  - Upstream operator/bundle version bumped? Re-confirm the RBAC is
    still required.
  - Architecture changed (e.g. Multus replaced)? Remove the entry.
  - Finding now patchable via Kustomize? Add the patch, remove entry.
- **On upstream upgrade**: re-run Trivy after any rabbitmq-cluster-operator,
  kubevirt, cdi, multus-cni, or rabbitmq-messaging-topology-operator bump.
  New findings → add justified entries. Previously-ignored findings that
  disappear → delete the now-stale entries.

## Current categories (as of 2026-04-16)

- **rabbitmq-cluster-operator** — rOFS patched via Kustomize; static-scan
  finding retained with updated statement. RBAC (secrets, pods/exec,
  services/endpoints) upstream-required.
- **Multus CNI** — privileged + hostNetwork + wildcard RBAC required for
  CNI binary install; upstream v4.2.4 has no read-only variant.
- **KubeVirt + CDI operators** — vendored upstream bundles
  (7,669 + 5,486 lines); operator RBAC + writable FS upstream-required.
- **rabbitmq-messaging-topology-operator** — Secret-management RBAC for
  User/Vhost/Permission CRs.
- **ingress-front DHCP init containers** — NET_RAW required by `udhcpc`
  raw sockets for FRITZ!Box host-table registration; unavoidable.

## See also

- `Plans/floofy-nibbling-bird.md` — full rationale for the original
  Trivy gate + exception baseline.
- `.github/workflows/gitops-validate.yml` — CI wiring.
- `scripts/run_trivy.sh` — the single point-of-truth wrapper.
