# ArgoCD Application Patterns for Rendered Manifests

When migrating a component to the rendered-manifests pattern (Phase C of
the migration), each component overlay produces 1–3 ArgoCD Applications
instead of the previous Multi-Source single Application. This document is
the canonical reference for those Application shapes and the PreSync-Hook
RBAC pattern that goes with them.

Cross-refs:

- [Rendered Manifests Pattern (Akuity)][rmp]
- [`../talos-platform-base/.work/rendered-manifests-migration/plan-v2.md`][plan]
- [`../talos-platform-base/.work/rendered-manifests-migration/team-red-findings.md`][team-red]

[rmp]: https://akuity.io/blog/the-rendered-manifests-pattern
[plan]: ../talos-platform-base/.work/rendered-manifests-migration/plan-v2.md
[team-red]: ../talos-platform-base/.work/rendered-manifests-migration/team-red-findings.md

## The three-Application split

A migrated component is deployed by up to three ArgoCD Applications:

| App | Sync wave | Contains | Required? |
|---|---|---|---|
| `<comp>-crds` | −5 | CustomResourceDefinitions only | only if chart ships CRDs |
| `<comp>` | 0 | Controller, RBAC, services, webhooks, deployments | always |
| `<comp>-config` | 2 | Custom Resources (ClusterIssuer, ClusterPolicy, …) | only if overlay defines CRs |

Splitting CRDs at wave −5 with `Prune=false` solves the
same-wave CRD/CR race documented in plan-v2 §Phase D. Splitting
config-CRs at wave 2 lets us attach a PreSync hook that waits for the
controller's webhook to be Available before applying the CRs.

## Application template — `<comp>` (controller wave 0)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: <comp>
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "0"
  labels:
    app.kubernetes.io/name: <comp>
    app.kubernetes.io/instance: homelab
    app.kubernetes.io/component: application
    app.kubernetes.io/part-of: homelab
    app.kubernetes.io/managed-by: argocd
spec:
  project: infrastructure
  source:
    repoURL: https://github.com/Nosmoht/talos-homelab-cluster.git
    targetRevision: main
    path: kubernetes/overlays/homelab/infrastructure/<comp>/_rendered
  destination:
    server: https://kubernetes.default.svc
    namespace: <comp-ns>
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      # Phase D mandates ServerSideApply because:
      # (a) several CRDs exceed the 256 KiB last-applied-configuration
      #     annotation limit that Client-Side Apply enforces (Cilium,
      #     cert-manager, kube-prometheus-stack);
      # (b) field-level ownership via managedFields makes the
      #     ignoreDifferences pattern below work cleanly with
      #     cainjector / kyverno admission webhooks that mutate
      #     specific fields at runtime.
      - ServerSideApply=true
      - RespectIgnoreDifferences=true
      - CreateNamespace=false
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
  ignoreDifferences:
    # Carry over whatever the pre-migration Application declared. Common
    # patterns:
    # - cert-manager-cainjector mutates caBundle on its own webhooks
    # - kyverno does the same
    # - kubevirt-operator mutates its own Deployment annotations at
    #   runtime
    # See team-red C3/H1 for the failure modes if these are dropped.
    []
```

**Notes on each field:**

- `argocd.argoproj.io/sync-wave: "0"` — controller waves at 0. CRDs at
  −5 (separate App). CRs at 2 (separate App). Anything inside `0` runs
  in parallel.
- `path: .../_rendered` — points at the directory containing
  `manifests.yaml`. ArgoCD's `directory` source reads every `*.yaml` in
  the path as one apply.
- `ServerSideApply=true` is non-negotiable. Without it the first sync
  fails on Cilium/cert-manager CRDs and the migration cannot proceed.
- `--force-conflicts` is NOT a sync-option. At cutover time, the
  operator runs `argocd app sync <comp>
  --server-side --force` once per Application to take ownership; from
  the second sync onwards SSA without force is sufficient.

## Application template — `<comp>-crds` (wave −5)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: <comp>-crds
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-5"
  labels:
    app.kubernetes.io/name: <comp>-crds
    app.kubernetes.io/instance: homelab
    app.kubernetes.io/component: crds
    app.kubernetes.io/part-of: homelab
    app.kubernetes.io/managed-by: argocd
spec:
  project: infrastructure
  source:
    repoURL: https://github.com/Nosmoht/talos-homelab-cluster.git
    targetRevision: main
    path: kubernetes/overlays/homelab/infrastructure/<comp>/_rendered
    directory:
      include: 'crds.yaml'
  destination:
    server: https://kubernetes.default.svc
    namespace: <comp-ns>
  syncPolicy:
    automated:
      prune: false        # CRDs survive Application deletion; CRs would orphan otherwise
      selfHeal: true
    syncOptions:
      - ServerSideApply=true
      - Replace=false     # do not replace CRD spec; SSA merges field-by-field
      - CreateNamespace=false
```

`directory.include: 'crds.yaml'` makes ArgoCD's directory source pick up
only that one file — the rest of `_rendered/` belongs to the
controller App.

## Application template — `<comp>-config` (wave 2, with PreSync gate)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: <comp>-config
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "2"
  labels:
    app.kubernetes.io/name: <comp>-config
    app.kubernetes.io/instance: homelab
    app.kubernetes.io/component: config
    app.kubernetes.io/part-of: homelab
    app.kubernetes.io/managed-by: argocd
