# Incident recovery plan v4 — final

**Revision:** v4 (post R3 — 2 BLOCKING + 4 WARNING + 3 INFO findings, all addressed)
**Detected:** 2026-05-14 09:55
**Severity:** P0
**Status:** drafted, awaiting R4 (hard-cap round per CLAUDE.md §Review Rigor)

## Delta from v3

R3 surfaced model errors in Phase 3 — `kubectl get clusterissuer` shows
`deletionTimestamp: "2026-05-13T16:38:07Z"` with `foregroundDeletion`
finalizer on all 3 CIs, and `cert-manager` controller App syncResult
already shows `status: Pruned, message: pruned` for all 3. The CIs are
terminating, blocked behind the NS. v3 Phase 3a/3b/3c rested on the
premise that CIs are live cluster-scoped resources that need protection
from prune — they aren't.

R3 simplifications and additions:

1. **Phase 3 simplified.** Drop 3a (`prune:false` defense — moot; CIs
   already terminating). Drop 3b (annotate — will be stripped when
   `foregroundDeletion` finalizer clears, no effect). Keep 3c only
   (clear `/status/operationState` + hard refresh). Add explicit note
   that ClusterIssuers will be re-created by `cert-manager-config` in
   Phase 7b — there is a brief window (few minutes) where no
   ClusterIssuer exists cluster-wide. Document that.
2. **Phase 5.3 policy** `HookSucceeded` → `HookSucceeded,HookFailed`.
   Covers both success and failure cleanup paths without re-introducing
   `BeforeHookCreation` finalizer.
3. **Phase 0.7 expectation** updated to match live state: `M cluster.yaml`
   AND `?? talos/nodes/node-07.yaml`.
4. **Phase 0.9 (new)** rendered NS labels vs live NS labels diff probe.
5. **Phase 9.1 (new)** ACME account-key Secret survival probe.
6. **Phase 5.5 commit body** expanded to enumerate ALL kubectl-only ops.
7. **Phase 11.2** prepends `git fetch origin && git checkout main && git pull --ff-only`.
8. **Phase 8** post-recovery resource sanity: confirm 3 ClusterIssuers
   re-created with correct tracking-id (cert-manager-config) and
   ACME account-key Secret survived.

## Plan (11 phases, gated)

### Phase 0 — Pre-conditions

```
# 0.1 — Job still has finalizer
test "$(kubectl -n cert-manager get job presync-wait-webhook-cert-manager -o jsonpath='{.metadata.finalizers}')" = '["argocd.argoproj.io/hook-finalizer"]'

# 0.2 — NS still Terminating
test "$(kubectl get ns cert-manager -o jsonpath='{.status.phase}')" = 'Terminating'

# 0.3 — failurePolicy=Fail confirmed
kubectl get validatingwebhookconfiguration cert-manager-webhook -o jsonpath='{.webhooks[*].failurePolicy}'
kubectl get mutatingwebhookconfiguration cert-manager-webhook -o jsonpath='{.webhooks[*].failurePolicy}'
# Expect: Fail Fail

# 0.4 — v1beta1 unserved
kubectl api-resources --api-group=external-secrets.io 2>/dev/null | awk '$2 ~ /v1beta1/ && !/generators/'
# Expect: empty

# 0.5 — controller App status carries stale ClusterIssuer entries
test "$(kubectl -n argocd get application cert-manager -o jsonpath='{range .status.resources[?(@.kind=="ClusterIssuer")]}{.name}{"\n"}{end}' | wc -l)" -eq 3

# 0.6 — vault-operator-config currently auto-syncs
test -n "$(kubectl -n argocd get application vault-operator-config -o jsonpath='{.spec.syncPolicy.automated}')"

# 0.7 — current branch + tree state (UPDATED per R3-WARNING)
git status --porcelain
# Expect (exactly):
#   M cluster.yaml
#   ?? talos/nodes/node-07.yaml

# 0.8 — KSOPS SOPS_AGE secret exists in argocd
kubectl -n argocd get secret sops-age -o jsonpath='{.metadata.name}'
# Expect: sops-age (fail soft, log)

# 0.9 — NEW per R3-WARNING — NS labels: rendered vs live diff
diff <(yq 'select(.kind == "Namespace" and .metadata.name == "cert-manager") | .metadata.labels' \
        kubernetes/overlays/homelab/infrastructure/cert-manager/_rendered/manifests.yaml | sort) \
     <(kubectl get ns cert-manager -o yaml | yq '.metadata.labels' | sort)
# Expect: empty diff (or PSA version-pin-only diff).
# On any platform.io/* delta: HARD STOP. Do not re-render manifests mid-incident
# (rendering happens in a separate stage; mid-execution hand-patching is a
# layering violation that will be overwritten on next render). Escalate to user
# for explicit risk-accept; resume plan execution from Phase 0 once labels
# converge. Per R4-W4.

# 0.10 — ClusterIssuers state (NEW per R3-BLOCKING-1)
kubectl get clusterissuer homelab homelab-staging vault-internal \
  -o jsonpath='{range .items[*]}{.metadata.name}: deletionTimestamp={.metadata.deletionTimestamp} finalizers={.metadata.finalizers}{"\n"}{end}'
# Expect: all 3 carry deletionTimestamp and ["foregroundDeletion"] finalizer.
# This is the documented incident state; confirms v4 Phase 3 simplification is
# correct (CIs already terminating, no protection-from-prune needed).
```

