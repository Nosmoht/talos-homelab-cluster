# `ignoreDifferences` Inventory for Rendered-Manifests Migration

When the 18 components migrate from Multi-Source Helm-at-sync-time to
the rendered-manifests pattern (Phase D), each new
`<comp>` Application must carry forward whatever `ignoreDifferences`
its predecessor declared, plus any new entries the team-red review
identified for components that did not previously have them.

This document is the canonical source of truth for those entries.
It is referenced by `docs/rendered-manifests-application-patterns.md`
(the standard Application template) and consumed by C.3 (the
17-component migration commit).

Cross-refs:
- [`../talos-platform-base/.work/rendered-manifests-migration/team-red-findings.md`](../../talos-platform-base/.work/rendered-manifests-migration/team-red-findings.md) §C3, §H1
- ArgoCD docs: [Diffing Customization](https://argo-cd.readthedocs.io/en/stable/user-guide/diffing/)

## Why these entries exist

After SSA cutover, ArgoCD's `managedFields` ownership tells which
controller owns which field. Several components have controllers that
mutate fields ArgoCD also writes — caBundle injection, operator-self-
mutation, runtime-generated TLS material. Without `ignoreDifferences`,
ArgoCD detects the controller's mutation as drift and either:

- (with `selfHeal: true`) reverts the controller's value and breaks
  whatever depends on it (admission webhooks, operator-self-config),
  OR
- (with `selfHeal: false`) reports the App as `OutOfSync` indefinitely.

Both outcomes are operational pain. Per-field `ignoreDifferences`
tells ArgoCD "these field paths belong to the controller, not me."

## Inventory

### Components migrated from existing pre-rendered apps

These three components ALREADY have `ignoreDifferences` blocks in
their pre-migration `application.yaml`. The new `<comp>` Application
must carry them forward verbatim.

#### cert-manager

```yaml
ignoreDifferences:
  - group: admissionregistration.k8s.io
    kind: MutatingWebhookConfiguration
    jqPathExpressions:
      - '.webhooks[]?.clientConfig.caBundle'
  - group: admissionregistration.k8s.io
    kind: ValidatingWebhookConfiguration
    jqPathExpressions:
      - '.webhooks[]?.clientConfig.caBundle'
  - group: apiextensions.k8s.io
    kind: CustomResourceDefinition
    jqPathExpressions:
      - '.spec.conversion.webhook.clientConfig.caBundle'
```

**Why:** cert-manager-cainjector mutates `caBundle` on its own webhook
configurations and CRD conversion webhooks at runtime. The rendered
manifests have empty `caBundle: ""`; cainjector writes the actual
PEM-encoded bundle once the controller is up.

#### piraeus-operator

```yaml
ignoreDifferences:
  - group: ""
    kind: Secret
    name: piraeus-operator-tls
    namespace: piraeus-datastore
    jsonPointers:
      - /data
  - group: admissionregistration.k8s.io
    kind: ValidatingWebhookConfiguration
    name: piraeus-operator-validating-webhook-configuration
    jqPathExpressions:
      - '.webhooks[].clientConfig.caBundle'
```

**Why:** the piraeus-operator chart embeds a self-generated CA in
its ValidatingWebhookConfiguration via `randAlphaNum` at helm-template
time. This is the chart-level non-determinism that blocks Phase B.3
from rendering piraeus-operator at all (see issue #27 for the
follow-up to use cainjector instead). Until #27 lands, the
ignoreDifferences entry covers the runtime-rotated state.

#### vault-config-operator

```yaml
ignoreDifferences:
  - group: admissionregistration.k8s.io
    kind: MutatingWebhookConfiguration
    jqPathExpressions:
      - '.webhooks[]?.clientConfig.caBundle'
  - group: admissionregistration.k8s.io
    kind: ValidatingWebhookConfiguration
    jqPathExpressions:
      - '.webhooks[]?.clientConfig.caBundle'
```

**Why:** vault-config-operator's webhook also uses cainjector for
caBundle population. Same shape as cert-manager.

### Components NEW to ignoreDifferences (team-red H1)

These three components do NOT have `ignoreDifferences` in their
pre-migration `application.yaml` because the previous Multi-Source
Helm-at-sync-time path was tolerant of operator-self-mutation. After
SSA cutover, the entries below are required.

#### kubevirt

```yaml
ignoreDifferences:
  - group: kubevirt.io
    kind: KubeVirt
    name: kubevirt
    namespace: kubevirt
    jsonPointers:
      - /status
      - /spec/configuration/developerConfiguration
  - group: apps
    kind: Deployment
    namespace: kubevirt
    jqPathExpressions:
      - '.spec.template.metadata.annotations["kubevirt.io/install-strategy-registry"]'
      - '.spec.template.metadata.annotations["kubevirt.io/install-strategy-version"]'
```

**Why:** the kubevirt-operator updates the KubeVirt CR's `.status`
field continuously and stamps install-strategy annotations on its
own Deployment pod template. Without these entries, every reconcile
loop produces drift.

#### kubevirt-cdi

```yaml
ignoreDifferences:
  - group: cdi.kubevirt.io
    kind: CDI
    name: cdi
    jsonPointers:
      - /status
  - group: apps
    kind: Deployment
    namespace: cdi
    jqPathExpressions:
      - '.spec.template.metadata.annotations["cdi.kubevirt.io/install-strategy-version"]'
```

**Why:** symmetric to kubevirt — cdi-operator does the same thing
on the CDI CR + cdi-operator Deployment.

#### kyverno

```yaml
ignoreDifferences:
  - group: admissionregistration.k8s.io
    kind: MutatingWebhookConfiguration
    jqPathExpressions:
      - '.webhooks[]?.clientConfig.caBundle'
  - group: admissionregistration.k8s.io
    kind: ValidatingWebhookConfiguration
    jqPathExpressions:
      - '.webhooks[]?.clientConfig.caBundle'
```

**Why:** kyverno's admission controller manages its own webhook CA
material at runtime via the cert-controller deployment. Without
this entry, every CA rotation triggers an ArgoCD diff.

### Components with no `ignoreDifferences` needed

The remaining 12 components do not need any `ignoreDifferences`
entries:

`alloy`, `argocd`, `cert-approver` (special — Phase B.3 follow-up),
`dex`, `external-secrets`, `kube-prometheus-stack`,
`local-path-provisioner` (special — Phase B.3 follow-up), `loki`,
`metrics-server`, `multus-cni` (plain YAML, not Helm), `nfd`,
`nvidia-dcgm-exporter`, `nvidia-device-plugin`,
`platform-network-interface` (plain YAML), `tetragon`, `vault-operator`.

If a regression surfaces after cutover for any of these, add the
necessary entry here and to that component's `application.yaml`.

## Maintenance

### When to add a new entry

After cutover, if `argocd app diff <comp>` reports a drift on a
field that a controller (not ArgoCD) is mutating:

1. Identify the controller (audit logs, owner references).
2. Identify the field path.
3. Add the entry here AND to the component's `application.yaml`.
4. Commit; ArgoCD self-syncs within `selfHeal` interval.

### When to remove an entry

When the upstream chart fixes the runtime-mutation pattern (e.g.
piraeus moves to cainjector — see issue #27), the corresponding
entry can be dropped. Run `argocd app diff <comp>` for ≥1 reconcile
window to confirm no residual drift before removing.

### When to convert from `jqPathExpressions` to `jsonPointers`

`jqPathExpressions` is more expressive (can match array elements
conditionally) but slower; `jsonPointers` is faster but path-literal.
Prefer `jsonPointers` for stable, single-resource patterns.
`jqPathExpressions` is necessary for `webhooks[]` patterns where the
chart may add/remove webhooks across versions.

The current inventory uses both because that is what the
pre-migration apps shipped — preserving them avoids regressions
from a converter quirk.
