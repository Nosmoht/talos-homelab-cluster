---
name: argocd-app-unstick
description: Unstick an ArgoCD Application stuck in OutOfSync, Degraded, or Missing state. Follows a decision tree from diagnosis to fix.
argument-hint: "<app-name> [--namespace argocd]"
disable-model-invocation: true
allowed-tools:
  - Bash
  - Read
  - Grep
  - mcp__kubernetes-mcp-server__resources_get
---

# ArgoCD App Unstick

## Background

This skill handles ArgoCD Applications stuck in non-healthy states. It follows the decision tree
from `.claude/rules/argocd-troubleshooting.md` — that rule is the authoritative reference; this skill
translates it into an executable step-by-step workflow.

**Scope:** Single-app targeted recovery. For cluster-wide GitOps triage across multiple apps,
spawn the `gitops-operator` agent instead.

**Git is source of truth.** Never `kubectl apply` ArgoCD-managed resources to fix sync issues —
the fix belongs in git. The only exception is `kubernetes/bootstrap/` AppProjects during emergency
bootstrap recovery.

## Environment Setup

Read `cluster.yaml` for cluster-specific values (kubeconfig path).

```bash
KUBECONFIG=<kubeconfig>
ARGOCD_NS=argocd   # override with --namespace if non-default
APP=<app-name>     # from argument
```

---

## Step 1 — Triage: Identify Failure Mode

Fetch the Application resource:

```
resources_get(apiVersion="argoproj.io/v1alpha1", kind="Application", name="<app>", namespace="argocd")
# Fallback: kubectl get application <app> -n argocd -o yaml
```

Extract and record these fields:
- `.status.health.status` — `Healthy` / `Degraded` / `Missing` / `Unknown`
- `.status.sync.status` — `Synced` / `OutOfSync`
- `.status.operationState.phase` — `Running` / `Error` / `Failed` / `Succeeded` / absent
- `.status.operationState.message` — the most useful error field
- `.status.operationState.syncResult.revision` — revision locked by the operation
- `.status.conditions[].message` — ComparisonError, InvalidSpecError, etc.
- `.status.resources[]` — per-resource sync and health status

**Decision table:**

| health | sync | operationState.phase | Most Likely Cause | Go to |
|--------|------|----------------------|-------------------|-|
| Degraded/Missing | OutOfSync | Error/Failed | Sync error — resource create/update failed | §2 |
| Healthy | OutOfSync | absent/Succeeded | Pure drift — config changed, auto-sync not triggered | §3 |
| Any | OutOfSync | Running (> 5 min) | Stale operation — hung sync | §4 |
| Degraded | Synced | Succeeded | Deployed resource unhealthy (crash, OOM, etc.) | §5 |
| Any | OutOfSync | Succeeded + "will not retry" | Exhausted auto-sync retries | §6 |

If the failure mode is ambiguous, read `.status.operationState.message` fully before deciding —
it usually names the specific resource and verb that failed.

---

## Step 2 — Sync Error: Resource Create/Update Failed

### 2.1 Identify the failing resource

```bash
KUBECONFIG=<kubeconfig> kubectl get application "$APP" -n "$ARGOCD_NS" \
  -o jsonpath='{.status.resources[?(@.status=="SyncFailed")]}'
```

Also check `.status.operationState.syncResult.resources` for the first hard failure.

### 2.2 Categorize the error

Read the error message and match to a known pattern:

**a) Immutable field change (e.g., Deployment selector, StatefulSet volumeClaimTemplate):**
```
Deployment.apps "<name>" is invalid: spec.selector: ... field is immutable
```
Fix: delete the conflicting resource, then hard-refresh:
```bash
KUBECONFIG=<kubeconfig> kubectl delete deployment <name> -n <namespace>
KUBECONFIG=<kubeconfig> kubectl annotate application "$APP" -n "$ARGOCD_NS" \
  argocd.argoproj.io/refresh=hard --overwrite
```
Check if the Service also has a stale selector from a three-way merge — delete it too if needed.

**b) AppProject permission denied:**
```
one or more synchronization tasks are not valid
```
Identify the blocked kind from `.status.operationState.message`. Add it to the AppProject's
`spec.clusterResourceWhitelist` in git, then wait for ArgoCD to reconcile the AppProject.
Do NOT `kubectl apply` git-managed AppProjects directly.