If 0.1–0.6 + 0.10 fail, the incident state has changed (someone intervened) —
re-investigate before continuing. 0.7 mismatch → resolve dirty state first.
0.8 missing → escalate. 0.9 platform.io label drift → patch rendered first.

### Phase 1 — Pause vault-operator-config

```
kubectl -n argocd patch application vault-operator-config --type=merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}'
```
**Success:** `.spec.syncPolicy.automated` absent. **Rollback (Phase 10):** restore `{prune:true,selfHeal:true}`.

### Phase 2 — Webhook failurePolicy → Ignore

```
kubectl patch validatingwebhookconfiguration cert-manager-webhook --type=json \
  -p='[{"op":"replace","path":"/webhooks/0/failurePolicy","value":"Ignore"}]'
kubectl patch mutatingwebhookconfiguration cert-manager-webhook --type=json \
  -p='[{"op":"replace","path":"/webhooks/0/failurePolicy","value":"Ignore"}]'
```
**Why:** webhook is dead. While dead, `failurePolicy: Fail` rejects any
admission call to it; we will be mutating ClusterIssuers indirectly during
recovery. `Ignore` lets those through. Restored in Phase 8.3.
**Success:** both show `Ignore`. **Rollback (Phase 8.3):** restore `Fail`.

### Phase 3 — Clear stale controller App state (simplified per R3)

R3-BLOCKING-1+2 findings: the 3 ClusterIssuers already have
`deletionTimestamp` + `foregroundDeletion` finalizer (since 2026-05-13
16:38:07Z). They will be garbage-collected once the NS finalizes
(Phase 6). They are not live resources requiring protection. So v3
Phase 3a (`prune:false` defense) and 3b (annotate tracking-id) are moot.

**Only 3c remains:**
```
kubectl -n argocd patch application cert-manager --type=json \
  -p='[{"op":"remove","path":"/status/operationState"}]'
kubectl -n argocd annotate application cert-manager \
  argocd.argoproj.io/refresh=hard --overwrite
```

**Why:** the controller App is stuck in retry-exhausted state with stale
`status.resources[]` from before the C.2 migration. Clearing
`/status/operationState` lets ArgoCD re-evaluate freshly. The hard
refresh kicks the reconcile immediately (don't wait for the normal
3-min poll).

**Success (poll up to 2 min):**
- `.status.operationState` absent or freshly populated (not the old
  retried-5-times one — check `.lastTransitionTime` is recent).

**Note — accepted outage window:** Between Phase 6 (NS finalize) and
Phase 7b success (config App recreates CIs), there is a window of
~3-10 min during which **no ClusterIssuer exists cluster-wide**. Any
in-flight Certificate issuance during that window will fail or stall.
The cluster already has no functioning webhook for 17h, so no new
Certificate issuance is happening anyway. Existing Certificates with
valid (non-expired) tls.crt remain functional via the cached Secret;
renewal only triggers at 2/3 lifetime remaining.

