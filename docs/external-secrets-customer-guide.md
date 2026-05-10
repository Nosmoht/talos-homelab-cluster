# Customer Guide: Vault Secrets with External Secrets Operator (ESO)

## Purpose

This guide explains how customer workloads consume runtime secrets from Vault.

Scope:
- Customer runtime secrets only
- Vault as source of truth
- Kubernetes `Secret` objects created by ESO

Out of scope:
- Cluster bootstrap/platform secrets (these stay in KSOPS/SOPS)

## Security Model

Tenant isolation is enforced by multiple controls:

1. Vault policy path boundary:
- Tenant `team-a` can read only `secret/data/customers/team-a/*`.

2. Kubernetes auth role binding:
- One Vault role per tenant namespace, bound to exact service account + namespace.

3. Namespaced SecretStore:
- Each namespace has its own `SecretStore` and Vault role.
- No shared default `ClusterSecretStore`.

Even if a tenant tries to reference another tenant path in an `ExternalSecret`,
Vault denies access.

## Hard Requirement: Multi-Namespace Access per Tenant

A single tenant can consume its own secrets in multiple namespaces.

Pattern:
- Shared Vault tenant path: `secret/data/customers/<tenant>/*`
- Per namespace role: `es-<tenant>-<namespace>`
- Per namespace SecretStore pointing to that namespace role

This keeps revocation and blast radius namespace-local while preserving tenant
secret reuse.

## Prerequisites

The namespace must be onboarded to platform contracts:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: team-a-apps
  labels:
    platform.io/network-interface-version: "v1"
    platform.io/network-profile: "managed"
    platform.io/consume.vault-secrets: "true"
```

Platform team responsibilities:
- Create/maintain Vault policy for tenant path.
- Create/maintain Vault Kubernetes auth roles per namespace.
- Ensure ESO is deployed and healthy.
- Own ESO control-plane network policy via platform PNI policies.
- Distribute `vault-ca` secret to opted-in tenant namespaces.

Customer responsibilities:
- Define `ExternalSecret` resources in own namespace.
- Reference only approved Vault keys/paths.
- Do not manage ESO control-plane Cilium policies.

## Step 1: Put a Secret into Vault

Example (performed by platform automation or approved workflow):

```bash
vault kv put secret/customers/team-a/payments \
  username="payments-user" \
  password="replace-me"
```

## Step 2: Create a SecretStore (per namespace)

Example namespace: `team-a-apps`.

Create a dedicated service account for Vault auth:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: eso-store
  namespace: team-a-apps
```

```yaml
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: vault-team-a
  namespace: team-a-apps
spec:
  provider:
    vault:
      server: https://vault.vault.svc.cluster.local:8200
      path: secret
      version: v2
      caProvider:
        type: Secret
        name: vault-ca
        key: ca.crt
      auth:
        kubernetes:
          mountPath: kubernetes
          role: es-team-a-team-a-apps
          serviceAccountRef:
            name: eso-store
```

`vault-ca` is platform-managed. Tenants should reference it but should not create or update it.

## Step 3: Create an ExternalSecret

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: payments-runtime
  namespace: team-a-apps
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: SecretStore
    name: vault-team-a
  target:
    name: payments-runtime
    creationPolicy: Owner
  data:
    - secretKey: APP_USERNAME
      remoteRef:
        key: customers/team-a/payments
        property: username
    - secretKey: APP_PASSWORD
      remoteRef:
        key: customers/team-a/payments
        property: password
```

## Multi-Namespace Example

For `team-a` in namespaces `team-a-apps` and `team-a-jobs`:

1. Two Vault roles:
- `es-team-a-team-a-apps`
- `es-team-a-team-a-jobs`

2. Two namespaced `SecretStore` objects (one in each namespace).

3. Both roles map to the same tenant path:
- `secret/data/customers/team-a/*`

## Rotation Behavior

- Update secret values in Vault.
- ESO refreshes on `refreshInterval` (or manual reconcile trigger).
- Kubernetes target Secret is updated in-place.

## Troubleshooting

1. `permission denied`:
- Vault role policy does not include the requested path.
- `SecretStore` role does not match namespace/service account binding.

2. `secret not found`:
- Wrong `remoteRef.key` or `property`.
- KV path written under a different tenant prefix.

3. Store is not Ready:
- Vault endpoint/TLS/auth config mismatch.
- ESO controller logs show provider auth errors.
- Missing `vault-ca` secret in tenant namespace.

Useful commands:

```bash
kubectl -n external-secrets get pods
kubectl -n external-secrets logs deploy/external-secrets --tail=200
kubectl -n <tenant-namespace> get secretstore,externalsecret,secret
kubectl -n <tenant-namespace> describe externalsecret <name>
```

## Best Practices

1. Keep one app/domain secret path per component (avoid huge shared blobs).
2. Use least-privilege Vault policies with explicit tenant prefix.
3. Use one SecretStore per namespace.
4. Keep `refreshInterval` aligned with secret rotation policy.
5. Never commit runtime secret values to git.
