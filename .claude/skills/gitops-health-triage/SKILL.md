---
name: gitops-health-triage
description: Triage ArgoCD app sync/health drift and produce a focused remediation plan with safe GitOps-first actions for this homelab repository.
argument-hint: [application-name|all]
disable-model-invocation: true
allowed-tools: Bash, Read, Grep, Glob, Write, mcp__kubernetes-mcp-server__resources_list, mcp__kubernetes-mcp-server__resources_get
---

# GitOps Health Triage

## Environment Setup

Read `cluster.yaml` to load cluster-specific values (kubeconfig path, overlay name).
If the file is missing, tell the user: "Copy `cluster.yaml.example` to `cluster.yaml` and fill in your cluster details."

Use throughout this skill:
- `KUBECONFIG=<kubeconfig>` for all `kubectl` commands
- Overlay path: `kubernetes/overlays/<cluster.overlay>/`

You are an ArgoCD triage specialist. You classify failures precisely and propose GitOps-safe remediations with calibrated confidence. Reason step-by-step: gather evidence, classify, map to manifests, propose fix.

## Reference Files

Read before proceeding:
- `references/argocd-remediation-patterns.md` — Remediation lookup table, confidence calibration, controller log commands
- `.claude/rules/argocd-troubleshooting.md` — Git-as-truth, safe change sequence, drift/retry handling

## Inputs

- Argument: one application name (`dex`, `kube-prometheus-stack`) or `all`.
  - When `all` is specified: triage every application, then sort the output report by severity (Degraded > OutOfSync > Progressing) before listing remediations.
- Kubeconfig: from `cluster.yaml` (`kubeconfig` field).

## Workflow

### 1. Gather status quickly

First verify cluster connectivity:
```
resources_list(apiVersion="argoproj.io/v1alpha1", kind="Application", namespace="argocd")
# Fallback: KUBECONFIG=$KUBECONFIG kubectl -n argocd get applications
```
If the MCP tool errors (not empty — empty list is a valid cluster state), fall back to the kubectl command. If that also exits non-zero (kubeconfig missing, cluster unreachable), stop and report: "Cannot connect to cluster. Verify the kubeconfig path in `cluster.yaml` is correct and cluster is reachable."

If a specific app is provided, also run:
```
resources_get(apiVersion="argoproj.io/v1alpha1", kind="Application", name="<app>", namespace="argocd")
# Fallback: KUBECONFIG=$KUBECONFIG kubectl -n argocd get application <app> -o yaml
KUBECONFIG=$KUBECONFIG kubectl -n argocd describe application <app>
# ^ describe stays CLI — no MCP equivalent for event-aggregated output (see .claude/rules/kubernetes-mcp-first.md §CLI-Only)
```

Extract the exact failure message from the `resources_get` JSON above — read `.status.operationState.message` from the response.
```
# No second MCP call needed — extract from resources_get result: .status.operationState.message
# Fallback: KUBECONFIG=$KUBECONFIG kubectl -n argocd get application <app> \
#   -o jsonpath='{.status.operationState.message}'
```

If the `operationState.message` is empty or generic ("ComparisonError"), inspect controller logs per `references/argocd-remediation-patterns.md`.

### 2. Classify failure mode

Read `references/argocd-remediation-patterns.md` and classify into one of:
- webhook/defaulted-field drift
- immutable field/selector patch rejection
- missing CRD/order dependency
- Cilium network policy blocking hooks or control-plane traffic
- stale operation state / exhausted retries
- admission webhook rejection (distinct from defaulted-field drift — the resource is actively rejected, not just drifting)
- pre/post-sync hook failure (Job pods fail; check hook pod logs: `kubectl -n <namespace> logs -l app.kubernetes.io/managed-by=argocd --tail=50`
  — label-selector logs stay CLI; `pods_log` takes a pod name, not a selector — see `.claude/rules/kubernetes-mcp-first.md` §CLI-Only)
- RBAC / permission denied (service account lacks required verbs on target resources)
- resource quota exceeded (namespace quota blocks resource creation)
- sync loop (external controller drift — HPA, VPA, cert-manager modifying ArgoCD-managed fields; fix with `ignoreDifferences`)
- resource suspended (awaiting external input or manual intervention)

### 3. Map to repository paths

Identify manifests driving the app:
- app CR: `kubernetes/overlays/<overlay>/infrastructure/<component>/application.yaml`
- additional resources: `.../resources/`
- shared values: `kubernetes/base/infrastructure/<component>/values.yaml`
- overlay values: `kubernetes/overlays/<overlay>/infrastructure/<component>/values.yaml`

### 4. Propose GitOps-safe remediation

Consult the remediation lookup table in `references/argocd-remediation-patterns.md` for the matching failure class. Always prefer a git change first. Only propose direct cluster actions when necessary to unblock controller state.

## Output

Present the completed report to the user for review. After user confirmation, write `docs/argocd-triage-<app-or-all>-<yyyy-mm-dd>.md` with:
1. Current state summary
2. Root cause hypothesis + confidence (use calibration from `references/argocd-remediation-patterns.md`):
   - **High**: failure message directly names the resource/field; one class clearly matches
   - **Medium**: circumstantial evidence but no confirmed diff
   - **Low**: multiple plausible classes; further investigation required
3. Exact files to modify
4. Verification commands
5. Emergency-only live actions (if any)

### Example (single app)
```markdown
# ArgoCD Triage: dex (2026-03-24)
## State: OutOfSync / Degraded
Sync failed at 14:02 UTC. Last successful sync: 12:30 UTC.
## Root Cause: Immutable field rejection (High confidence)
Deployment `dex-server` selector changed; Kubernetes rejects in-place update.
## Files to Modify
- `kubernetes/overlays/<overlay>/infrastructure/dex/application.yaml` — add `Replace: true` sync option
## Verification
```bash
KUBECONFIG=<kubeconfig> argocd app sync dex --dry-run
```
## Emergency Live Action
None required.
```

## Hard Rules

- Do not deploy with `kubectl apply` for ArgoCD-managed resources.
- When suggesting live patches (e.g., clear operation state), include the follow-up git change required to make state convergent.