Probe for both *renewal* AND *in-flight issuance* (R4-B2: renewal-only
probe missed `argocd/argocd-server` which is in active issuance loop):
```
# (renewals within 24h)
kubectl get certificate -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}: renewalTime={.status.renewalTime} notAfter={.status.notAfter}{"\n"}{end}'
# Expect: no renewalTime within next 24h

# (in-flight issuance against any of homelab/homelab-staging/vault-internal)
kubectl get certificate -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}: ready={.status.conditions[?(@.type=="Ready")].status} issuerRef={.spec.issuerRef.name}{"\n"}{end}' \
  | awk '/ready=False/ && /issuerRef=(homelab|homelab-staging|vault-internal)/'
# Known accepted exception: argocd/argocd-server has been failing on
# Vault PKI role mismatch (not caused by this incident) since 2026-05-12.
# Acceptable to leave during outage window; the extra retry cycles do not
# worsen the situation. Document any other matches and risk-accept.
```

**Rollback:** none for clear-operationState (one-way; alternative is to
wait for next reconcile, ~3 min).

### Phase 4 — Bump cert-manager-config retry budget

```
kubectl -n argocd patch application cert-manager-config --type=merge \
  -p '{"spec":{"syncPolicy":{"retry":{"limit":15,"backoff":{"duration":"5s","factor":2,"maxDuration":"3m"}}}}}'
```
**Success:** `.spec.syncPolicy.retry.limit=15`. **Rollback:** restore `limit:5`.

### Phase 5 — Code changes (Bundle A: git commit + push)

**Branch:** `fix/cert-manager-recovery-2026-05-13` forked from `main` (cd045cb).

**5.1 — Flip ExternalSecret to v1:**
`kubernetes/overlays/homelab/infrastructure/cert-manager/resources/external-secret-google-cloud-dns.yaml:1`
`apiVersion: external-secrets.io/v1beta1` → `apiVersion: external-secrets.io/v1`

**5.2 — Flip SecretStore to v1:**
`kubernetes/overlays/homelab/infrastructure/cert-manager/resources/secret-store.yaml:12`
`apiVersion: external-secrets.io/v1beta1` → `apiVersion: external-secrets.io/v1`

**5.3 — Drop BeforeHookCreation, ADD HookFailed (UPDATED per R3-WARNING):**
`kubernetes/overlays/homelab/infrastructure/cert-manager/resources/presync-hook-job.yaml:~9`
```
-    argocd.argoproj.io/hook-delete-policy: HookSucceeded,BeforeHookCreation
+    argocd.argoproj.io/hook-delete-policy: HookSucceeded,HookFailed
```
R3-WARNING: `HookSucceeded` alone leaves a stale Job behind on failure.
`HookSucceeded,HookFailed` cleans up in both paths without the
finalizer-deadlock risk of `BeforeHookCreation`.

**5.4 — Validate:**
```
kubectl kustomize kubernetes/overlays/homelab/infrastructure/cert-manager/resources >/dev/null
```

