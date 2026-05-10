# Platform Network Interface (PNI) - Consumer Guide

## Purpose

Platform Network Interface (PNI) is the standard way to consume cluster-managed platform services without writing custom network policies per deployment.

If your workload opts in to PNI correctly, required Cilium policies are handled by the platform.

If your workload does not use PNI, you must provide and operate your own network policies and you may not be able to use managed capabilities.

## Audience

- Application teams deploying workloads into the cluster
- Platform consumers using managed services (for example Redis, Kafka, PostgreSQL, Vault, monitoring)

## What PNI Solves

- No per-team per-namespace CNP authoring for common platform integrations
- Consistent least-privilege network behavior across teams
- Faster onboarding to platform services via explicit capability opt-in
- Safer multi-tenant boundaries by default

## Core Concepts

### Provider

A platform-managed component exposing one or more capabilities (for example Strimzi, CNPG, Vault, Prometheus).

### Consumer

A tenant namespace and its workloads that opt in to one or more capabilities.

### Capability

A named function offered by the platform and backed by pre-defined network policy rules.

Examples:

- `monitoring-scrape`
- `vault-secrets`
- `cnpg-postgres`
- `redis-managed`
- `kafka-managed`
- `s3-object`
- `gateway-backend`
- `tls-issuance`
- `storage-csi`
- `gpu-runtime`
- `logging-ship`
- `hpa-metrics`

### Network Profile

A coarse baseline behavior for a namespace:

- `restricted`: minimal baseline, capability access only via explicit opt-in
- `managed`: platform-managed baseline for typical app namespaces
- `privileged`: exception profile, only by platform approval

`network-profile` alone is not enough to access core services. Capability opt-in is required.

## PNI Contract (v1)

### Required Namespace Labels

```yaml
metadata:
  labels:
    platform.io/network-interface-version: "v1"
    platform.io/network-profile: "managed"
```

### Capability Opt-In Labels

Set capability labels on the namespace (recommended default) or explicitly documented workload-level metadata:

```yaml
metadata:
  labels:
    platform.io/consume.monitoring-scrape: "true"
    platform.io/consume.vault-secrets: "true"
    platform.io/consume.cnpg-postgres: "true"
```

### Reserved Labels (Platform-Owned)

The following labels are provider-owned and must not be set by consumer teams:

- `platform.io/provider`
- `platform.io/managed-by`
- `platform.io/capability`

Admission policy (Kyverno) enforces this separation.

## Capability Catalog (Current Cluster)

| Capability | Provider Components | Typical Consumer Use |
|---|---|---|
| `monitoring-scrape` | `kube-prometheus-stack`, `vault-config-operator` | Prometheus metrics scraping |
| `logging-ship` | `alloy`, `loki` | Log forwarding and ingestion |
| `vault-secrets` | `vault-operator`, `vault-config-operator`, `external-secrets` | Secret and PKI integration |
| `cnpg-postgres` | `cloudnative-pg` | Managed PostgreSQL workloads |
| `redis-managed` | `redis-operator` | Managed Redis instances |
| `kafka-managed` | `strimzi-kafka-operator` | Managed Kafka clusters/topics |
| `rabbitmq-managed` | `rabbitmq-cluster-operator`, `rabbitmq-messaging-topology-operator` | Managed RabbitMQ clusters and topology (User/Vhost/Queue) |
| `s3-object` | `minio-operator`, `minio` | S3-compatible object storage |
| `storage-csi` | `piraeus-operator` | Persistent volumes via CSI |
| `tls-issuance` | `cert-manager`, `cert-approver` | Certificate issuance and renewal |
| `gateway-backend` | `gateway-api` (Cilium dataplane) | Backend exposure via Gateway API |
| `external-gateway-routes` | `gateway-api` (homelab-gateway external-https listener) | Opt-in to attach HTTPRoutes to the public `*.homelab.ntbc.io` listener. Gateway-API `allowedRoutes` selector only — network policy continues to be governed by `gateway-backend`. Every external HTTPRoute MUST enforce its own auth (Dex/OIDC); SNI dispatch is routing isolation, not authz. |
| `gpu-runtime` | `nvidia-device-plugin`, `nvidia-dcgm-exporter`, `node-feature-discovery` | GPU workload scheduling and telemetry |
| `hpa-metrics` | `metrics-server` | Resource metrics for autoscaling |
| `internet-egress` | `cilium` | Egress to public internet (all ports) |
| `controlplane-egress` | `kube-apiserver` | kube-apiserver + DNS access for Kubernetes controllers |

