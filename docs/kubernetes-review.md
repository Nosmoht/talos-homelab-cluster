# Kubernetes Manifests Review

**Date:** 2026-03-01  
**Scope:** `kubernetes/` + ArgoCD/Talos integration points  
**Reviewer:** Staff Engineer / Principal Architect review

## Current State Summary

The platform now follows a cleaner GitOps ownership model than the initial review snapshot:

- Root app runs in dedicated constrained project (`root-bootstrap`) instead of `default`.
- Infrastructure/app projects are no longer wildcard-open for destinations and cluster-scoped kinds.
- Mutable Argo source revisions were pinned (`main` for Git refs, exact chart versions).
- Cert-manager SOPS secret format was normalized to encrypt sensitive data fields only.
- Kubelet serving cert approver source was fixed (switched from dead Helm repo URL to upstream Git source).
- Talos no longer bootstraps cert-approver/metrics-server via `extraManifests`; these are now Argo-owned.

## Closed Findings

The following previously reported issues are resolved:

- Dex storage backend deprecation fix (`storage.type: memory`).
- Dex and ArgoCD routes pinned to HTTPS listener.
- AppProject wildcard scope reduction.
- Chart version skew in Argo bootstrap path.
- App `retry` blocks added.
- `SkipDryRunOnMissingResource` added where needed.
- Piraeus version pinning and hardening improvements.
- NVIDIA scheduling constrained to GPU-capable nodes.
- Metrics-server insecure kubelet TLS flag removal.
- Root app moved off `default` project.
- Git/chart mutable revision hardening.

## Remaining Findings

### High

1. **Argo repo-server exec plugins enabled**  
   `kustomize.buildOptions` still includes `--enable-exec`, which expands render-time RCE blast radius.

2. **Talos etcd metrics endpoint exposed over plaintext on all interfaces**  
   `listen-metrics-urls: http://0.0.0.0:2381` remains in controlplane patch.

### Medium

3. **Argo server internal insecure mode still enabled**  
   `server.insecure: true` means in-cluster HTTP unless constrained by network controls.

4. **Gateway accepts routes from all namespaces**  
   `allowedRoutes.namespaces.from: All` remains broad for a shared edge.

5. **Talos secret generation still writes decrypted intermediate file**  
   `.secrets.dec.yaml` workflow remains a workstation exposure risk.

### Low

6. **Root app still lacks resources finalizer**  
   No `resources-finalizer.argocd.argoproj.io` on root Application.

7. **Empty/unreferenced Argo base kustomization file**  
   `kubernetes/base/infrastructure/argocd/kustomization.yaml` remains dead config.

8. **Dex missing `ServerSideApply=true` sync option**  
   Inconsistent with other infra apps using SSA.

9. **Cert-manager hardening gaps**  
   Resource/securityContext hardening and CRD `caBundle` drift handling are still open.

10. **Certificate policy defaults not explicit**  
    Gateway wildcard cert lacks explicit key algorithm/lifecycle tuning and apex SAN.

11. **No namespace PSA labels**  
    Pod Security admission labels are still not codified.

12. **No CI security gate in-repo**  
    No PR pipeline for schema/policy/secret scanning enforcement.

## Notes

- For actionable status tracking, use [`docs/kubernetes-review-todo.md`](kubernetes-review-todo.md), which is the live source of truth for open/closed findings.
