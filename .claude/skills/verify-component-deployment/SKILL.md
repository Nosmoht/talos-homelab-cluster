---
name: verify-component-deployment
description: "Verify a deployed ArgoCD infrastructure component is healthy — probes ArgoCD sync, workloads, custom CRs, network policies, and observability artifacts."
argument-hint: "<component> (e.g., tetragon, kube-prometheus-stack, piraeus-operator)"
disable-model-invocation: true
allowed-tools: Bash, Read, Grep, Glob, mcp__kubernetes-mcp-server__resources_get, mcp__kubernetes-mcp-server__resources_list, mcp__kubernetes-mcp-server__pods_list_in_namespace, mcp__kubernetes-mcp-server__events_list, mcp__kubernetes-mcp-server__pods_log
---

# Verify Component Deployment

## Environment Setup

Read `cluster.yaml` for kubeconfig path and overlay name.
If the file is missing, stop: "Copy `cluster.yaml.example` to `cluster.yaml` and fill in your cluster details."

```bash
KUBECONFIG=$(yq '.kubeconfig' cluster.yaml)
OVERLAY=$(yq '.cluster.overlay // "homelab"' cluster.yaml)
```

If any variable is empty after extraction, stop: "Required field missing in `cluster.yaml`. Check `cluster.yaml.example` for the schema."

## Reference Files

Read before acting:
- `cluster.yaml` — kubeconfig, overlay name
- `.claude/rules/argocd-structure.md` — ArgoCD patterns, sync-wave ordering, GitOps constraints

## Inputs

- `$ARGUMENTS`: component name matching the overlay directory name (e.g., `tetragon`, `kube-prometheus-stack`, `piraeus-operator`)

Examples:
```
/verify-component-deployment tetragon
/verify-component-deployment kube-prometheus-stack
/verify-component-deployment piraeus-operator
```

## Scope Guard

This is a **read-only** health check. If problems are found, suggest the appropriate remediation skill — do not attempt to fix anything.

Remediation routing:
- ArgoCD sync failures → `/gitops-health-triage`
- Cilium policy drops or CNP issues → `/cilium-policy-debug`
- Storage degraded → `/linstor-storage-triage`
- GitOps drift → `/validate-gitops`

**Prohibited actions:** `kubectl apply`, `kubectl delete`, `kubectl patch`, `kubectl edit`, `kubectl scale`, decrypting SOPS secrets, any write to the filesystem, any git operation.

## Workflow

### Phase 1 — Discovery

Set the overlay path:
```bash
OVERLAY_PATH="kubernetes/overlays/${OVERLAY}/infrastructure/${ARGUMENTS}"
```

**Early-exit check:** If `${OVERLAY_PATH}/application.yaml` does not exist, output:
```
| Check      | Status | Detail |
|------------|--------|--------|
| Component  | SKIP   | Not found at ${OVERLAY_PATH} — not an ArgoCD-managed component or wrong name |

Overall: SKIP — verify the component name matches its overlay directory.
```
Stop. Do not continue.

**Inventory the component** by reading the overlay directory. Record each of the following:

1. **Namespace** — `yq '.spec.destination.namespace' ${OVERLAY_PATH}/application.yaml`
2. **Chart + version** — from `application.yaml` sources
3. **Resources directory** — list all YAML files in `${OVERLAY_PATH}/resources/` (if it exists)
4. **Helm values scan** — if `${OVERLAY_PATH}/values.yaml` or `kubernetes/base/infrastructure/${ARGUMENTS}/values.yaml` exists, scan for:
   - `serviceMonitor.enabled: true` or `serviceMonitor.create: true` → add ServiceMonitor to inventory (name defaults to component name)
   - `prometheusRule.enabled: true` → add PrometheusRule to inventory
   - `grafana.dashboards` or `dashboardProviders` → add dashboard to inventory
   This detection supplements `resources/` YAML discovery — do not replace it.

For each `.yaml` file in `resources/` (excluding `kustomization.yaml`), extract:
```bash
yq '.apiVersion + " " + .kind + " " + .metadata.name' <file>
```

Classify each resource into probe categories:
- `DaemonSet`, `Deployment`, `StatefulSet` → workload probes
- `CiliumNetworkPolicy` → CNP probes
- `ServiceMonitor` → observability probes
- `PrometheusRule` → observability probes
- `ConfigMap` with apparent dashboard content (file name contains `dashboard`) → dashboard probes
- Everything else → custom CR probes (extract full GVK via `yq '.apiVersion + "/" + .kind'`)