## Onboarding Workflow (Consumer)

1. Choose a namespace network profile (`restricted` or `managed`).
2. Set `platform.io/network-interface-version: v1`.
3. Opt in only to required capabilities using `platform.io/consume.<capability>: "true"`.
4. Deploy your workloads or custom resources.
5. Consumer egress is automatically granted by PNI consumer CCNPs once the capability label is set.
6. Validate connectivity and policy behavior.

## Onboarding Workflow (Provider — adding a new capability)

Adding a capability requires touching three places in lockstep. Skipping any one
causes silent admission failure or untested egress paths. Verified end-to-end
during the RabbitMQ rollout.

1. **Capability Registry ConfigMap** —
   `kubernetes/base/infrastructure/platform-network-interface/resources/capability-registry-configmap.yaml`.
   Add an `id:` entry under `capabilities:` with the providing component(s).
   This is documentation/inventory only; it does not enforce anything.
2. **Kyverno enforce-policy allow-list** —
   `kubernetes/base/infrastructure/platform-network-interface/resources/kyverno-clusterpolicy-pni-capability-validation-enforce.yaml`.
   The `AnyNotIn` list under `validate-consume-capability-labels` is hardcoded.
   Append `platform.io/consume.<new-id>` and update the human-readable message.
   **Skipping this step makes Kyverno reject any namespace that opts into the
   new capability as "unknown PNI capability label".**
3. **CCNPs** under
   `kubernetes/base/infrastructure/platform-network-interface/resources/`:
   - `ccnp-pni-<capability>-consumer-egress.yaml` — selects on namespace label
     `platform.io/consume.<capability>=true` plus pod label
     `platform.io/capability-consumer.<capability>=true`, opens egress to the
     provider endpoints.
   - `ccnp-pni-<capability>-operator-dataplane-egress.yaml` (optional) — for
     operator → managed-resource traffic that is not consumer-facing. Scope
     ports tightly; do not preemptively include broker-internal protocols
     (e.g. Erlang distribution) that have no current need — those belong in
     a separate CCNP when multi-replica clusters are introduced.
4. **Provider pod label**: ensure provider pods carry
   `platform.io/capability-provider.<capability>: "true"` on the pod template
   (Helm `podLabels`, operator `spec.podMetadata.labels`, or
   `spec.override.statefulSet.spec.template.metadata.labels` depending on the
   operator). The capability CCNP `egress.toEndpoints` selects on this label,
   so missing it = silent egress denial. The label is reserved for providers —
   `kyverno-clusterpolicy-pni-reserved-labels-enforce.yaml` blocks consumer
   workloads from setting it.
5. Add both CCNP filenames to
   `kubernetes/base/infrastructure/platform-network-interface/kustomization.yaml`.
6. Validate end-to-end:
   `kubectl kustomize kubernetes/base/infrastructure/platform-network-interface/`
   and `make validate-kyverno-policies`.

### Vendored upstream namespaces

Operators distributed as raw upstream YAML (e.g. KubeVirt, RabbitMQ) ship a
`Namespace` resource that **lacks the PNI contract labels**. The namespace is
rejected by `pni-contract-audit` on first sync with
`Namespaces must set platform.io/network-interface-version=v1`.

Patch via kustomize at the overlay level — do not edit the vendored YAML so
upstream upgrades stay clean:

```yaml
patches:
  - target:
      kind: Namespace
      name: <ns>
    patch: |
      - op: add
        path: /metadata/labels/platform.io~1network-interface-version
        value: v1
      - op: add
        path: /metadata/labels/platform.io~1network-profile
        value: managed
      - op: add
        path: /metadata/labels/pod-security.kubernetes.io~1enforce
        value: baseline
      # plus -enforce-version, -audit, -warn, and audit/warn-version labels
      # plus app.kubernetes.io/{instance,managed-by,part-of}
```

