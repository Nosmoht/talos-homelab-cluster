---
paths:
  - "kubernetes/**/kyverno-clusterpolicy-*.yaml"
  - "kubernetes/**/clusterpolicy-*.yaml"
  - "kubernetes/**/policy-*.yaml"
---

# Kyverno ClusterPolicy / Policy Authoring

## `allowExistingViolations` Is a One-Way Ratchet

`allowExistingViolations: true` lets a tightened policy land in Enforce without breaking pods that are already running with violations. **This is not a free pass.** The semantics are:

- Existing pods stay running (audit reports recorded as `PolicyReport` but admission is not retroactively re-evaluated).
- The first time **any** of those existing pods is recreated — voluntary disruption (drain), involuntary disruption (OOM, node loss, ImagePullBackOff retry), Talos schematic update, operator-driven rollout, controller-restart-triggered re-sync, scheduler eviction — the new admission event hits Enforce.
- If the workload is governed by a controller with rate-limited workqueue retries (StatefulSet, Deployment, DaemonSet, Job), repeated denials accumulate to the 1000 s exponential cap. The workload may stay degraded for hours, surface only via downstream symptoms, and require operator nudging to recover (see `.claude/skills/argocd-controller-backoff-escape/SKILL.md`).

**Before merging a tightening change to a Kyverno policy in Enforce mode:**

1. **Audit pre-existing violators**:
   ```bash
   kubectl get policyreport -A -o json \
     | jq -r '.items[].results[]? | select(.policy=="<policy-name>" and .result=="fail") | "\(.resources[0].kind)/\(.resources[0].namespace)/\(.resources[0].name) → \(.rule)"' \
     | sort -u
   ```
