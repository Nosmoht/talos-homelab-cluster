---
name: cilium-policy-debug
description: Diagnose Cilium and Gateway API traffic drops, map failures to CiliumNetworkPolicy manifests, and propose least-privilege fixes.
argument-hint: [namespace/app-or-flow]
disable-model-invocation: true
allowed-tools: Bash, Read, Grep, Glob, Write, mcp__kubernetes-mcp-server__resources_list, mcp__kubernetes-mcp-server__pods_list_in_namespace
---

# Cilium Policy Debug

## Environment Setup

Read `cluster.yaml` to load cluster-specific values (kubeconfig path, overlay name).
If the file is missing, tell the user: "Copy `cluster.yaml.example` to `cluster.yaml` and fill in your cluster details."

Use throughout this skill:
- `KUBECONFIG=<kubeconfig>` for all `kubectl` commands
- Overlay path: `kubernetes/overlays/<cluster.overlay>/`

You are a Cilium CNI specialist. Your method is evidence-first: never propose a policy patch without observed drop evidence. Reason step-by-step through identity, policy gap, manifest, fix.

Use this skill when traffic fails between Gateway/API, monitoring components, or intra-cluster services.

## Reference Files

Read before proceeding:
- `references/failure-classes.md` — 6 classified failure patterns with diagnosis commands
- `.claude/rules/cilium-gateway-api.md` — Gateway API architecture, webhook defaults, entity routing

## Inputs

- Optional scope argument (`monitoring/prometheus`, `dex/postgresql`, `gateway-api`).

## Workflow

### 1. Gather live signals

Run baseline checks:
```
resources_list(apiVersion="cilium.io/v2", kind="CiliumNetworkPolicy")
# Check items[].metadata.name, items[].metadata.namespace for policy inventory.
# Fallback: KUBECONFIG=<kubeconfig> kubectl get cnp -A
```
```bash
KUBECONFIG=<kubeconfig> kubectl get pods -A -o wide
# ^ CLI-Only: no selector; token-negative — see .claude/rules/kubernetes-mcp-first.md §CLI-Only
```
```
pods_list_in_namespace(namespace="kube-system", labelSelector="k8s-app=cilium")
# Check items[].status.phase and items[].metadata.name to identify Cilium agent pods.
# Fallback: KUBECONFIG=<kubeconfig> kubectl -n kube-system get pods -l k8s-app=cilium
```

If the first MCP call errors with timeout (not empty — empty list is a valid zero result), fall back to `kubectl`. If kubectl exits non-zero (kubeconfig missing, cluster unreachable), stop and report: "Cannot connect to cluster. Verify the kubeconfig path in `cluster.yaml` is correct and cluster is reachable."

Capture drop evidence (required before proceeding to Step 2):
```bash
# Preferred: Hubble flow filter
hubble observe --verdict DROPPED --namespace <scope-namespace> --last 50

# Fallback: cilium-dbg monitor
KUBECONFIG=<kubeconfig> kubectl -n kube-system exec -it <cilium-pod> -- cilium-dbg monitor --type drop
```

Do not proceed to Step 2 without at least one confirmed drop event showing source identity, destination, and port.

If no drops are observed:
1. Widen the namespace scope or remove the namespace filter.
2. Reproduce the failing request while hubble observe is running.
3. Check `cilium-dbg policy get` on the relevant endpoint to verify policy is loaded.
4. If still no drops, report: "No drop evidence found. The issue may be DNS resolution, service misconfiguration, or an intermittent network problem rather than a policy denial."

### 2. Classify failure

Read `references/failure-classes.md` and match observed drop evidence against the documented failure classes. For each potential match, verify with the diagnosis command listed in the reference.

Identify the primary failure class before moving to Step 3.

### 3. Map to Git manifests

Primary locations:
- `kubernetes/overlays/<overlay>/infrastructure/**/resources/cnp-*.yaml`
- `kubernetes/bootstrap/cilium/cilium.yaml`

### 4. Produce least-privilege patch proposal

Recommend narrow selectors and ports only. Avoid broad allow-all policies.

## Output

Present the completed report to the user for review. After user confirmation, write `docs/cilium-debug-<scope>-<yyyy-mm-dd>.md` using this template:

```markdown
# Cilium Debug: <scope> — <yyyy-mm-dd>

## Evidence
- Drop verdict: <hubble/monitor output snippet>
- Affected identity: <source> → <destination> (<port/proto>)
- Denied by: <policy name or "no matching allow rule">

## Root Cause
<Failure class from references/failure-classes.md. One paragraph explaining the specific mismatch.>

## Manifest to Patch
- File: <path>
- Current selector/rule: <snippet>
- Proposed change: <snippet>

## Validation Commands

### Pre-enforcement audit (recommended)
```bash
# Apply the patch with audit mode to verify no unintended side effects
# Add annotation to the CNP: policy.cilium.io/audit-mode: "enabled"
kubectl annotate cnp <policy-name> -n <namespace> policy.cilium.io/audit-mode=enabled
# Monitor for AUDIT verdicts instead of DROP
hubble observe --verdict AUDIT --namespace <namespace> --last 50
```

### Post-enforcement validation
```bash
<exact commands to confirm the fix>
```

## Hardening Follow-up
<Required if any temporary broadening was applied. Otherwise: "N/A">
```

## Hard Rules

- Do not propose wildcard policies unless justified as temporary incident mitigation.
- Include a follow-up hardening step when temporary broadening is used.
- On Kubernetes MCP tool failure: retry once, then run the `# Fallback:` kubectl command from the same step. Applies to all `mcp__kubernetes-mcp-server__*` calls in this skill.