Mirror the label set used on existing operator namespaces (e.g. `kafka`,
`redis-system`) so PSA enforcement stays uniform across the cluster.

### Admission webhooks (Cilium WireGuard strict mode)

Validating/mutating webhook calls from kube-apiserver appear with multiple
Cilium identities depending on which control-plane node the apiserver runs on
and whether traffic is rewritten by `cilium_host`. A CNP that allows only
`fromEntities: [kube-apiserver]` will time out on some control-plane nodes.

Use the existing PNI capability instead of writing per-component rules:
label the webhook-serving Deployment pod template with
`platform.io/capability-provider.admission-webhook: "true"`. The cluster-wide
CCNP `pni-admission-webhook-provider-ingress` already covers
`fromEntities: [kube-apiserver, host, remote-node]` on standard webhook ports
(9443, 4221). Add the new component to the `admission-webhook-provider`
provider list in the registry ConfigMap.

### Selector tightness for managed-resource egress

`<capability>-managed-consumer-egress` CCNPs typically select provider pods
by `app.kubernetes.io/component` + `app.kubernetes.io/part-of` in the
provider namespace. This is loose — any future pod in that namespace with
matching labels (debug sidecar, benchmark client) becomes reachable on the
opened ports. Tighten with the operator's `managed-by` label or a cluster-name
selector when introducing managed clusters in additional namespaces.

For `redis-managed` and `rabbitmq-managed`, the platform now uses the
canonical `platform.io/capability-provider.<id>: "true"` label as the
provider selector, making CCNP matching independent of CR name and
namespace. This is the recommended pattern for new capabilities; the
`managed-by` / cluster-name advice above remains current for
`cnpg-postgres` and `kafka-managed` until those CCNPs adopt the same
convention in a follow-up PR. The `platform.io/capability-provider.*`
label is reserved for provider pods — `kyverno-clusterpolicy-pni-reserved-labels-enforce`
blocks consumer workloads from setting it.

## Current Policy Coverage (Core Platform)

The following core flows are currently implemented through platform-owned PNI policies:

- Monitoring DNS visibility: `monitoring` -> `kube-dns` (`53/TCP,UDP`)
- Monitoring scrape to Vault Config Operator metrics: `prometheus` -> `vault-config-operator` (`8443/TCP`)
- Monitoring scrape to External Secrets metrics: `prometheus` -> `external-secrets`, `external-secrets-webhook`, `external-secrets-cert-controller` (`8080/TCP`)
- Controlplane egress (consolidated): all namespaces with `consume.controlplane-egress=true` -> API server (`10.96.0.1:443` + `kube-apiserver:6443`) + DNS — covers cert-manager, external-secrets, vault, cnpg-system, redis-system, kafka, piraeus-datastore, minio-operator
- Redis operator data-plane access: `redis-operator` -> managed Redis pods (`6379/TCP`, `26379/TCP`)
- Strimzi operator data-plane access: `strimzi-cluster-operator` -> managed Kafka pods (`9090/TCP`, `9091/TCP`, `9092/TCP`)
- CNPG operator data-plane access: `cloudnative-pg` -> managed CNPG pods (`5432/TCP`, `8000/TCP`)
- Vault CA distribution for consumers: `cert-manager/vault-ca` -> namespaces labeled `platform.io/network-interface-version=v1` and `platform.io/consume.vault-secrets=true`

### Consumer Capability Policies

Consumer-side policies grant network access for any namespace that opts in to a capability.

Most CCNPs select on **namespace labels only** (`k8s:io.cilium.k8s.namespace.labels.*`) — all pods in the opted-in namespace receive the grant automatically.

