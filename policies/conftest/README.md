# Conftest policies

This directory contains baseline policies for GitOps CI:

- `k8s.rego`: checks rendered Kubernetes manifests for basic runtime hygiene.
- `argocd.rego`: validates raw Argo CD `Application` manifests and source pinning rules.

## Notes

- Policies are intentionally strict for production defaults.
- Allowlists are defined at the top of each `.rego` file for pragmatic exceptions.
- `warn` rules do not fail CI by default; `deny` rules fail.