spec:
  project: infrastructure
  source:
    repoURL: https://github.com/Nosmoht/talos-homelab-cluster.git
    targetRevision: main
    path: kubernetes/overlays/homelab/infrastructure/<comp>/resources
  destination:
    server: https://kubernetes.default.svc
    namespace: <comp-ns>
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ServerSideApply=true
      - RespectIgnoreDifferences=true
      - CreateNamespace=false
```

The `<comp>/resources/` directory must contain a PreSync Job (template
below) that waits for the controller's webhook to be ready. Without it
the CRs may apply before the validating webhook is reachable and get
rejected with "no endpoints available for service".

## PreSync-Hook Job + RBAC

Three files per component (cert-manager, kyverno, vault-config-operator
all need this pattern; others without webhooks do not):

### `presync-hook-sa.yaml`

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: presync-hook-<comp>
  namespace: <comp-ns>
  labels:
    app.kubernetes.io/name: presync-hook-<comp>
    app.kubernetes.io/instance: homelab
    app.kubernetes.io/component: hook-sa
    app.kubernetes.io/part-of: homelab
    app.kubernetes.io/managed-by: argocd
```

### `presync-hook-role.yaml`

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: presync-hook-<comp>
  namespace: <comp-ns>
spec: {}   # spec is empty for Role; rules below
rules:
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: presync-hook-<comp>
  namespace: <comp-ns>
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: presync-hook-<comp>
subjects:
  - kind: ServiceAccount
    name: presync-hook-<comp>
    namespace: <comp-ns>
```

### `presync-hook-job.yaml`

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: presync-wait-webhook-<comp>
  namespace: <comp-ns>
  annotations:
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/hook-delete-policy: HookSucceeded,BeforeHookCreation
spec:
  ttlSecondsAfterFinished: 600
  backoffLimit: 3
  template:
    metadata:
      labels:
        app.kubernetes.io/name: presync-wait-webhook-<comp>
        app.kubernetes.io/instance: homelab
        app.kubernetes.io/component: hook-job
        app.kubernetes.io/part-of: homelab
    spec:
      serviceAccountName: presync-hook-<comp>
      restartPolicy: OnFailure
      containers:
        - name: wait
          image: bitnami/kubectl:1.31
          command:
            - kubectl
            - wait
            - --for=condition=Available
            - deployment/<comp>-webhook
            - --namespace=<comp-ns>
            - --timeout=120s
```

Hook annotations:

- `argocd.argoproj.io/hook: PreSync` — runs before the App's resources
  apply.
- `argocd.argoproj.io/hook-delete-policy: HookSucceeded,BeforeHookCreation` —
  cleans up after success and avoids stale Jobs from previous syncs.

The Job replaces what Helm used to do via `helm.sh/hook` annotations
(team-red H4). When the chart's own startup-api-check Job is rendered
into `manifests.yaml` (e.g. cert-manager-startupapicheck), the
`helm.sh/hook` annotations on that Job become inert — ArgoCD does not
translate them. Strip them at render time or in the kustomize overlay.

## Cutover sequence (per-component, abbreviated)

The full T0–T7 sequence lives in plan-v2 §Phase D. The
per-component shape:

1. `<comp>-crds` applies at wave −5 (CRDs installed).
2. `<comp>` applies at wave 0 (controller + webhook come up).
3. `<comp>-config`'s PreSync Job waits for the webhook to be
   Available; the Job is the ONLY thing that runs at wave 2 until the
   webhook is Available.
4. `<comp>-config` resources (CRs) apply once the Job succeeds.

The PreSync Job is automatically deleted after success.

## ignoreDifferences inventory

Existing pre-migration Applications already carry `ignoreDifferences`
for runtime-mutated fields. They MUST survive into the new
controller-App. Known patterns:

| Component | Pattern |
|---|---|
| cert-manager | webhookconfigurations `.webhooks[].clientConfig.caBundle` (cainjector) |
| cert-manager | crd `.spec.conversion.webhook.clientConfig.caBundle` (cainjector) |
| kyverno | webhookconfigurations `.webhooks[].clientConfig.caBundle` |
| vault-config-operator | (carries over from existing App — TBD in C.5) |
| piraeus-operator | webhook caBundle + TLS Secret data |
| kubevirt | KubeVirt-CR `.status` (operator self-mutation) |
| kubevirt-cdi | CDI-CR `.status` (operator self-mutation) |

See team-red C3/H1 for the failure modes if any of these are dropped.

## Common mistakes

1. **Forgetting `--load-restrictor=LoadRestrictionsNone`** in
   `kustomize build`. Consumer overlays traverse `..` into
   `vendor/base/` and kustomize 5.x rejects that by default. The
   render-consumer-component.sh script sets this flag; ad-hoc kustomize
   invocations do not and will error.
2. **Conflating `argocd app sync --force` with SSA force-conflicts.**
   `--force` on the argocd CLI is unrelated to SSA. Use
   `argocd app sync <app> --server-side --force` for the cutover-day
   ownership takeover.
3. **Dropping `ignoreDifferences` during the migration.** Pre-migration
   Apps had `ignoreDifferences` for caBundle etc.; the new Apps must
   carry them forward. Phase C.5 (#24) inventories these per-component.
4. **PreSync Job without RBAC.** The Job's default SA cannot
   `get deployments` in another namespace (or even its own in restricted
   PSA). Always ship the SA + Role + RoleBinding alongside the Job.
