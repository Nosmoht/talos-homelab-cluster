---
paths:
  - "kubernetes/**/*.yaml"
  - "kubernetes/**/*.yml"
---

# Kubernetes Manifest Quality Gate

## Required Conventions
- Use Kubernetes recommended labels (`app.kubernetes.io/*`) on all non-generated resources.
- Keep namespaces explicit where required by object kind.
- Prefer one logical resource group per file directory (`application.yaml`, `kustomization.yaml`, `values.yaml`, `resources/`).

## Review Checklist
- Kustomize references are relative and resolvable.
- Helm values only override what differs from base values.
- Gateway API resources specify fields that webhooks default (match/group/path typing).
- CiliumNetworkPolicies include explicit endpoint selectors and ports that match post-DNAT behavior.
- SOPS secrets stay encrypted (`*.sops.yaml`) and ksops generators are referenced in local `kustomization.yaml`.

## Validation Commands
- `kubectl kustomize kubernetes/overlays/<overlay>` (overlay name from `cluster.yaml`)
- `kubectl apply -k kubernetes/overlays/<overlay> --dry-run=client`
- **Kyverno ClusterPolicy changes**: run `make validate-kyverno-policies` before commit to catch invalid variable/JMESPath expressions via server-side dry-run
- **Local kustomize builds with SOPS secrets**: use `kubectl kustomize --enable-alpha-plugins ...` — default build fails with `external plugins disabled`
