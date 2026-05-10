---
paths:
  - "kubernetes/**"
  - "docs/day2-operations.md"
  - "Makefile"
---

# ArgoCD Troubleshooting

## Operator Intent
- Treat git as source of truth for ArgoCD-managed resources.
- Use `kubernetes/bootstrap/**` only for bootstrap and emergency recovery.

## Safe Change Sequence
1. Render locally before editing (`kubectl kustomize kubernetes/overlays/<overlay>` — overlay name from `cluster.yaml`).
2. Apply manifest changes in git only.
3. Verify ArgoCD application health/sync status after push.
4. Capture verification evidence in PR notes.

## Drift and Retry Handling
- If sync is stuck on stale `operationState`, clear it via patch and force refresh: `kubectl patch app <app> -n argocd --type json -p '[{"op":"remove","path":"/status/operationState"}]'`
- **Exhausted auto-sync retries**: ArgoCD stops with "will not retry" when retries exhaust at a fixed revision; clear `/status/operationState` via patch then refresh to allow fresh auto-sync
- **Stale revision in auto-sync retries**: Auto-sync locks to the git revision at start; pushing fixes won't help until retries exhaust. Primary fix: `argocd app terminate-op <app>` then clear `/status/operationState` via patch — less disruptive than restarting argocd-application-controller (which affects all apps). Use controller restart only as last resort.
- For immutable selector chart upgrades, delete conflicting Deployment (and often Service) first, then resync — check Service selector for stale labels from three-way merge
- **Hook Job completed but operationState stuck**: If a hook Job is deleted (DeletePolicy) before ArgoCD observes completion, sync hangs. Clear `/status/operationState` via patch then refresh
- **Force refresh after push**: `kubectl annotate application <app> -n argocd argocd.argoproj.io/refresh=hard --overwrite`

## Helm Chart Upgrade Gotchas
- **Validate values.yaml keys against target chart version**: Run `helm show values <repo>/<chart> --version <target>` and confirm all key paths. Helm silently ignores unknown keys — top-level keys that worked in one version may become no-ops after chart restructuring (e.g., `serviceMonitor.enabled` vs `component.prometheus.serviceMonitor.enabled`). Validate with `helm template` before committing.
- **CRD schema defaulting causes perpetual OutOfSync**: When a chart upgrade adds or changes CRD schema defaults (e.g., new fields with default values), the API server injects those defaults into existing CRs. ArgoCD sees the extra fields as drift. Fix: add the defaulted fields explicitly to CR manifests in git. Do not use `ignoreDifferences` — it masks real drift. Identify diffs with `kubectl get <cr> -o json` vs git source.
- **CRDs without managedFields block SSA normalization**: Some CRDs (e.g., TracingPolicy) use `x-kubernetes-preserve-unknown-fields` which prevents SSA from tracking field ownership. Re-applying with `--server-side --force-conflicts` won't help — you must align git manifests with server-defaulted state.

## Resource Management Gotchas
- **SharedResourceWarning (Namespace)**: When upstream sources include a Namespace resource, don't redefine it in root app — use `spec.source.kustomize.patches` on the child Application to add labels instead
- **OCI Helm repos**: Use `repoURL: ghcr.io/<org>/<repo>` (no `oci://` prefix), `chart: <name>`. AppProject `sourceRepos` needs glob: `ghcr.io/<org>/<repo>*`
- **AppProject permission blocks valid syncs**: If an app shows `one or more synchronization tasks are not valid`, add the denied kinds to AppProject `spec.clusterResourceWhitelist` in Git then sync `root`
- **Do not stop at `OutOfSync` label-only checks**: Always check `status.operationState.message` and per-resource sync results for the first hard blocker
- **Multus DaemonSet `prune: false`**: Changing init containers won't take effect until `kubectl rollout restart daemonset kube-multus-ds -n kube-system`
- **Gateway `Programmed: False` blocks root app sync**: Cilium bug #42786; add `argocd.argoproj.io/sync-options: SkipHealthCheck=true` annotation on the Gateway resource
- **Removing `commonAnnotations` drops sync-wave from raw resources**: Add per-resource `argocd.argoproj.io/sync-wave` annotations or move resources into a child Application
- **Migrating resources between Applications**: Add `argocd.argoproj.io/sync-options: Prune=false` to resources before removing from the old Application's kustomization — otherwise `prune: true` deletes before new Application recreates, causing an outage window
- **StatefulSet rollout deadlock on CrashLooping pod**: Default STS `RollingUpdate` replaces pods in reverse ordinal order (N-1 → 0) and waits for each to be Ready before moving on. A pod stuck in `CrashLoopBackOff` on the current ordinal blocks the rollout forever — subsequent ordinals never update, so a template fix (e.g. new env vars, new labels) reaches zero pods. `kubectl rollout restart sts/<name>` only writes the template annotation; it does NOT force a delete. Also note that `updated=0/2 ready=1` with mismatched `currentRevision` vs `updateRevision` is the diagnostic signature. Fix: `kubectl delete pod <name>-<ordinal>` to force the STS controller to create a fresh pod on the `updateRevision` template; the ordinal above rolls once the crashing pod is Ready on the new revision.

## Hard Rules
- Never use `kubectl apply` for resources already managed by ArgoCD.
- Never mask drift with `ignoreDifferences` until webhook/defaulting behavior is verified.
- Always include explicit fields known to be defaulted by Gateway API webhooks to avoid perpetual OutOfSync.