**5.5 — Commit + push (UPDATED per R3-WARNING — body enumerates ALL ops):**
```
git checkout -b fix/cert-manager-recovery-2026-05-13 main
git add kubernetes/overlays/homelab/infrastructure/cert-manager/resources/external-secret-google-cloud-dns.yaml \
        kubernetes/overlays/homelab/infrastructure/cert-manager/resources/secret-store.yaml \
        kubernetes/overlays/homelab/infrastructure/cert-manager/resources/presync-hook-job.yaml \
        .work/incident-cert-manager-2026-05-13/
git commit -m "$(cat <<'EOF'
fix(cert-manager): unblock NS Terminating deadlock + bump ESO v1beta1→v1

Recovery for the cert-manager namespace stuck-Terminating incident
detected 2026-05-14 09:55 UTC. Three deterministic defects fixed in
source; recovery also requires kubectl-only state ops on six live
ArgoCD/admission resources (see .work/.../plan-v4.md for full list
and rollback steps).

Source-tree fixes:
  * ExternalSecret + SecretStore: external-secrets.io/v1beta1 is no
    longer served by the cluster (only v1 + v1alpha1). Sync apply
    returned "could not find version v1beta1". v1 schema is
    compatible for this codepath (dataFrom.extract + vault
    kubernetes auth) per upstream issue #5478.
  * PreSync Job hook-delete-policy: drop BeforeHookCreation, add
    HookFailed. The former attaches an argocd-managed finalizer
    that blocks NS finalization on NS prune — the root deadlock.
    HookFailed covers the failure-path cleanup without the finalizer.

Kubectl-only state ops executed during recovery (not in this PR):
  * cert-manager controller App: clear /status/operationState +
    hard refresh.
  * cert-manager-config App: retry.limit 5 → 15 (post-recovery
    revert deferred).
  * vault-operator-config App: pause auto-sync during recovery,
    restored post.
  * cert-manager-webhook VWC + MWC: failurePolicy Fail → Ignore
    during recovery, restored post.
  * cert-manager NS PreSync Job: remove
    argocd.argoproj.io/hook-finalizer to unblock NS deletion.

Sibling Apps (kube-prometheus-stack-config, kyverno-config,
vault-config-operator-config) carry the same BeforeHookCreation
defect-class. They are not currently deadlocked but should be
patched. Deferred to follow-up issue filed in Phase 11.

Refs: .work/incident-cert-manager-2026-05-13/plan-v4.md
EOF
)"
git push -u origin fix/cert-manager-recovery-2026-05-13
```

**Success:** commit lands on origin; CI green.
**Rollback:** `git reset --hard HEAD~1 && git push --force-with-lease`
(new branch, no consumers).

### Phase 6 — Unblock NS Terminating

```
kubectl -n cert-manager patch job presync-wait-webhook-cert-manager --type=json \
  -p='[{"op":"remove","path":"/metadata/finalizers"}]'
```
**Success (poll 5 min, every 15 s):** Job NotFound; NS NotFound. After NS
finalizes, the 3 ClusterIssuers also disappear (cascade via
`foregroundDeletion`). This is expected per Phase 3 outage-window note.
**Rollback:** none.

### Phase 7a — Refresh controller App + wait webhook Available

ArgoCD picks up the new commit from Phase 5 (~30s repo-server poll). The
controller App applies `_rendered/manifests.yaml`, including the
Namespace, then Deployments roll out.

```
kubectl -n argocd annotate application cert-manager \
  argocd.argoproj.io/refresh=hard --overwrite
```

**Success (poll up to 10 min):**
1. NS `cert-manager` recreated with PSA + PNI labels matching
   `_rendered/manifests.yaml`.
2. Deployments `cert-manager`, `cert-manager-cainjector`,
   `cert-manager-webhook` reach Available=True.
3. Service `cert-manager-webhook` has ≥1 endpoint.

**Block on this. Do not start Phase 7b until 7a success.**

### Phase 7b — Refresh cert-manager-config

```
kubectl -n argocd annotate application cert-manager-config \
  argocd.argoproj.io/refresh=hard --overwrite
```

**Success (poll up to 8 min):**
1. PreSync Job `presync-wait-webhook-cert-manager` completes Successful
   (no BeforeHookCreation finalizer this cycle).
2. App `.status.sync.status=Synced`, `.status.health.status=Healthy`.
3. ClusterIssuers `homelab`, `homelab-staging`, `vault-internal` recreated
   AND their tracking-id is `cert-manager-config:...` (not the stale
   `cert-manager:...`):
   ```
   kubectl get clusterissuer -o jsonpath='{range .items[*]}{.metadata.name}={.metadata.annotations.argocd\.argoproj\.io/tracking-id}{"\n"}{end}'
   ```
4. ClusterIssuer status shows ACME registration:
   ```
   kubectl get clusterissuer -o jsonpath='{range .items[*]}{.metadata.name}: {.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}'
   ```
   Expect: True for all 3 within 2 min.
