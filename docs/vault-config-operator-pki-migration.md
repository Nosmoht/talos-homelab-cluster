# Vault Config Operator PKI Migration (cert-manager only)

## Scope

This migration moves only cert-manager PKI configuration to Red Hat Vault Config Operator (VCO).

Included:
- `pki_root` and `pki_int` secret engine mounts
- `cert-manager-pki` Vault policy
- `cert-manager-pki` Kubernetes auth role
- `cert-manager-internal` PKI role

Excluded:
- Transit/KV and ATLAS-specific Vault configuration

## Rollout order

1. Deploy `vault-config-operator` application in namespace `vault`.
2. Run VCO bootstrap PreSync hook job to:
- create/update `vault-ca` secret in `cert-manager`
- ensure `auth/kubernetes` config exists
- create/update `vco-pki-admin` policy and role
3. Reconcile VCO PKI custom resources.
4. Remove old PKI bootstrap job ownership from `vault-operator`.

## Validation

- Argo CD apps `vault-operator`, `vault-config-operator`, and `cert-manager` are `Synced` and `Healthy`
- `ClusterIssuer/vault-internal` is `Ready`
- cert-manager canaries continue to issue certificates

## Rollback

1. Revert VCO PKI CRs and application manifests.
2. Restore old `vault-operator` PKI bootstrap job if needed.
3. Wait for Argo CD reconciliation and re-check cert-manager canaries.
