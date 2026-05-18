# Base-pin drift analysis — 2026-05-18

## Summary

The CI drift gate that the multi-repo split ADR and the cluster-creation
plan describe as the safety net between `.base-version` (Day-0 pin) and
ArgoCD `targetRevision` (Day-2 pin) **does not exist** in this repo.

As a result the two pins have silently diverged across the lifetime of
the consumer repo. `.base-version` currently pins `v0.4.0`; every one of
the 20 `talos-platform-base.git` references in
`kubernetes/overlays/homelab/**/application.yaml` still pins `v0.1.0`.
The upstream `talos-platform-base` published `v0.5.0` as Latest on
2026-05-18.

This document records the root cause, the evidence, and a recommended
remediation order. It deliberately ships **no pin changes** — bumping
either side before the drift gate is in place would reproduce the
same blind-spot for the next release.

## Evidence

### 1. Drift gate is referenced but not implemented

Two repo documents promise the script and a CI workflow:

- `docs/adr-multi-repo-platform-split.md:149` —
  "Pin-drift between Day-0 (`.base-version`) and Day-2
  (`spec.sources[base].targetRevision`) is checked in the consumer
  repo's CI via `scripts/check-base-pin-drift.sh`. The check fails the
  build when the two pins diverge."
- `docs/talos-homelab-cluster-creation-plan.md:97` —
  "`scripts/check-base-pin-drift.sh` | CI gate: cross-checks
  `.base-version` against every `targetRevision` for the base source
  in `kubernetes/overlays/homelab/**/application.yaml`"

Neither artifact is present:

```text
$ ls scripts/check-base-pin-drift.sh
ls: cannot access 'scripts/check-base-pin-drift.sh': No such file or directory

$ ls .github/workflows/check-base-pin-drift.yml
ls: cannot access '.github/workflows/check-base-pin-drift.yml': No such file or directory
```

`grep -rIn "check-base-pin-drift" .` returns only the doc references
above — no executable code path.

### 2. The CI workflow that *does* read `.base-version` is a different gate

`.github/workflows/gitops-validate.yml:296-320` reads `.base-version`
exclusively to drive `pull-base-oci.sh` and
`verify-consumer-rendered.sh`. That gate verifies **render
reproducibility** for the consumer overlays under
`kubernetes/overlays/homelab/infrastructure/<comp>/_rendered/` — it
does **not** cross-check the Day-2 `targetRevision` field on
ArgoCD Applications.

Additionally, lines 313–318 of the same step exit `0` with a notice
when the OCI tag in `.base-version` is not yet published. That guard is
unrelated to the missing drift gate but is worth flagging: it disables
the only existing base-side CI verification whenever the upstream
artifact does not exist, which is acceptable during initial bringup
but should be revisited.

### 3. Quantified pin state (2026-05-18)

| Site | Mechanism | Current value |
|---|---|---|
| `.base-version` | Day-0 pin (read by `pull-base-oci.sh`, vendored into `vendor/base/`) | `v0.4.0` |
| `application.yaml` × 20 under `kubernetes/overlays/homelab/` | Day-2 pin (`spec.sources[].targetRevision` for `talos-platform-base.git`) | `v0.1.0` (uniform across all 20 files) |
| Upstream `talos-platform-base` Latest GitHub Release | n/a | `v0.5.0` (2026-05-18) |
| Upstream tags published as OCI artifacts on `ghcr.io` | n/a | `v0.1.0`, `v0.2.0`, `v0.3.0`, `v0.4.0`, `v0.5.0` |

Reproduction:

```bash
# Day-0 pin
cat .base-version
# v0.4.0

# Day-2 pins
for f in $(grep -rIln 'talos-platform-base' --include='application.yaml' \
             kubernetes/overlays/); do
  rev=$(yq -r '.spec.sources[]?
                | select(.repoURL == "https://github.com/Nosmoht/talos-platform-base.git")
                | .targetRevision' "$f")
  [ -n "$rev" ] && echo "$rev $f"
done | awk '{print $1}' | sort | uniq -c
#   20 v0.1.0
```

## Root cause

The drift gate is described in plan-tier and ADR-tier documents but
was never landed as code. The two reasonable hypotheses are:

1. The script was descoped during the initial bringup (`v0.1.0`
   landed without it) and never tracked back into the backlog.
2. The script was deferred until a second cluster materialised; with
   only one consumer, drift between Day-0 and Day-2 has no visible
   blast radius beyond `verify-consumer-rendered.sh` failing if the
   `.base-version` tag is bumped past the rendered tree's
   provenance.

Either way, the *contract* between ADR and code is broken: the ADR
declares the gate exists; the code does not back the claim.

## Why no bump in this PR

Bumping `.base-version` from `v0.4.0` to `v0.5.0` and the 20
`targetRevision` fields from `v0.1.0` to `v0.5.0` *now* — without first
landing the drift gate — would:

1. Reproduce the same blind spot for the v0.5.0 → v0.6.0 transition.
2. Conflate two distinct concerns (gap closure + version bump) in one
   PR, making post-hoc review harder.
3. Pre-empt a v0.5.0-specific consumer-side migration step from
   `UPGRADING.md` (the rename of `ClusterPolicy/pni-contract-audit` →
   `pni-contract-enforce` is a breaking name change that this repo
   may reference in dashboards or labels — that audit has to run
   *before* the bump, not after).

## Recommended remediation order

1. **This PR** — land this document so the gap is durable and
   reviewable; no behaviour change.
2. **Next PR (small, independent)** — implement
   `scripts/check-base-pin-drift.sh` per
   `docs/talos-homelab-cluster-creation-plan.md §8.3` (the plan
   already contains a working implementation sketch). Wire it into
   `.github/workflows/gitops-validate.yml` as a required check.
3. **Then** — run the v0.5.0 `UPGRADING.md` audit:
   - Search this repo for `pni-contract-audit` (Grafana dashboards,
     PolicyReport queries, labels/annotations, doc snippets).
     Rename to `pni-contract-enforce` where found.
4. **Then** — produce the bump PR:
   - `.base-version` → `v0.5.0`
   - 20 `application.yaml::spec.sources[].targetRevision` → `v0.5.0`
   - Re-run `make day0` (or local equivalent) to refresh
     `vendor/base/` and re-render every consumer overlay with
     `verify-consumer-rendered.sh`.
   - Drift gate from step 2 should now be green.

## References

- `docs/adr-multi-repo-platform-split.md` §"Consumption Mechanism"
- `docs/talos-homelab-cluster-creation-plan.md` §8.3 + §9.6
- `../talos-platform-base/UPGRADING.md` §`v0.5.0` (consumer-side
  breaking change)
- `../talos-platform-base/CHANGELOG.md` §`v0.5.0`