5. ExternalSecret + SecretStore apply cleanly on v1 (the v1beta1 error
   from before is gone).

### Phase 8 — Restore prune + CA-bundle + failurePolicy

**8.1 — Restore prune on controller App** (no-op for v4: v3 Phase 3a no
longer applies. Verify it's already `true`.)
```
kubectl -n argocd get application cert-manager -o jsonpath='{.spec.syncPolicy.automated.prune}'
# Expect: true
```

**8.2 — CA-bundle hash match (M1)**
```
vwc_hash=$(kubectl get vwc cert-manager-webhook -o jsonpath='{.webhooks[0].clientConfig.caBundle}' | base64 -d | sha256sum | awk '{print $1}')
sec_hash=$(kubectl -n cert-manager get secret cert-manager-webhook-ca -o jsonpath='{.data.tls\.crt}' | base64 -d | sha256sum | awk '{print $1}')
echo "vwc=$vwc_hash sec=$sec_hash"
[ "$vwc_hash" = "$sec_hash" ] || kubectl -n cert-manager rollout restart deployment cert-manager-cainjector
```
Re-check after 60s on mismatch.

**8.3 — Restore failurePolicy: Fail**
```
kubectl patch validatingwebhookconfiguration cert-manager-webhook --type=json \
  -p='[{"op":"replace","path":"/webhooks/0/failurePolicy","value":"Fail"}]'
kubectl patch mutatingwebhookconfiguration cert-manager-webhook --type=json \
  -p='[{"op":"replace","path":"/webhooks/0/failurePolicy","value":"Fail"}]'
```

**8.4 — SharedResourceWarning state (LOG-ONLY per R4-W3)**
```
kubectl -n argocd get application cert-manager-config -o jsonpath='{range .status.conditions[*]}{.type}{"\n"}{end}' | grep -c SharedResourceWarning
```
R4-W3: 4 SharedResourceWarning entries pre-existed because both `cert-manager`
controller App and `cert-manager-config` declare the 3 ClusterIssuers + 1
PreSync Job in their resource trees. The shared-ownership is a separate
structural defect that this incident does NOT resolve. Phase 8.4 is therefore
informational, not a gate — note the count and fold any change into the
Phase 11 follow-up issue. The structural fix (remove ClusterIssuers from one
of the two Apps' source tree) is deferred.

### Phase 9 — Verify piraeus-operator recovery + ACME survival

**9.1 — ACME account-key Secret recreation + ClusterIssuer Ready (R4-B1 fix)**

R4-B1: the v3 wording "survival" was wrong — NS Terminating already pruned
all Secrets ~17h ago. Post-Phase-7b the config App + cert-manager
controllers recreate the ACME account state from scratch:
```
# Both ACME account-key Secrets exist (cert-manager creates them on
# ClusterIssuer Ready)
kubectl -n cert-manager get secret homelab-account-key homelab-staging-account-key 2>&1 | grep -c NotFound
# Expect: 0 (both Secrets present within 60s of ClusterIssuer Ready)

# ClusterIssuer ACME registration succeeded
kubectl get clusterissuer homelab homelab-staging \
  -o jsonpath='{range .items[*]}{.metadata.name}:{.status.conditions[?(@.type=="Ready")].reason}{"\n"}{end}'
# Expect: ACMEAccountRegistered on both
```
Re-issuance from a fresh ACME account is cost-neutral: Let's Encrypt rate
limit is 10 accounts per IP per 3h, single homelab cluster makes 2.

**9.2 — piraeus-operator no longer hits webhook errors**
```
kubectl -n piraeus-datastore logs deployment/piraeus-operator-controller-manager --tail=200 \
  | grep -E '(failed calling webhook|cert-manager-webhook)' | tail -3
# Expect: empty in the last 2 min
```

**9.3 — LinstorSatellite/node-07 created**
```
kubectl -n piraeus-datastore get linstorsatellite node-07 \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}{"\n"}'
# Expect: Applied=True Configured=True within 2 min
```

**9.4 — linstor-satellite pod on node-07**
```
kubectl -n piraeus-datastore get pods -l app.kubernetes.io/component=linstor-satellite -o wide | grep node-07
# Expect: 2/2 Running
```

**9.5 — linstor-csi-node-smvlm out of Init**
```
kubectl -n piraeus-datastore get pod linstor-csi-node-smvlm
# Expect: 3/3 Running
```

**Rollback:** none — verify. If 9.2-9.5 not converged within 5 min:
`kubectl -n piraeus-datastore rollout restart deployment piraeus-operator-controller-manager`.

### Phase 10 — Resume vault-operator-config

```
kubectl -n argocd patch application vault-operator-config --type=merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
```
**Success:** auto-sync resumes; first sync applies `Role/RoleBinding
vault-pki-bootstrap-target` into the now-healthy cert-manager NS.

### Phase 11 — Follow-up + Bundle B (node-07)

**11.1 — Open follow-up GH issue**
Title: `bug: PreSync hook + namespace prune deadlock in C.2/C.3 rendered-manifest pattern (3 Apps affected)`
Labels: `bug`, `severity/high`, `status: triage`
Body: list `kube-prometheus-stack-config`, `kyverno-config`,
`vault-config-operator-config` as carrying the same
`BeforeHookCreation` defect-class. Link to plan-v4.md.

**11.2 — Bundle B: node-07 PR (R4-W1 fix: commit-first then rebase against `origin/main`)**

R4-W1: the v3 path (`checkout main`) would abort on uncommitted `M cluster.yaml`.
Commit on the current branch first, then rebase against `origin/main` directly
(no local `main` checkout needed at all):
```
# Currently on feat/onboard-node-07 with M cluster.yaml + ?? talos/nodes/node-07.yaml
git add cluster.yaml talos/nodes/node-07.yaml
git commit -m "$(cat <<'EOF'
feat(talos): onboard node-07 as standard worker

Hardware: Intel I219-V (e1000e), Toshiba NVMe + Samsung SATA 256 GB.
Installed on SATA (consistent with node-04/05/06). DRBD VLAN 110
host-octet = LAN host-octet - 60 (per talos-config.md scheme).

Joined cluster on 2026-05-14 ~09:51 UTC. cert-manager NS deadlock
during P7 verification surfaced an unrelated cluster incident; resolved
via Bundle A (fix/cert-manager-recovery-2026-05-13). After Bundle A
merged and cluster recovered, LinstorSatellite/node-07 registered
cleanly.

Refs: .work/incident-cert-manager-2026-05-13/plan-v4.md
EOF
)"
git fetch origin
git rebase origin/main   # picks up Bundle A merge directly from origin
git push -u origin feat/onboard-node-07
gh pr create --base main --head feat/onboard-node-07 --title "feat(talos): onboard node-07 as standard worker" --body "..."
```

## R4 execution gate

R4 is the hard cap per CLAUDE.md §Review Rigor. Submitted for final
adversarial pre-mortem. Expectation: zero new material CRITICAL/HIGH
findings → GO. If R4 produces ≥1 material new finding, escalate to user
for explicit risk-accept-and-execute decision.

---

## Post-execution outcome (added 2026-05-15)

The plan above was executed but the recovery surfaced **five additional
defects** not modelled in v4. Final defect-tally is **10**, not the
4-5 enumerated in Phases 0-11 above. This section documents the
delta — read it INSTEAD OF the plan when reasoning about the actual
recovery sequence.

### Final defect cascade (10 defects)

| # | Defect | Discovered in | Remediation | Reference |
|---|---|---|---|---|
| 1 | ESO `external-secrets.io/v1beta1` unserved (cert-manager-config sync wedged) | Phase 0.4 (pre-recovery probe) | Update CRDs to `v1` in `external-secret-google-cloud-dns.yaml` + `secret-store.yaml` | PR #13 |
| 2 | PreSync hook `hook-delete-policy: HookSucceeded,BeforeHookCreation` race with NS prune | Phase 5.3 (pre-recovery commit) | Drop `BeforeHookCreation` → `HookSucceeded,HookFailed` in `cert-manager/resources/presync-hook-job.yaml` | PR #13 |
| 3 | `argocd.argoproj.io/hook-finalizer` on dead Job blocked NS Termination | Phase 6 (during recovery) | Ad-hoc `kubectl patch job ... '[{"op":"remove","path":"/metadata/finalizers"}]'` | ad-hoc (Phase 6 in plan) |
| 4 | ArgoCD `.operation` field locks revision; `refresh=hard` does not terminate in-flight op | Phase 7b (during recovery, AFTER plan executed) | Ad-hoc `kubectl patch app ... '[{"op":"remove","path":"/operation"}]'` then `refresh=hard` | ad-hoc + issue #25 |
| 5 | Kyverno `pni-reserved-labels-audit` trust-signature gap denies cert-manager Pod admission | Phase 7a (mid-recovery — NS recreated, pods denied) | Strip `platform.io/capability-provider.*` labels from `cert-manager` + `cert-manager-webhook` rendered Deployments via Kustomize JSON patches in `_rendered-overlay/kustomization.yaml` | PR #15 |
| 6 | PreSync hook SA/RBAC in Sync-phase (chicken-and-egg with hook Job referencing SA) | Phase 7b (Job stuck `0/1`, SA missing) | Ad-hoc `kubectl apply -f resources/presync-hook-{sa,role}.yaml`. Permanent fix tracked. | ad-hoc + issue #22 |
| 7 | `bitnami/kubectl:1.31` removed from Docker Hub (Bitnami Aug 2025 catalog purge) | Phase 7b (PreSync hook Pod `ImagePullBackOff`) | Migrate all 4 PreSync hook Jobs to `bitnamilegacy/kubectl:1.31` | PR #16 |
| 8 | Kyverno `pni-reserved-labels-audit` (same as #5) denies external-secrets Pod admission | Phase 7b (after #1-#7 fixed, ESO webhook unreachable) | Strip `platform.io/capability-provider.monitoring-scrape` from 3 ESO Deployments via `_rendered-overlay` patches | PR #17 |
| 9 | Kyverno `pni-reserved-labels-audit` (same as #5/#8) denies vault Pod admission. StatefulSet stuck `1/3`, Raft quorum lost | Phase 9 verification (vault-internal ClusterIssuer Not Ready) | Remove `platform.io/capability-provider.monitoring-scrape` from `vaultLabels` in Vault CR | PR #18 |
| 10 | Vendor `vault-operator/namespace.yaml` missing `consume.controlplane-egress` label → CCNP doesn't match vault-operator pod → kube-apiserver unreachable (212 restarts) | Phase 9 verification (vault-operator `Client.Timeout` on every reconcile) | Add 4 `consume.*` labels to vault NS via Kustomize patches | PR #20 |

### Defect classes (3 share a root cause)

- **#5, #8, #9 — Kyverno trust-signature allowlist gap**: A single `pni-reserved-labels-audit` ClusterPolicy enforced a 2-operator allowlist (RabbitMQ + Redis-Operator) but three additional cluster operators (cert-manager, external-secrets, vault) ship `capability-provider.*` labels. Pre-incident the policy used `allowExistingViolations=true`, grandfathering existing Pods. The NS-Terminating cascade forced Pod recreation, evaluating the policy fresh, exposing the gap cluster-wide. Permanent fix tracked in issue #21.

- **#6 — PreSync hook SA/RBAC ordering**: 4 sibling Apps (cert-manager, kube-prometheus-stack, kyverno, vault-config-operator) ship PreSync hook Jobs that reference a ServiceAccount declared in Sync-phase. Pre-incident the SAs were grandfathered; post-NS-recreate the SA didn't exist when the Job ran. Permanent fix tracked in issue #22.

- **#7 — Bitnami legacy catalog migration**: Frozen registry, no security patches, "may be removed anytime" per upstream deprecation. Long-term migration to maintained image tracked in issue #23.

### Mid-recovery emergent symptoms (no separate defects)

- **vault-config-operator-config sync stuck on PreSync Job after cluster recovery** — chicken-and-egg #6 hit a second time. Same ad-hoc fix.
- **3 dependent Certificates stuck `Issuing`** (argocd-server, vault-pki-canary, vault-pki-canary-atlas-svc): not defects, downstream of #9/#10 (vault-internal ClusterIssuer Not Ready until vault Raft recovered).
- **Pre-existing config bugs surfaced** (NOT recovery-caused): PKISecretEngineRole `cert-manager-internal.allowedDomains` missing `argocd.lan.homelab.ntbc.io` → argocd-server cert can't issue (issue #27). SecretStore `caProvider.type: ConfigMap` references missing CM (issue #28).

### Final PR sequence (chronological)

| PR | Title | Defects addressed |
|---|---|---|
| #13 | fix(cert-manager): unblock NS Terminating deadlock + ESO v1beta1->v1 | #1, #2 + plan v4 Phases 5/6 |
| #14 | (merge: harness restore — unrelated) | — |
| #15 | fix(cert-manager): strip platform.io/capability-provider labels from rendered Deployments | #5 |
| #16 | fix(presync-hooks): migrate kubectl image to bitnamilegacy after Bitnami deprecation | #7 (4 Apps) |
| #17 | fix(external-secrets): strip platform.io/capability-provider labels from rendered Deployments | #8 |
| #18 | fix(vault): remove platform.io/capability-provider label from vault CR | #9 |
| #19 | (merge: kube-agent-harness consume — unrelated) | — |
| #20 | fix(vault): add consumer capability labels to vault namespace | #10 |

Ad-hoc patches (not in any PR): #3 (Job finalizer strip), #4 (`/operation` patch), #6 (`kubectl apply -f` of SA+RBAC, twice).

### Follow-up issues created during post-mortem

Tracking via #21 (Kyverno trust-signature gap), #22 (PreSync SA annotations), #23 (bitnami long-term), #24 (talos-platform-base vault NS labels upstream), #25 (ArgoCD stale-revision doc), #26 (3 remaining `BeforeHookCreation` Jobs), #27 (PKI allowedDomains), #28 (SecretStore type), #29 (gitignore `.claude/settings.local.json`), #31 (skill review medium/low).

### What the plan got right vs got wrong

**Right:**
- Phases 0-7a executed cleanly with the predicted state transitions.
- The `BeforeHookCreation` race (Defect #2) was caught pre-execution via plan v2.
- Webhook `failurePolicy: Ignore` workaround (Phase 2) successfully unblocked cluster while NS was Terminating.
- R3 simplification of Phase 3 (drop 3a/3b, keep 3c only) was correct — ClusterIssuers were already terminating.

**Wrong:**
- **Phase 7b underestimated**: assumed sync would complete once Phase 7a finished. Actually surfaced defects #4, #5, #6, #7, #8 in sequence. Each required separate diagnose + fix + merge cycles.
- **Phase 9 + 10 conflated**: plan treated Vault recovery as "verify ACME survival + resume vault-operator-config". Actually Vault required #9 (capability-provider label strip) + #10 (NS consume labels) before ANY config could be reconciled.
- **No model for "Kyverno trust-signature gap" as a defect class**: plan treated this as a one-off for cert-manager. The cascade hit ESO and vault identically — should have been generalized after #5.
- **Resume contract missing**: the parent skill (`onboard-worker-node`) had no checkpoint, so the original node-07 onboarding lost its `talos/nodes/node-07.yaml` artifact when the cert-manager incident interrupted P7. Tracked in skill rewrite PR #32.

### Lessons for future incident plans

- **Multi-app symptoms hint at single-policy root cause**: when 3 apps fail with same symptom shape, the diagnosis must climb to the cluster-wide policy layer before fixing in each app. Cost in this incident: defects #5, #8, #9 were diagnosed sequentially (~30min each) when one cluster-wide search would have found them in 5min.
- **Pre-existing config bugs surface during recovery, not separately**: argocd-server cert + SecretStore type were inert until cert-issuance was triggered fresh. Recovery is the time to also enumerate dependent-on-vault resources.
- **ArgoCD `.operation` revision lock is real**: any rule that says "refresh=hard" without also "patch /operation" is incomplete. Documented in issue #25.