**c) CRD not yet installed:**
```
no matches for kind "<Kind>" in version "<apiVersion>"
```
Check the sync-wave of the CRD Application (should be wave 0) vs. this app (wave 1). If the CRD
Application is itself stuck, unstick it first (recursive application of this skill). If CRDs are
present but not yet established, wait 30 s and re-trigger.

**d) SOPS/ksops decryption failure:**
```
failed to decrypt ... failed to decode key
```
Check ArgoCD repo-server for key errors:
```bash
KUBECONFIG=<kubeconfig> kubectl logs deployment/argocd-repo-server -n "$ARGOCD_NS" \
  --tail=50 -c repo-server | grep -i 'sops\|age\|decrypt'
```
If the AGE key is wrong or missing, run `/sops-key-rotate` (Phase 2: update cluster secret only).

**e) Hook Job completed before ArgoCD observed it:**
```
hook ... SyncFailed  (operationState stuck)
```
The hook Job was deleted (DeletePolicy) before ArgoCD logged completion. Clear operationState:
```bash
KUBECONFIG=<kubeconfig> kubectl patch application "$APP" -n "$ARGOCD_NS" \
  --type json -p '[{"op":"remove","path":"/status/operationState"}]'
KUBECONFIG=<kubeconfig> kubectl annotate application "$APP" -n "$ARGOCD_NS" \
  argocd.argoproj.io/refresh=hard --overwrite
```

### 2.3 Trigger sync after fix

After the fix is in git (committed and pushed):
```bash
KUBECONFIG=<kubeconfig> kubectl annotate application "$APP" -n "$ARGOCD_NS" \
  argocd.argoproj.io/refresh=hard --overwrite
```

Then skip to §7 to verify recovery.

---

## Step 3 — Pure Drift: Healthy but OutOfSync

The Application is healthy but shows drift — config changed in git but auto-sync has not yet run.

### 3.1 Confirm drift is real

```bash
# With argocd CLI (preferred):
argocd app diff "$APP"
# Fallback — look for resources with OutOfSync status:
KUBECONFIG=<kubeconfig> kubectl get application "$APP" -n "$ARGOCD_NS" \
  -o jsonpath='{.status.resources[?(@.syncStatus=="OutOfSync")]}'
```

### 3.2 Force refresh

```bash
KUBECONFIG=<kubeconfig> kubectl annotate application "$APP" -n "$ARGOCD_NS" \
  argocd.argoproj.io/refresh=hard --overwrite
```

Wait 30 s, then re-check. If auto-sync triggers and completes: done (§7).

If auto-sync is disabled on this app (`.spec.syncPolicy.automated` is absent or `selfHeal: false`):
the drift is intentional — confirm with the operator before forcing a manual sync.

---

## Step 4 — Stale Operation: Running for > 5 Minutes

A sync operation is stuck in `Running` state.

### 4.1 Confirm staleness

From Step 1, check `.status.operationState.startedAt`. If the operation has been Running for
more than 5 minutes, it is stale.

### 4.2 Terminate the operation

```bash
argocd app terminate-op "$APP"
# Fallback (argocd CLI unavailable):
KUBECONFIG=<kubeconfig> kubectl patch application "$APP" -n "$ARGOCD_NS" \
  --type merge -p '{"operation": null}'
```

### 4.3 Clear stale operationState

If `.status.operationState` persists after terminate:
```bash
KUBECONFIG=<kubeconfig> kubectl patch application "$APP" -n "$ARGOCD_NS" \
  --type json -p '[{"op":"remove","path":"/status/operationState"}]'
```

### 4.4 Force refresh

```bash
KUBECONFIG=<kubeconfig> kubectl annotate application "$APP" -n "$ARGOCD_NS" \
  argocd.argoproj.io/refresh=hard --overwrite
```

Then skip to §7 to verify recovery.

---

## Step 5 — Deployed Resource Unhealthy (Synced but Degraded)

The Application synced successfully but a deployed resource is unhealthy (Deployment rollout
stuck, Pod crash-looping, etc.).

### 5.1 Identify the unhealthy resource

```
resources_get(apiVersion="argoproj.io/v1alpha1", kind="Application", name="<app>", namespace="argocd")
# Filter: .status.resources[] where .health.status != "Healthy"
```

### 5.2 Investigate the resource

For a Deployment/StatefulSet/DaemonSet:
```bash
KUBECONFIG=<kubeconfig> kubectl describe <kind> <name> -n <namespace>
KUBECONFIG=<kubeconfig> kubectl get pods -n <namespace> -l <selector>
KUBECONFIG=<kubeconfig> kubectl logs <pod-name> -n <namespace> --tail=50
```