Also check for:
- Dashboard JSON files: `${OVERLAY_PATH}/resources/dashboards/*.json` (Helm sidecar-loaded pattern)
- SOPS-encrypted secrets: files matching `*.sops.yaml` or containing `sops:` key → record as PRESENT but never read content

**Note:** Workloads synthesized by operator CRs (e.g., a `LinstorCluster` CR that creates DaemonSets) may not appear as explicit YAML in `resources/`. The pod sweep in Phase 5 will catch these.

Record the inventory before proceeding. Every declared probe class must yield at least one result.

---

### Phase 2 — ArgoCD Application Health

```
resources_get: kind=Application, name=<component>, namespace=argocd
```

Check:
- `status.sync.status == "Synced"` → OK; `OutOfSync` → WARN; any error → CRIT
- `status.health.status == "Healthy"` → OK; `Degraded` → CRIT; `Progressing` → WARN
- `status.operationState.phase` — if `Running` or `Error`, record details

Record result as `ArgoCD sync` and `ArgoCD health` rows.

---

### Phase 3 — Namespace and PSA

```
resources_get: kind=Namespace, name=<namespace>
```

Check:
- Namespace exists → OK; missing → CRIT (component cannot be running)
- PNI label `platform.io/network-interface-version: v1` present → OK; missing → WARN
- PSA enforce label present (`pod-security.kubernetes.io/enforce`) → OK; missing → WARN

Record as `Namespace` row.

---

### Phase 4 — Workload Probes

Run probes only for workload kinds explicitly declared in Phase 1 (or that may be operator-synthesized — see Phase 5 sweep).

**DaemonSet** (for each discovered):
```
resources_get: kind=DaemonSet, name=<name>, namespace=<ns>
```
Pass: `status.numberReady == status.desiredNumberScheduled`
Fail: `numberReady < desiredNumberScheduled` → CRIT with counts

**Deployment** (for each discovered):
```
resources_get: kind=Deployment, name=<name>, namespace=<ns>
```
Pass: `status.readyReplicas == spec.replicas`
Fail: mismatch → CRIT with counts

**StatefulSet** (for each discovered):
```
resources_get: kind=StatefulSet, name=<name>, namespace=<ns>
```
Pass: `status.readyReplicas == spec.replicas` AND `status.currentRevision == status.updateRevision`
Fail: either mismatch → CRIT; revision mismatch alone → WARN (rolling update in progress)

---

### Phase 5 — Pod Readiness and Warning Events

**Pod sweep — universal floor:**
```
pods_list_in_namespace: namespace=<ns>
```

Assert:
- All pods `Running` → OK; any `Pending`/`CrashLoopBackOff`/`OOMKilled` → CRIT
- All containers `ready: true` → OK; any `ready: false` → CRIT with container name

**Operator-synthesized children sweep:**
List all pods with label `app.kubernetes.io/instance=<component>` in the namespace. If pods appear here that have no corresponding declared workload from Phase 1, note them (operator-created) but do not fail on them.

**Warning events:**
```
events_list: namespace=<ns>, fieldSelector=type=Warning
```

Fail if any event in the last hour has reason:
- `BackOff`, `CrashLoopBackOff`
- `Failed`, `FailedMount`, `FailedScheduling`
- `OOMKilling`

WARN for other Warning events. OK if none.

---

### Phase 6 — Custom CR Probes

For each non-workload, non-CNP resource classified in Phase 1:

```
resources_list: apiVersion=<apiVersion>, kind=<kind>, namespace=<ns>
```

GVK extraction (Phase 1 already recorded this via `yq '.apiVersion + "/" + .kind'` from each resource file).

Assert:
- If `resources_list` returns an API error containing "no matches for kind" or "resource type not found": CRIT "CRD not installed for <kind> — check `kubectl get crd | grep <group>`"
- If `resources_list` returns empty list (CRD exists, no instances): CRIT "Expected instance <name> not found"
- The instance named in the resource file is present → OK

Status subresource heuristics (apply to any custom CR):
- If `apiVersion` contains `v1alpha1` or `v1beta1`: status subresource is likely absent or sparse. Presence of the instance + ArgoCD `Synced` = OK. Note in output: "no status subresource".
- If the CR's `.status` object contains a `conditions` array: assert at least one condition with `type: Ready` or `type: Available` and `status: "True"`.
- If `.status` is empty or absent: treat as OK with note. Do not CRIT on missing status for alpha-API resources.

