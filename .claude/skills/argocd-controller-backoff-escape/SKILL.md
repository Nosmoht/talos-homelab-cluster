---
name: argocd-controller-backoff-escape
description: Force-recover an ArgoCD child workload whose recreation is stuck in kube-controller-manager workqueue backoff after the upstream cause was already fixed. Uses a benign metadata annotation to fire an Informer Update → immediate reconcile. Safe only on operator-owned resources outside the ArgoCD Application's tracking list.
disable-model-invocation: true
allowed-tools:
  - Bash
  - Read
  - mcp__kubernetes-mcp-server__resources_get
  - mcp__kubernetes-mcp-server__resources_list
---

# ArgoCD Controller Backoff Escape

## Background

After an ArgoCD-owned admission policy, scheduler constraint, image pull, or webhook starts denying a child resource's pod creations, the built-in Kubernetes controller (StatefulSet, Deployment, DaemonSet, Job) for that workload accumulates failures in its workqueue. Once the failure count exceeds ~17, the `DefaultControllerRateLimiter` exponential cap of 1000 s ≈ 16.7 min applies between retries. **Fixing the upstream cause does NOT immediately resume reconciliation** — the controller waits for its next scheduled tick.

This skill nudges the controller via a benign metadata write on the stuck resource. The write fires the controller's Informer `UpdateFunc`, which calls `workqueue.Add()` directly (not `AddRateLimited()`), bypassing the backoff. This is the same primitive ArgoCD's `argocd.argoproj.io/refresh=hard` annotation uses at the Application layer, applied one layer down.

**When to use:**
- ArgoCD shows the parent Application as Synced/Healthy or Synced/Degraded but the actual workload is missing replicas / Pods / Jobs.
- Events on the stuck workload show many `FailedCreate` / `FailedMount` / similar with a stale `lastTimestamp` predating the fix.
- The upstream cause is **verified fixed** (new Kyverno policy live, fixed PVC, fixed image tag, etc.).

**When NOT to use:**
- The upstream cause is unfixed — nudging will re-fail and waste the next workqueue cap window.
- The stuck resource appears directly in an ArgoCD Application's `status.resources[]` tracking list — that path violates `AGENTS.md §Hard Constraints` ("Never `kubectl apply` ArgoCD-managed resources"). Use the Application's ksops-managed flow instead.
- The resource is a `Pod` you would delete-recreate via the StatefulSet/Deployment — pod-delete is more surgical and the hook policy in this repo already allows it for non-ArgoCD-tracked workloads.

**Authoritative reference:** `docs/2026-05-11-vault-quorum-kyverno-cert-manager-cascade.md` §Operational Technique.

## Environment Setup

Read `cluster.yaml` for cluster-specific values (kubeconfig path, namespaces). Confirm `kubectl` is pointing at the homelab kubeconfig.

## Step 0 — Confirm upstream cause is fixed

Skip if not. The nudge **does not** cure failures; it only schedules the next reconcile immediately.

Examples:
- Kyverno policy fix: `kubectl get cpol <policy-name> -o yaml | grep <new-condition>` returns >0.
- PVC binding fix: `kubectl get sc <storage-class>` exists; `kubectl get pv` has Available volumes.
- Image fix: `crictl pull <image>` from a node succeeds OR `kubectl get pod <stuck-pod> -o yaml | grep image:` already shows the fixed tag.

If the cause is not verified, **stop**. Investigate the cause first; come back when verified.

## Step 1 — Confirm staleness of the last failure

```bash
kubectl -n <ns> get events --field-selector reason=FailedCreate \
  -o jsonpath='{range .items[*]}{.lastTimestamp} {.message}{"\n"}{end}' \
  | sort -r | head -3
```

The most recent `lastTimestamp` should predate the upstream-cause fix. If recent failures continue after the fix is live, the cause is NOT actually fixed — return to Step 0.

## Step 2 — Verify ownership boundary (CRITICAL)

The stuck workload must be operator-owned and **not** directly tracked by an ArgoCD Application. ArgoCD-tracked resources fall under the "Never `kubectl apply` ArgoCD-managed resources" hard constraint.

For each candidate ArgoCD Application that could own the workload's parent CR (e.g., the operator's App):

```bash
kubectl get app -n argocd <candidate-app> -o json \
  | jq -r '.status.resources[] | "\(.kind)/\(.name)"' \
  | grep -E '<workload-kind>/<workload-name>'
```

- If the kind/name matches: STOP. The resource is directly ArgoCD-managed. Use ArgoCD's `refresh=hard` annotation on the App instead, or commit the desired state to git.
- If empty: the workload is owned transitively (typically by an operator). Safe to proceed.

**Concrete precedent (2026-05-11):** The `vault-operator` ArgoCD Application tracks the `Vault/vault` CR, not the `StatefulSet/vault`. The StatefulSet is operator-owned; annotation nudge is permitted.

