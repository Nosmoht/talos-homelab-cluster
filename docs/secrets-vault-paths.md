# Secrets in Vault — Path Schema and Migration Inventory

This cluster's secret material is provisioned by [External Secrets Operator
(ESO)](https://external-secrets.io/) from HashiCorp Vault. Phase A of the
[rendered-manifests migration](../../talos-platform-base/.work/rendered-manifests-migration/plan-v2.md)
replaced KSOPS + sops-encrypted Secrets in git with `ExternalSecret`
manifests + Secrets stored in Vault. This document defines the path
convention and lists every secret currently in the migration scope.

## Why ESO instead of SOPS

The Akuity-published [Rendered Manifests Pattern][rmp] is explicit:
KSOPS is incompatible with rendering manifests at CI time and committing
the result. Decrypting at render time would land plaintext in git;
deferring decryption to ArgoCD requires a Config-Management-Plugin which
breaks the `directory`-source promise. ESO sidesteps both: the
`ExternalSecret` resource is git-safe (it references a Vault path), and
ESO populates the actual `kind: Secret` at runtime from Vault.

[rmp]: https://akuity.io/blog/the-rendered-manifests-pattern

## Path schema

```text
kv/clusters/<cluster>/<namespace>/<secret-name>
```

- `<cluster>` matches the consumer cluster name. For this repo:
  `homelab`.
- `<namespace>` matches the Kubernetes namespace where the
  `ExternalSecret` lives.
- `<secret-name>` matches the target Kubernetes Secret name (the
  string the consuming workload references via `secretRef`).

Each Vault KV entry stores all keys of the corresponding Kubernetes
Secret as flat key-value pairs. Example: a Vault entry at
`kv/clusters/homelab/dex/dex` with keys
`google-client-id`, `google-client-secret`, … maps to a Kubernetes
Secret `dex` in namespace `dex` with those same keys.

## Migration inventory

Every secret currently encrypted via SOPS+KSOPS in this repo, with the
target Vault path and the data keys it must contain. After Phase A
lands, these SOPS files are deleted (Phase C.6) and the `ExternalSecret`
manifests in `kubernetes/overlays/homelab/secrets/external-secrets/`
take over.

| SOPS file (today) | Target Vault path | Secret namespace | Keys |
|---|---|---|---|
| `cert-manager/resources/secret.sops.yaml` | `kv/clusters/homelab/cert-manager/google-cloud-dns` | cert-manager | `service-account-key.json` |
| `dex/resources/secret.sops.yaml` | `kv/clusters/homelab/dex/dex-oidc-secrets` | dex | `google-client-id`, `google-client-secret`, `argocd-oidc-client-secret`, `argo-workflows-oidc-client-secret`, `grafana-oidc-client-secret`, `prometheus-oidc-client-secret`, `alertmanager-oidc-client-secret` |
| `loki/resources/secret-minio-credentials.sops.yaml` | `kv/clusters/homelab/monitoring/loki-minio-credentials` | monitoring | `LOKI_S3_ACCESS_KEY_ID`, `LOKI_S3_SECRET_ACCESS_KEY` |
| `minio/resources/secret-minio-env-configuration.sops.yaml` | `kv/clusters/homelab/minio/myminio-env-configuration` | minio | `config.env` |
| `kube-prometheus-stack/resources/grafana-oidc-secret.sops.yaml` | `kv/clusters/homelab/monitoring/grafana-oidc` | monitoring | `client-secret` |
| `kube-prometheus-stack/resources/oauth2-proxy-secret.sops.yaml` | `kv/clusters/homelab/monitoring/oauth2-proxy-secrets` | monitoring | `prometheus-client-secret`, `alertmanager-client-secret`, `prometheus-cookie-secret`, `alertmanager-cookie-secret` |
| (NEW — no SOPS source) | `kv/clusters/homelab/monitoring/grafana-admin-credentials` | monitoring | `admin-user`, `admin-password` |

The last row (`grafana-admin-credentials`) is new: the
`kube-prometheus-stack` chart used to auto-generate a random Grafana
admin password, which is non-deterministic and broke the rendered-
manifest drift gate. Phase B set `grafana.admin.existingSecret` in
the chart values, requiring an externally-provisioned Secret of that
name. ESO provisions it from Vault per this row.

## Out-of-band seed runbook

The Vault writes themselves are out-of-band — they happen ONCE,
operator-driven, before the corresponding `ExternalSecret` is
activated. They are intentionally NOT scripted in CI or git.

Decrypt each existing SOPS file locally and pipe the cleartext into
`vault kv put`. Disable shell history first to avoid leaking the
plaintext into `~/.zsh_history` / `~/.bash_history`.

```bash
set +o history    # disable history capture for this shell
unset HISTFILE    # belt and braces

# Example for the dex OIDC clients Secret. Adapt path/file/keys per row.
sops -d kubernetes/overlays/homelab/infrastructure/dex/resources/secret.sops.yaml \
  | yq -o=json '.stringData' \
  | vault kv put -mount=kv "clusters/homelab/dex/dex-oidc-secrets" -

# For the cert-manager google-cloud-dns Secret (data is base64'd):
sops -d kubernetes/overlays/homelab/infrastructure/cert-manager/resources/secret.sops.yaml \
  | yq -o=json '.data | map_values(@base64d)' \
  | vault kv put -mount=kv "clusters/homelab/cert-manager/google-cloud-dns" -

# For the new grafana-admin-credentials (no SOPS source — generate fresh):
admin_password="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)"
vault kv put -mount=kv "clusters/homelab/monitoring/grafana-admin-credentials" \
  admin-user=admin admin-password="${admin_password}"
unset admin_password
```

After all paths are populated, verify with:

```bash
for path in \
  cert-manager/google-cloud-dns \
  dex/dex-oidc-secrets \
  monitoring/loki-minio-credentials \
  minio/myminio-env-configuration \
  monitoring/grafana-oidc \
  monitoring/oauth2-proxy-secrets \
  monitoring/grafana-admin-credentials; do
  vault kv get -mount=kv "clusters/homelab/$path" >/dev/null \
    && echo "OK:      $path" \
    || echo "MISSING: $path"
done
```

When every line prints OK, the Phase A `ExternalSecret` manifests
(written in commit A.3) can be activated by including them in the
appropriate Application's `resources/`. Until then, they sit in
`kubernetes/overlays/homelab/secrets/external-secrets/` (not yet
referenced by any kustomization), inert.

## Vault auth model

ESO authenticates to Vault using the [Kubernetes Auth method][k8s-auth]:
each `SecretStore` is per-namespace, references a Vault role that is
bound to the `external-secrets` ServiceAccount in that namespace, and
has a Vault Policy that grants `read` on exactly the paths under
`kv/clusters/homelab/<namespace>/`. There are no central credentials —
Vault verifies the SA JWT against the Kubernetes API at login time.

The role TTL is set to `3600s` to match the Talos-default
`serviceAccountToken.expirationSeconds: 3607`. Setting the Vault
token TTL longer than the SA-JWT TTL would create a class of "Vault
trusts a token Kubernetes has revoked" — symmetric TTLs avoid that.

[k8s-auth]: https://developer.hashicorp.com/vault/docs/auth/kubernetes

## Cross-references

- Phase A.2 (commit) — `ClusterSecretStore`/`SecretStore` resources +
  vault-config-operator policies/roles
- Phase A.3 (commit) — `ExternalSecret` manifests for all rows above
- Phase C.6 (commit) — KSOPS removal + `*.sops.yaml` deletion (only
  after these ExternalSecrets are confirmed `SecretSynced` in cluster)
