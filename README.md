# talos-homelab-cluster

Homelab-specific ArgoCD overlay repository for the Talos Kubernetes cluster.
This is the cluster half of the multi-repo split (Issue #162 of Nosmoht/Talos-Homelab).

## Provenance

Initial commit produced deterministically by `scripts/162a-cluster-migrate.sh`
(driver version `472a9f5`) against Talos-Homelab at source-state pin `041e339`.

| Artifact                | Reference                                              |
|-------------------------|--------------------------------------------------------|
| Source-state pin        | `041e339`                                              |
| Driver version          | `472a9f5`                                              |
| Base platform OCI image | `ghcr.io/nosmoht/talos-platform-base:v0.1.0`           |
| Migration spec          | `docs/talos-homelab-cluster-migration-spec.md@5ee18ad` |
| Parent issue            | Nosmoht/Talos-Homelab#162                              |
| 162b issue              | Nosmoht/Talos-Homelab#173                              |

## What Changed

All 34 `application.yaml` files in `kubernetes/overlays/homelab/` were processed.
K1-K4 apps (33 files) migrated to `.spec.sources` (plural). K5 (cert-approver) retains
`.spec.source` (singular, external repo). AppProject `sourceRepos` updated additively:
`talos-platform-base.git` and `talos-homelab-cluster.git` added; `Talos-Homelab.git` retained
for D2 transition.

## Multi-Source Architecture

K1/K2: `ref:base` (OCI talos-platform-base:v0.1.0) + `ref:cluster` (this repo) + chart.
K3: `ref:base` + `ref:cluster` + path source.
K4: `ref:base` with path only.
K5: Original singular `.spec.source` (no migration).