## Step 3 — Apply the nudge

```bash
kubectl annotate <kind>/<name> -n <ns> \
  homelab.io/retry-nudge=$(date -u +%s) --overwrite
```

Use a repo-namespaced annotation key (`homelab.io/...`) to avoid clobbering vendor metadata. Some operators reconcile away unknown annotations on their next loop — that is fine. The annotation only needs to live long enough for the Informer Update event to fire in `kube-controller-manager` (sub-second).

## Step 4 — Verify the controller reconciled

```bash
kubectl -n <ns> get events --field-selector involvedObject.kind=<workload-kind>,involvedObject.name=<workload-name> \
  --sort-by='.lastTimestamp' | tail -5
```

You should see a fresh `Normal SuccessfulCreate` (or equivalent) within seconds. If still only stale failures, the cause may not be fully fixed at the API-server admission layer (Kyverno webhook reload lag is the common one — wait 10 s and re-annotate). If `Warning FailedCreate` re-appears with a current timestamp, return to Step 0.

## Step 5 — Watch the workload to steady state

```bash
kubectl -n <ns> get <kind> <name> -w
# or, for replica counts:
kubectl -n <ns> get <kind> <name> -o jsonpath='{.status.readyReplicas}/{.status.replicas}{"\n"}'
```

Continue until `readyReplicas == replicas`. For sequential rollouts (StatefulSets), each pod-ordinal must reach Ready before the next is created — total time is dominated by per-pod startup.

## Step 6 — Hand off to ArgoCD

Once the workload is steady, force-refresh the parent Application(s) so ArgoCD's per-resource Health reflects the recovery:

```bash
kubectl annotate application <app-name> -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite
```

If the parent Application had previously exhausted its 5-retry budget (`status.operationState.phase: Failed`, message *"retried 5 times"*), additionally clear the stale operation state — but **only after** the relevant child resource's Health is verified True/Healthy (see `.claude/rules/argocd-troubleshooting.md` §Exhausted auto-sync retries; the race condition is documented in the 2026-05-11 postmortem §Recovery Timeline Step 6).

```bash
kubectl patch app <app-name> -n argocd --type json \
  -p '[{"op":"remove","path":"/status/operationState"}]'
```

## Mechanism (FYI — why this works)

`kube-controller-manager` built-in controllers (StatefulSet, Deployment, DaemonSet, Job, ReplicaSet) use `DefaultControllerRateLimiter`:

```go
NewMaxOfRateLimiter(
    NewItemExponentialFailureRateLimiter(5*time.Millisecond, 1000*time.Second),
    &BucketRateLimiter{Limiter: rate.NewLimiter(rate.Limit(10), 100)},
)
```

Rate-limited requeues (via `AddRateLimited`) accumulate exponential backoff per workqueue key, capping at 1000 s. The per-key counter resets only on explicit `Forget()` after a successful reconcile. Informer event handlers (`AddFunc`, `UpdateFunc`, `DeleteFunc`) call plain `workqueue.Add()`, which adds the item immediately regardless of rate-limit state. Any change visible to the watch — including a no-op metadata write — fires the handler.

The technique is generic across controllers. The reason this skill lives in the ArgoCD domain is that the operational context where you need it is **ArgoCD-coupled**: ArgoCD's auto-sync retry counter eventually surfaces the latent failure as Application Degraded, and the safety preconditions (ownership boundary, the `refresh=hard` chase pattern) are ArgoCD-specific.

## Anti-patterns

- **`kubectl delete pod` on a missing peer to "force" recreation** — there is no pod to delete. The StatefulSet/Deployment controller is the one in backoff, not the kubelet.
- **`kubectl scale --replicas` on the workload** — touches spec, which is reconciled by ArgoCD or its parent operator; produces drift and probably a CI rejection. Use it only if the workload is directly hand-rolled and not managed.
- **`kubectl rollout restart`** — equivalent in effect to a metadata annotation BUT writes a `kubectl.kubernetes.io/restartedAt` field that ArgoCD or some operators reconcile away as drift. The repo-namespaced annotation pattern is safer.
- **Bouncing the operator pod to force re-reconcile** — works but is over-broad: the operator restart re-evaluates every CR it owns, not just the stuck one. Side effects may include re-applying CRD defaults, re-issuing client certs, or surfacing transient connection errors elsewhere.

## Related

- Rule: `.claude/rules/argocd-troubleshooting.md` — sync retries, stale operationState, `refresh=hard` pattern.
- Rule: `.claude/rules/argocd-structure.md` — App-of-Apps + per-resource Health aggregation behavior.
- Postmortem: `docs/2026-05-11-vault-quorum-kyverno-cert-manager-cascade.md` — concrete first application of this skill.
- Skill: `.claude/skills/argocd-app-unstick/` — sibling skill for the App-level recovery (Application stuck in OutOfSync / Degraded / Missing).