Some CCNPs use a **two-level opt-in**: namespace label plus a pod-level label. The pod-level label follows the pattern `platform.io/capability-consumer.<capability>: "true"` and must be set on the pod (e.g., via Helm `podLabels` or an operator's `podTemplate`). If the pod label is absent, the CCNP endpointSelector does not match the pod and the capability is silently not granted.

**Capabilities requiring pod-level label:**

| Capability | Pod label required |
|---|---|
| `controlplane-egress` | `platform.io/capability-consumer.controlplane-egress: "true"` |

Capabilities not listed here are namespace-label-only — no pod label required.

Most consumer CCNPs are **egress** grants (consumer -> provider). The `gateway-backend` capability is an **ingress** grant (gateway proxy -> consumer backend pods). In both cases, per-service CNPs on the provider/consumer side remain the fine-grained authorization boundary.

#### Egress (consumer -> provider)

- S3 object storage: namespaces with `consume.s3-object=true` -> MinIO tenant pods (`9000/TCP`) + MinIO Operator STS (`4223/TCP`) + DNS
- CNPG PostgreSQL: namespaces with `consume.cnpg-postgres=true` -> CNPG cluster pods (`5432/TCP`) + DNS
- Vault secrets: namespaces with `consume.vault-secrets=true` -> Vault pods (`8200/TCP`) + DNS
- Redis managed: namespaces with `consume.redis-managed=true` -> Redis pods (`6379/TCP`) + DNS
- Kafka managed: namespaces with `consume.kafka-managed=true` -> Kafka broker pods (`9092/TCP`) + DNS
- Internet egress: namespaces with `consume.internet-egress=true` -> public internet via `toCIDRSet 0.0.0.0/0` excluding RFC1918 (all ports/protocols) + DNS
- Controlplane egress: namespaces with `consume.controlplane-egress=true` -> kube-apiserver (`10.96.0.1:443` + `kube-apiserver:6443`) + kube-dns (`53/UDP,TCP`)

> **Platform operator capability**: `controlplane-egress` is consumed by platform operator namespaces (cert-manager, external-secrets, vault-operator, cnpg-system, etc.), not application workload namespaces. Application teams interact with the API server through CRDs and controllers — no direct pod-to-apiserver network path is needed. This capability replaces 7 per-operator CCNPs with a single namespace-label-based policy, covering all pods in the opted-in namespace including sidecar controllers (e.g., `external-secrets-cert-controller`).

#### Ingress (gateway proxy -> consumer)

- Gateway backend: namespaces with `consume.gateway-backend=true` receive ingress from Cilium Gateway API proxy (`reserved:ingress` identity) on container ports `3000/TCP` (Grafana), `4180/TCP` (oauth2-proxy), `5556/TCP` (Dex), `8000/TCP` (Django/Uvicorn — plane.so), `8001/TCP` (kb-mcp), `8200/TCP` (Vault UI)

Ports in the gateway-backend CCNP are **container/pod ports** (post-DNAT), not Service ports — Cilium `toPorts` evaluates after kube-proxy DNAT. When adding a new gateway-exposed backend, add its container port to the CCNP.

Namespaces without existing CiliumNetworkPolicies (e.g. `argocd` with `privileged` profile) should **not** opt in to `gateway-backend` or `internet-egress` — the CCNP would be the first policy selecting their pods, activating Cilium's implicit default-deny and breaking intra-namespace communication. Gateway traffic already works in those namespaces since no default-deny is active.

#### API-only capabilities (no CCNP)

The following capabilities are valid opt-in labels but do not require consumer network policies.
Interaction with the provider happens through the Kubernetes API, CRDs, or node-level mechanisms — not pod-to-pod networking.

| Capability | Interaction Model |
|---|---|
| `logging-ship` | Alloy DaemonSet collects container logs from the node filesystem; consumer pods write to stdout/stderr |
| `storage-csi` | CSI volumes provisioned via Kubernetes API; kubelet handles block device attachment at node level |
| `tls-issuance` | Certificates managed via `Certificate` CRDs; cert-manager controller watches the API, no direct network path |
| `gpu-runtime` | NVIDIA device plugin exposes GPUs via kubelet device plugin socket; node-local only |
| `hpa-metrics` | Metrics Server aggregated into Kubernetes API (`metrics.k8s.io`); HPA controller queries via kube-apiserver |

The `monitoring-scrape` capability has a CCNP but follows a different pattern: it is a **provider-egress** grant (Prometheus scrapes into consumer namespaces), not a consumer-egress grant like the other 7 CCNPs.

These labels still require `platform.io/consume.<capability>` on the namespace for audit visibility, Kyverno validation, and forward compatibility with future policy changes.

Implementation rules:

- Policies are platform-owned and reusable.
- Operator control-plane baselines (including `external-secrets`) are implemented as platform-owned `CiliumClusterwideNetworkPolicy` resources under PNI.
- Selectors should be provider/generic label-based.
- Do not encode consumer deployment names or tenant-specific namespace names in PNI policies.
- Consumer capability egress policies use `k8s:io.cilium.k8s.namespace.labels.*` selectors to match all pods in opted-in namespaces -- no hardcoded namespace or pod names on the consumer side.

## Minimal Example

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: team-a
  labels:
    platform.io/network-interface-version: "v1"
    platform.io/network-profile: "managed"
    platform.io/consume.monitoring-scrape: "true"
    platform.io/consume.vault-secrets: "true"
    platform.io/consume.redis-managed: "true"
```

## Validation Checklist (Consumer)

1. Render:
   - `kubectl kustomize kubernetes/overlays/homelab`
2. Dry-run:
   - `kubectl apply -k kubernetes/overlays/homelab --dry-run=client`
3. Runtime:
   - confirm app readiness and successful provider interactions
   - verify expected flows with Hubble where needed

## What Happens If You Do Not Use PNI

- No automatic capability allow-rules
- You must ship your own CNP/KNP for required connectivity
- Platform support may require reproducing the issue with PNI-compliant metadata first

## Security Model

- Default posture is deny-by-default once policies select endpoints.
- Capability access is granted only through explicit opt-in metadata.
- Provider-side identities and grants are platform-owned.
- Cross-tenant communication is denied unless explicitly allowed.

## Troubleshooting

1. Capability not working — namespace label set, but no traffic allowed:
   - verify exact capability label key and value (`"true"`)
   - verify namespace has `platform.io/network-interface-version: v1`
   - **check whether the capability requires a pod-level label** (see §Consumer Capability Policies table above) — if so, verify the pod has `platform.io/capability-consumer.<capability>: "true"`; missing pod label = CCNP silently does not match
2. Traffic blocked:
   - inspect Hubble drops and effective identities: `hubble observe --from-ip <pod-ip> --type drop`
   - verify Cilium endpoint has non-empty egress policy: `cilium-dbg endpoint get <id>` → `policy.realized.egress`
   - check whether workload is using unsupported ports/protocols for that capability
3. Admission denied:
   - confirm you are not setting provider-reserved labels
4. Unknown capability warning:
   - check for typos in `platform.io/consume.*` labels (e.g., `internet-igress` instead of `internet-egress`)
   - Kyverno audits unknown capability labels and emits warnings

## FAQ

### Is `platform.io/network-profile` enough by itself?

No. Profile defines baseline posture. Core platform access requires explicit `platform.io/consume.<capability>` labels.

### Can I opt in only for monitoring and Vault?

Yes. Opt in to exactly the capabilities you need.

### Can I bypass PNI?

Yes, with self-managed policies. You then own policy design, testing, and incident handling for that traffic path.

## Repository Structure

PNI resources live in the base layer — they are not environment-specific:

```
kubernetes/base/infrastructure/platform-network-interface/
├── kustomization.yaml          # lists all resources with resources/ prefix
└── resources/
    ├── capability-registry-configmap.yaml
    ├── kyverno-clusterpolicy-pni-*.yaml    (3 ClusterPolicies)
    ├── kyverno-clusterpolicy-vault-ca-distribution.yaml
    └── ccnp-pni-*.yaml                     (capability CCNPs)
```

The ArgoCD Application CR that deploys these resources lives in the overlay:

```
kubernetes/overlays/homelab/infrastructure/platform-network-interface/
├── kustomization.yaml          # references application.yaml only
└── application.yaml            # ArgoCD Application CR, source.path → base
```

To add a capability: use `/pni-capability-add`. To onboard a namespace: use `/onboard-workload-namespace`.

## Versioning and Compatibility

- Current contract: `v1`
- Future versions may introduce new capabilities or stricter validation
- Consumers should pin `platform.io/network-interface-version` explicitly