For a CiliumNetworkPolicy blocking traffic: use `/cilium-policy-debug`.
For a LINSTOR PVC stuck pending: use `/linstor-storage-triage`.

### 5.3 Fix

The fix is always resource-specific. Common patterns:

| Symptom | Likely cause | Action |
|---------|-------------|--------|
| `ImagePullBackOff` | Wrong image tag or missing pull secret | Fix image tag in git; add imagePullSecret if private registry |
| `CrashLoopBackOff` | Application startup failure | Check logs; fix config or image in git |
| `Pending` (no nodes match) | Resource requests exceed available, or missing taint toleration | Fix requests/toleration in git |
| `OOMKilled` | Container memory limit too low | Increase `resources.limits.memory` in git |
| `Init:CrashLoopBackOff` | Init container failure | Check init container logs |

This skill covers the ArgoCD layer only. For deep application debugging, escalate to the relevant
domain skill (`/linstor-storage-triage`, `/cilium-policy-debug`, etc.).

---

## Step 6 — Exhausted Auto-Sync Retries

ArgoCD locks retries to the git revision at first attempt. Pushing fixes after retries started
does not help until all retries exhaust — then ArgoCD stops with "will not retry".

### 6.1 Detect exhausted retries

Look in `.status.operationState.message` for "will not retry" and compare
`.status.operationState.syncResult.revision` against current `git rev-parse origin/main HEAD`.
If they differ, ArgoCD is syncing against a stale revision.

### 6.2 Terminate and clear operationState

```bash
# Terminate first (absorbs any in-flight retry):
argocd app terminate-op "$APP" 2>/dev/null || true

# Clear the locked operationState:
KUBECONFIG=<kubeconfig> kubectl patch application "$APP" -n "$ARGOCD_NS" \
  --type json -p '[{"op":"remove","path":"/status/operationState"}]'
```

### 6.3 Force refresh to pick up latest revision

```bash
KUBECONFIG=<kubeconfig> kubectl annotate application "$APP" -n "$ARGOCD_NS" \
  argocd.argoproj.io/refresh=hard --overwrite
```

ArgoCD will now start a fresh sync cycle from the latest commit. Skip to §7 to verify recovery.

---

## Step 7 — Verify Recovery

Target state: `health == Healthy` AND `sync == Synced`, no active operationState error.

```
resources_get(apiVersion="argoproj.io/v1alpha1", kind="Application", name="<app>", namespace="argocd")
# Check: .status.health.status, .status.sync.status, .status.operationState.phase
```

Poll up to 12 × 10 s = 2 min:

```bash
for i in $(seq 1 12); do
  health=$(KUBECONFIG=<kubeconfig> kubectl get application "$APP" -n "$ARGOCD_NS" \
    -o jsonpath='{.status.health.status}')
  sync=$(KUBECONFIG=<kubeconfig> kubectl get application "$APP" -n "$ARGOCD_NS" \
    -o jsonpath='{.status.sync.status}')
  echo "$i: health=$health sync=$sync"
  [ "$health" = "Healthy" ] && [ "$sync" = "Synced" ] && { echo "Recovery confirmed"; break; }
  sleep 10
done
```

If not recovered after 2 min: escalate to `gitops-operator` agent with:
1. Full Application YAML (`kubectl get application <app> -n argocd -o yaml`)
2. Recent ArgoCD application-controller logs (`kubectl logs deployment/argocd-application-controller -n argocd --tail=100`)
3. Description of all recovery steps already attempted

---

## Hard Rules

- Never `kubectl apply` ArgoCD-managed resources. Git is source of truth. Exception: one-time
  bootstrap AppProjects under `kubernetes/bootstrap/` during emergency recovery.
- Never use `ignoreDifferences` to suppress drift until the root cause (webhook defaulting, CRD
  schema change) is confirmed.
- Never restart `argocd-application-controller` as a first response — it affects ALL apps in the
  cluster. Use `terminate-op` + `operationState` clear + hard-refresh first (§4). Restart is a
  last resort.
- Do not terminate an operation that has been Running for < 5 min — it may be legitimately in
  progress (large Helm chart render, slow webhook).
- If auto-sync is disabled on an app, verify with the operator before forcing a manual sync —
  the disabled state may be intentional.