---

### Phase 7 — CiliumNetworkPolicy Probes

If CNPs were discovered in Phase 1:

```
resources_list: kind=CiliumNetworkPolicy, namespace=<ns>
```

Count the live CNPs. Compare to the count of `cnp-*.yaml` files found in `resources/` during Phase 1.

- Count matches → OK
- Live count < file count → WARN: "Expected N CNPs, found M — possible sync gap"
- Live count > file count → WARN: "More CNPs live than in git — possible orphan"

If no CNPs were declared in Phase 1, record as SKIP.

---

### Phase 8 — Observability Probes

**ServiceMonitor:**
If a `ServiceMonitor` resource was discovered in Phase 1 (via `resources/` YAML or known to be in Helm chart values):
```
resources_get: kind=ServiceMonitor, name=<name>, namespace=<ns>
```
Check: exists, and `spec.selector` is populated.
If absent: CRIT (Prometheus cannot scrape the component).

If no ServiceMonitor declared: SKIP.

**Dashboard — ConfigMap pattern** (files like `resources/grafana-dashboard.yaml`):
```
resources_get: kind=ConfigMap, name=dashboard-<component>, namespace=<ns>
```
Check: exists, label `grafana_dashboard: "1"` present (sidecar-discoverable).

**Important:** Dashboard ConfigMaps do NOT always live in `monitoring`. Grep the resource file during Phase 1:
```bash
yq '.metadata.namespace' resources/grafana-dashboard.yaml
```
Use that namespace for the probe, not `monitoring`.

**Dashboard — JSON sidecar pattern** (files in `resources/dashboards/*.json`):
If JSON dashboard files were discovered in Phase 1, check that the Grafana sidecar has imported them. Look for the `grafana-sc-dashboard` container in the kube-prometheus-stack Grafana pod:
```
pods_log: namespace=monitoring, container=grafana-sc-dashboard
```
Search for the dashboard filename in recent log output. Missing import → WARN (sidecar may still be loading; not a hard failure).

If no dashboards declared: SKIP.

**PrometheusRule** (if declared):
```
resources_get: kind=PrometheusRule, name=<name>, namespace=<ns>
```
Check: exists. If absent: WARN.

---

## Output

Present a health report table to the user. Status values: `OK`, `WARN`, `CRIT`, `SKIP`.

```
## verify-component-deployment: <component>

Chart: <name> v<version>
Namespace: <ns>
ArgoCD sync-wave: <n>

| Check              | Status | Detail                          |
|--------------------|--------|---------------------------------|
| ArgoCD sync        | OK     | Synced                          |
| ArgoCD health      | OK     | Healthy                         |
| Namespace/PSA      | OK     | privileged                      |
| DaemonSet          | OK     | numberReady=8/8                 |
| Pods               | OK     | 9/9 Running, all containers ready |
| Warning events     | OK     | none in last hour               |
| TracingPolicy (3)  | OK     | 3/3 present                     |
| ServiceMonitor     | OK     | tetragon, scrapeInterval=10s    |
| Dashboard ConfigMap| OK     | dashboard-tetragon (ns=tetragon)|
| CNPs               | SKIP   | none declared                   |

Overall: PASS (0 CRIT, 0 WARN, 1 SKIP)
```

If any CRIT:
```
Overall: FAIL (N CRIT, M WARN)
Recommended next step: /gitops-health-triage <component>
```

## Hard Rules

- **Read-only:** no writes to the filesystem, no cluster mutations, no `kubectl apply/delete/patch/edit/scale`
- **No SOPS decryption:** if encrypted secret files are found during discovery, record their presence as OK (ArgoCD manages them) and skip content inspection entirely
- **Skip gracefully:** if a probe class was not declared during discovery (e.g., no dashboard), record as SKIP — never fail on absent optional resources
- **No hardcoded component knowledge:** all probe targets come from Phase 1 discovery, not from built-in Tetragon/Piraeus/etc. assumptions
- **Fail closed on declared probes:** if Phase 1 records a resource class but Phase 6/7/8 returns zero matches, that is a CRIT — a declared resource that's missing is not the same as an optional resource being absent
- **Use Phase 1 namespace for all probes** — do not assume `monitoring` or `kube-system`; always use the namespace from `application.yaml`
