---
paths:
  - "kubernetes/**/minio/**"
  - "kubernetes/**/minio/*.yaml"
  - "kubernetes/**/minio-operator/**"
  - "kubernetes/**/*minio*.yaml"
---

# MinIO End-of-Life Guardrails

Both upstream repos are archived as of Q1 2026:
- `github.com/minio/operator` — last commit 2025-10-09, last release v5.0.18.
- `github.com/minio/minio` — last release RELEASE.2025-10-15 (with CVE GHSA-jjjj-jwhf-8rgr).

License remains AGPLv3; there is no upstream CVE pipeline going forward. The vendor's strategy shifted to the commercial AIStor product; the community server distribution is now source-only.

## Reject on sight

Do NOT propose or implement:

- **Installing `job.min.io/AdminJob` CRDs.** The reconciler was merged into the unreleased v6 branch and never shipped. On the v5.0.18 binary (what chart v7.1.1 actually deploys) AdminJob instances hang Pending forever.
- **`sts.min.io/PolicyBinding` + STS/AssumeRoleWithWebIdentity hardening for consumers.** ROI is negative against the 6–12 month exit horizon; the three implementation gates (chart keys, config rendering, STS audience) are non-trivial and the result must be unwound at exit time.
- **Operator-chart or tenant-chart "upgrades".** There is no upstream version beyond v5.0.18 to upgrade to.

## Acceptable bridge patterns

- **Static S3 credentials per consumer**, stored SOPS-encrypted. Each consumer gets its own dedicated MinIO user (not root). Example: Loki uses `loki-<random>`, not `minio`.
- **Root credentials** must be SOPS-encrypted and use a strong, rotated password. The in-cluster IAM state persists MinIO user accounts across tenant pod restarts, so root-password rotation does not disturb existing consumer users.

## Exit tracking

Migration to a maintained S3-compatible backend is tracked as a separate GitHub issue. Shortlist: SeaweedFS (Apache-2.0, lightweight, active), Garage (AGPLv3, minimal, geo-distribution focus), Rook-Ceph RGW (CNCF-graduated, heavy). Horizon: 6–12 months from 2026-04-15.

## Incident reference

See the MinIO root-credential rotation incident (commit `a090b72` on main) for the multi-lens review that converged on this posture.
