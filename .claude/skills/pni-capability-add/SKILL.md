---
name: pni-capability-add
description: "Add a PNI capability: author CCNP, register in ConfigMap, update Kyverno allowlist, update docs — as one atomic commit. Use when onboarding new platform services."
argument-hint: "<capability-name> --provider <ns/component> --type egress|ingress|api-only"
disable-model-invocation: true
allowed-tools: Bash, Read, Grep, Glob, Write, Edit, mcp__kubernetes-mcp-server__resources_list, mcp__kubernetes-mcp-server__resources_get
---

# PNI Capability Add

## Environment Setup

Read `cluster.yaml` for kubeconfig path.
If the file is missing, stop: "Copy `cluster.yaml.example` to `cluster.yaml` and fill in your cluster details."

Extract before running any commands:
```bash
KUBECONFIG=$(yq '.kubeconfig' cluster.yaml)
```

## Reference Files

Read before acting:
- `docs/platform-network-interface.md` — capability catalog, CCNP patterns, API-only table, onboarding workflow
- `.claude/rules/cilium-network-policy.md` — CCNP naming conventions, identity selectors, post-DNAT ports
- `kubernetes/base/infrastructure/platform-network-interface/resources/capability-registry-configmap.yaml` — current registry (must update)
- `kubernetes/base/infrastructure/platform-network-interface/resources/kyverno-clusterpolicy-pni-capability-validation-enforce.yaml` — current allowlist (must update)

Also read 2-3 existing CCNPs as examples:
```bash
ls kubernetes/base/infrastructure/platform-network-interface/resources/ccnp-pni-*.yaml
```
Read each one to understand the selector and port patterns.

## Inputs

- `<capability-name>`: Name of the new capability (kebab-case, e.g., `tetragon-export`)
- `--provider <ns/component>`: Provider namespace and component (e.g., `tetragon/tetragon-agent`)
- `--type egress|ingress|api-only`: Capability type

## Scope Guard

Before proceeding, run this check:
```bash
grep "<capability-name>" kubernetes/base/infrastructure/platform-network-interface/resources/capability-registry-configmap.yaml
```
If the capability name is found, stop: "Capability '<name>' already registered. To modify it, edit the existing CCNP and update docs/platform-network-interface.md."

If the user wants to onboard a CONSUMER namespace (not add a new capability):
- Stop. Suggest `/onboard-workload-namespace` instead.

If the user wants to debug a CNP traffic drop:
- Stop. Suggest `/cilium-policy-debug` instead.

## Workflow

### 1. Classify capability type

Determine from `--type`:
- `egress`: Consumer namespace initiates traffic TO the platform service. CCNP required.
- `ingress`: Platform service initiates traffic TO consumer namespaces. CCNP required.
- `api-only`: Contract-only (e.g., tls-issuance, storage-csi, logging-ship) — no CCNP needed; only registry + Kyverno + docs entries.

### 2. Look up provider port (skip for api-only)

Determine the container port (post-DNAT) for the provider component. Service ports are NOT the same as container ports — do not use Service `port:` values.

Run:
```
resources_list(apiVersion="v1", kind="Service", namespace="<provider-ns>")
# Fallback: KUBECONFIG=$KUBECONFIG kubectl get service -n <provider-ns> -o jsonpath='{.items[*].spec.ports[*]}'

resources_list(apiVersion="discovery.k8s.io/v1", kind="EndpointSlice", namespace="<provider-ns>")
# Fallback: KUBECONFIG=$KUBECONFIG kubectl get endpointslices -n <provider-ns> -o wide
# Note: project uses EndpointSlice (discovery.k8s.io/v1), never Endpoints (deprecated since Kubernetes v1.33.0)
# kubectl kustomize stays CLI — local render, no cluster call (see .claude/rules/kubernetes-mcp-first.md §CLI-Only)
```

Identify the target container port from the EndpointSlice JSON: `.endpoints[].addresses` shows pod IPs, `.ports[].port` shows the container port. Use that port in the CCNP `toPorts` field.

If the provider is not yet deployed, check `docs/platform-network-interface.md` for a documented port, or ask the user.

### 3. Draft CCNP (skip for api-only)

Draft file path:
```
kubernetes/base/infrastructure/platform-network-interface/resources/ccnp-pni-<capability>-consumer-<egress|ingress>.yaml
```

Rules:
- Use namespace-label selectors: `k8s:io.cilium.k8s.namespace.labels.platform.io/consume.<capability>: "true"`
- Never encode namespace names or Deployment names in consumer-side selectors
- Include explicit `toPorts` with the container port from Step 2 (post-DNAT, not service port)
- Apply `app.kubernetes.io/*` recommended labels
- Follow naming from `.claude/rules/cilium-network-policy.md`

### 4. Draft registry entry

Prepare the new capability name entry for `capability-registry-configmap.yaml` under the appropriate section (egress, ingress, or api-only).

### 5. Draft Kyverno allowlist entry

Prepare the new capability name addition to the allowlist array in:
```
kubernetes/base/infrastructure/platform-network-interface/resources/kyverno-clusterpolicy-pni-capability-validation-enforce.yaml
```

### 6. Draft documentation row

Prepare a new row for the capability table in `docs/platform-network-interface.md`:
- Capability name, type, provider, description, CCNP file (or "N/A" for api-only)

### 7. User Confirmation Gate

Present all drafted changes for user review before writing anything:
- CCNP (if applicable): show the full YAML
- Registry: `capability-registry-configmap.yaml` — show the new entry in context
- Kyverno: show the new allowlist entry in context
- Docs: show the new table row

Wait for explicit confirmation before writing any file.

### 8. Write files and validate

Write all approved files, then run:
```bash
make validate-kyverno-policies
kubectl kustomize kubernetes/overlays/homelab > /dev/null
```

If either fails, stop: "Validation failed. See the error above and fix before committing."

### 9. Atomic commit

All changed files MUST be in a single commit:
```bash
git add kubernetes/base/infrastructure/platform-network-interface/resources/ccnp-pni-<capability>-consumer-<direction>.yaml
git add kubernetes/base/infrastructure/platform-network-interface/resources/capability-registry-configmap.yaml
git add kubernetes/base/infrastructure/platform-network-interface/resources/kyverno-clusterpolicy-pni-capability-validation-enforce.yaml
git add docs/platform-network-interface.md
git commit -m "feat(pni): add <capability-name> capability"
```

## Hard Rules

- CCNP naming MUST follow: `ccnp-pni-<capability>-consumer-egress.yaml` or `-ingress.yaml`
- Never set provider-reserved labels on consumer selectors (`platform.io/provider`, `platform.io/managed-by`, `platform.io/capability`)
- Do NOT opt `privileged` namespaces (`network-profile: privileged`) into `gateway-backend` or `internet-egress`
- All 4 changes (CCNP, registry, Kyverno, docs) MUST land in a single commit — no partial states
- Never `kubectl apply` directly — these are ArgoCD-managed; git commit + push only
- The duplicate-capability check (Scope Guard) MUST run before any authoring begins
