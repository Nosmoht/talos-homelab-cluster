# Freeze-Learnings — Talos-Homelab Primitives (CLOSED 2026-04-26)

> **Status: freeze lifted 2026-04-26.** This file is preserved as a historical log. New primitive work happens directly in `.claude/skills/`, `rules/`, `agents/` again. Backlog entries previously parked here are now actionable in this repo without carve-out gymnastics.

## Closing rationale

The user lifted the freeze on 2026-04-26: "Der Harness frozen wird hiermit aufgehoben. Aktuell ist der harness und das wissen in den skills und agents das was am meisten mehrwert bringt." Concentrating primitive authoring solely in the harness repo was no longer the right trade-off — the in-repo skills/agents/rules deliver more direct value at this stage of the platform's evolution. The hard-stop date 2026-07-13 was retired ahead of schedule.

CI enforcement (`.github/workflows/freeze-guard.yml`) removed in the same commit as this banner. The `freeze-exception` GitHub label is no longer load-bearing and can be deleted at convenience.

## Original context (preserved for the record)

Talos-Homelab `.claude/skills/**`, `rules/**`, `agents/**` were frozen 2026-04-14 → 2026-04-26 during `kube-agent-harness` development. New primitive work was redirected to `github.com/devobagmbh/kube-agent-harness`. Carve-out for hooks + `validate-gitops` + `gitops-health-triage`. See `Plans/swirling-strolling-alpaca.md` for the original freeze rule and carve-out (gitignored).

## How to log an entry

Append below. Do not edit earlier entries. Format:

```
### <YYYY-MM-DD> — <short title>

**Context:** what were you doing / what broke / what felt missing
**Proposal:** what primitive (skill/rule/agent) would help, or what existing one needs what change
**Target:** where the proposal should land (harness Core / harness provider / Homelab-only keeping or creating)
**Links:** PR, issue, incident, commit refs
```

Alternative: open a GitHub issue with label `freeze-learning` — preferred if issue flow is already active.

## Entries

<!-- New entries below this marker. Newest at the bottom. -->

### 2026-04-15 — Emergency exception: two rule files edited outside carve-out

**Context:** During MinIO root-credential rotation incident follow-up, a `rollout restart deploy linstor-controller` issued as a routine diagnostic triggered a cert-manager rotation with ECDSA/RSA algorithm mismatch and flipped all six LINSTOR satellites OFFLINE, causing a full storage control-plane outage. Parallel research on MinIO revealed both `minio/operator` and `minio/minio` upstream repos archived in Q1 2026 with the `AdminJob` CRD reconciler never shipping in any tagged release. Leaving both findings only in per-user Claude memory would guarantee repeat incidents in future sessions (other tools, other operators) since the guardrails would not surface when someone edits MinIO or LINSTOR manifests.

**Decision:** User (sole maintainer) granted a narrow emergency exception to the primitives freeze for this one migration. The freeze otherwise remains in effect until the 2026-07-13 hard-stop.

**Proposal:** N/A — work already completed. Audit trail:
- `docs(linstor): capture controller-restart SSL failure mode in guardrails` (commit `c93b08f`) — extends `.claude/rules/linstor-storage-guardrails.md` § Known Failure Modes and § Safety Constraints.
- `docs(minio): add end-of-life exit posture rule` (commit `532f6d5`) — creates `.claude/rules/minio-exit.md` with `paths:` frontmatter and adds row to `AGENTS.md` § Domain Rules table.

**Target:** Already landed in `.claude/rules/`. No follow-up action for the switch-project.

**Links:** `Plans/snappy-growing-boole.md`, commits `c93b08f` and `532f6d5`, session 2026-04-15. Memory `project_homelab_primitives_frozen.md` updated with matching exception record.

### 2026-04-15 — Emergency exception: four cross-cutting operational learnings

**Context:** Continuation of the 2026-04-15 MinIO credential rotation session. Diagnosing why LINSTOR satellites remained OFFLINE and Loki continued failing after the Cilium and MinIO recoveries surfaced four non-obvious failure modes that are likely to recur:
1. Cilium operator lease-lock timeouts → agents hold incomplete BPF service maps → ClusterIP timeouts that look like pod-specific networking issues.
2. PNI CCNPs enforce a two-layer label filter (namespace `consume.*` + pod `capability-consumer.*`); missing the pod-level label is invisible until strict Cilium enforcement activates, e.g. after an agent restart.
3. DRBD kernel state can persist as a "zombie" resource after LINSTOR removes a node replica — `drbdadm` has no config for it but `drbdsetup status` reports `quorum:no` and the HA controller taints the node. Cleanup requires `drbdsetup down <resource>` via netlink.
4. StatefulSet `RollingUpdate` never progresses past a pod stuck in CrashLoopBackOff — `kubectl rollout restart` does not delete the broken pod, so template fixes reach zero pods. Force-delete is required.
5. (Refinement of existing LINSTOR guardrail) If the `linstor-controller` pod starts during a cert-manager rotation window, the init container can build a corrupt in-memory Java truststore even when the on-disk JKS is later correct. A second restart after cert stabilisation is the fix.

**Decision:** User (sole maintainer) granted a second narrow emergency exception to the primitives freeze to capture these. Freeze otherwise remains in effect until 2026-07-13 hard-stop.

**Proposal:** N/A — already landed in repo. Audit trail:
- `docs(agents): require pod-level PNI capability-consumer labels` — AGENTS.md §PNI Rules expanded with the pod-level contract.
- `docs(linstor): add DRBD zombie cleanup and cert-rotation nuance` — extends `.claude/rules/linstor-storage-guardrails.md` § Known Failure Modes.
- `docs(argocd): statefulset rollout deadlock gotcha` — extends `.claude/rules/argocd-troubleshooting.md` § Resource Management Gotchas.
- `docs(cilium): new rule for BPF service-sync troubleshooting` — creates `.claude/rules/cilium-service-sync.md` with `paths:` frontmatter and AGENTS.md §Domain Rules row.

**Target:** Already landed. No follow-up action for the switch-project.

**Links:** Continuation of the same session as the prior entry; commits follow `3c9b101` (the PNI-label fix for Loki that first surfaced the pod-label gap).