2. **Cross-check each violator** against the new allow conditions. Will the next recreation event admit successfully?
3. **For each grandfathered workload that still fails the new rules**, decide:
   - Adjust the workload (update Pod labels via the operator's CR or chart values) — preferred.
   - Add a tamper-verified operator signature to the allow chain (see next section).
   - Accept the latent failure and document it in the PR.
4. **Verify upstream signal**: an alert on `kube_statefulset_status_replicas_available < kube_statefulset_status_replicas` (per namespace) is the minimum detection for the latent-failure case. Without it, a grandfathered workload can sit at degraded replica count for days before a downstream consumer surfaces the symptom.

## Operator-Managed Pod-Label Signatures in Allow Chains

When extending a Kyverno ClusterPolicy's deny chain with a new "trusted operator signature" allow path (e.g., adding `vault_cr`, `app.kubernetes.io/managed-by=cloudnative-pg`, etc.), the signature's **tamper profile must be verified against the operator's source code, not inferred by analogy.**

### Tamper Profile Classification

Two profiles based on how the operator constructs the Pod template labels:

- **Tamper-resistant** — operator hardcodes the label from a derived constant (e.g., CR name) AND filters user-supplied metadata before merging, so a CR author **cannot** inject or override the label. Example: rabbitmq-cluster-operator drops user-supplied `app.kubernetes.io/*` keys during label merge (see `rabbitmq/cluster-operator v2.20.0 internal/metadata/label.go`).
- **Tamper-visible** — operator writes a default value but a CR author **can** override it by setting `spec.labels` / `spec.podLabels` / equivalent, because the operator's merge order is `operator-defaults → user-overrides`. Examples:
  - OT-Container-Kit redis-operator (operator applies stable labels first, then merges CR `metadata.labels` on top).
  - bank-vaults vault-operator v1.23.4 (`withVaultLabels` at `pkg/controller/vault/vault_controller.go:2283-2293` iterates `v.Spec.GetVaultLabels()` and overwrites: `for k,v := range v.Spec.GetVaultLabels() { l[k]=v }`).

### Authoring Discipline

1. **Read the operator's pod-template builder** — typically `pkg/controller/<operator>/...` or `internal/<operator>/...` in the operator source. Look for the function that constructs `corev1.PodTemplateSpec.ObjectMeta.Labels`.
2. **Identify the merge order** — does the operator (a) write hardcoded defaults LAST (tamper-resistant) or FIRST followed by user-supplied labels (tamper-visible)?
3. **Classify and document in the policy comment block** — mirror the existing precedent format in `kubernetes/base/infrastructure/platform-network-interface/resources/kyverno-clusterpolicy-pni-reserved-labels-enforce.yaml` (lines 22–43 at time of writing). Cite source paths inline: `pkg/.../file.go:line-range`.
4. **For tamper-visible signatures, require a downstream discriminator** — the signature alone is insufficient because a CR author can satisfy it. Add one of:
   - An additional namespace co-condition (e.g., `request.object.metadata.namespace == "<operator-ns>"`) when the operator's CRD is gated by an AppProject that scopes CR creation to that namespace.
   - An additional CCNP label match (the redis precedent uses `app.kubernetes.io/managed-by: redis-operator` at the Cilium policy layer).
   - A second, independently-tamper-resistant label from the same operator if one exists.
5. **Never accept a tamper-visible signature without a discriminator on the assumption that the operator is well-behaved** — a future operator version or a misconfigured CR can break the assumption silently.

### Anti-patterns

- "This operator looks like rabbitmq, so let's add the signature." Verify with source — see `~/.claude/rules/capability-claims.md` for the underlying principle.
- "The CR is gated by the AppProject, so users can't override the label." Correct only if the AppProject's `clusterResourceWhitelist` and `namespaceResourceWhitelist` actually prevent creation outside the trusted namespace. Verify in the AppProject manifest before relying on it.
- Stacking many tamper-visible signatures and trusting AND of "non-empty" checks. AND of weak signals is still weak unless one of them is operator-hardcoded.

## Lockstep Across Rules

When a policy has multiple rules that share a deny chain (e.g., one rule for `platform.io/provider,managed-by,capability` and another for `platform.io/capability-provider.*`), add new operator signatures to **all rules with semantically equivalent deny chains** even if the rule's match-set doesn't trigger today. Future operator releases that emit additional reserved labels would re-block grandfathered workloads silently otherwise. The lockstep is cheap (a few lines) and documented as the convention in the trust-model comment block.

## Validation Before Merge

- `make validate-kyverno-policies` runs the in-repo server-side dry-run (`kubectl apply --dry-run=server` against the live cluster's Kyverno admission controller). Catches JMESPath parse errors and references to unknown fields.
- `kubectl kustomize <overlay-or-base-path>` confirms the policy renders correctly.
- Render the updated policy and grep for the new conditions to confirm they reach the cluster after the PR merges:
  ```bash
  kubectl get cpol <name> -o yaml | grep -c <new-signature-key>
  ```

## Mutation Rules vs GitOps Reconciliation

**Hard rule:** every new `mutate:` rule that writes into a field ArgoCD reconciles (any field in a kustomize/Helm-rendered manifest) WILL produce perpetual `OutOfSync` drift on the affected Application. The mutation creates `live ≠ git` on every admission; ArgoCD's `selfHeal: true` resyncs from git; the webhook re-mutates; `autoHealAttemptsCount` accumulates indefinitely. This is structural, not a Kyverno bug or an ArgoCD configuration issue.

**Three safe outcomes for any new mutation rule:**

1. **The mutation-applied value is also declared in git** (the mutation becomes a no-op). Preferred when the value is workload-specific and can live in the chart values.
2. **The need for mutation is eliminated upstream** (the underlying intent expressed via a different mechanism — capability labels, nodeAffinity, network policies, etc.). Preferred when the mutation pattern is the wrong abstraction.
3. **Targeted `ignoreDifferences` on the affected JSON paths**, with an inline comment documenting why mutation cannot be eliminated. Last resort; revisits required when the mutation rule changes.

**Atomic-list trap:** if the mutation targets a `+listType=atomic` field (commonly `pod.spec.tolerations`, container args/command, env without name-keyed merge), `patchStrategicMerge` REPLACES the entire array — silently dropping any chart-declared entries. Verify by reading the live pod template after admission. If the field is atomic, switch to `patchesJson6902` with `op: add, path: <field>/-` and add a precondition that skips when the target value is already present. Reference: [kyverno/kyverno#7327](https://github.com/kyverno/kyverno/issues/7327) (closed as intended behaviour), [Kyverno mutate documentation](https://kyverno.io/docs/policy-types/cluster-policy/mutate/).

**Concrete precedent:** the `pi-reserved-daemonset-toleration` ClusterPolicy (retired 2026-05-12) used `patchStrategicMerge` on `tolerations` and silently dropped chart-declared `nvidia.com/gpu` tolerations on tetragon and NFD DaemonSets while keeping 5 ArgoCD Applications perpetually `OutOfSync`. Full incident analysis: `docs/2026-05-12-kyverno-mutation-vs-gitops-architecture.md`.
