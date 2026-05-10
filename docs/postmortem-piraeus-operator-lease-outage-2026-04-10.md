# Postmortem: piraeus-operator Lease Outage (2026-04-10 to 2026-04-11)

**Duration:** ~31 hours (2026-04-10T07:13 UTC to 2026-04-11T14:55 UTC)  
**Severity:** High — storage controller unreconciled; linstor-controller crash mitigation blocked  
**Status:** Resolved

---

## Summary

The piraeus-operator controller-manager lost its Kubernetes leader-election lease and was unable to renew it for 31 hours. During this window, the piraeus-operator could not reconcile `LinstorCluster` resources, meaning a planned linstor-controller crash mitigation (anti-affinity away from a degraded CP node) was committed to git but never applied to the cluster.

The immediate trigger was a node-03 NIC hardware issue (rxFrame errors, suspected duplex mismatch) that caused VIP instability and API server connectivity loss for pods on node-03. The 31h window was caused by a separate, pre-existing CNP misconfiguration that prevented the operator from ever recovering on any node.

---

## Timeline

| Time (UTC) | Event |
|---|---|
| 2026-04-10T07:13 | piraeus-operator lease last renewed — operator begins failing to reach `10.96.0.1:443` |
| (prior) | Commit `43b624c` shipped `cnp-piraeus-operator.yaml` with egress to linstor-controller only — no kube-apiserver egress |
| 2026-04-10 (ongoing) | node-03 NIC rxFrame errors accumulate (~2M), causing periodic VIP loss and API server instability |
| 2026-04-11 (session) | linstor-controller crash noted; investigation begins |
| 2026-04-11T~13:30 | `LinstorCluster` anti-affinity + lease duration mitigations committed and pushed (`33f9b83`) |
| 2026-04-11T~14:00 | ArgoCD sync succeeds but linstor-controller Deployment not updated — operator still not reconciling |
| 2026-04-11T~14:20 | CNP investigated; `cnp-piraeus-operator.yaml` identified as root cause — no kube-apiserver egress |
| 2026-04-11T~14:30 | Ad-hoc kube-apiserver egress added to CNP (wrong approach — PNI not considered) |
| 2026-04-11T~14:35 | ArgoCD syncs CNP fix; operator still failing — `Egress allowed: {}` on Cilium endpoint |
| 2026-04-11T~14:45 | PNI reviewed; `pni-controlplane-egress-consumer-egress` CCNP identified as correct mechanism |
| 2026-04-11T~14:50 | Ad-hoc CNP egress reverted; `podLabels.platform.io/capability-consumer.controlplane-egress: "true"` added via Helm values (`daf220e`) |
| 2026-04-11T14:55 | piraeus-operator lease renewed — outage ends |
| 2026-04-11T~15:00 | linstor-controller Deployment updated (anti-affinity + lease timers applied) |
| 2026-04-11T~15:05 | linstor-controller pod rescheduled from node-03 → node-02 |

---

## Root Causes

### RC-1: Missing kube-apiserver egress in `cnp-piraeus-operator.yaml`

Commit `43b624c` introduced least-privilege CNPs for all piraeus-datastore components. The piraeus-operator CNP was given egress only to `linstor-controller:3371/3370`. The operator's fundamental need for kube-apiserver access (leader election, resource watch, reconcile) was not included.

**Why it wasn't caught:** The CNP was added in a batch; no runtime validation was performed after deployment. The operator had already been running (lease pre-acquired), so the missing egress was only visible when the pod restarted.

### RC-2: PNI CCNP not consulted before CNP authoring

The namespace `piraeus-datastore` had `platform.io/consume.controlplane-egress: "true"` set, and the CCNP `pni-controlplane-egress-consumer-egress` already provided kube-apiserver + DNS egress for pods with the matching pod-level label. Neither the CNP author nor the incident responder checked PNI coverage before authoring egress rules.

The pod-level label `platform.io/capability-consumer.controlplane-egress: "true"` was absent from the piraeus-operator deployment — so the CCNP never matched. This two-condition requirement (namespace label AND pod label) was not documented prominently.

### RC-3: node-03 NIC hardware degradation

The node-03 NIC accumulates rxFrame errors (suspected duplex mismatch with the SG3428 switch port). This caused:
- Periodic VIP loss on node-03
- API server connectivity loss for pods consistently hashed to node-03's backend (Cilium Maglev)
- linstor-controller crash when it held the DRBD leader election from node-03

This was the **trigger** but not the root cause of the 31h outage — the CNP and PNI issues would have persisted regardless.

---

## Contributing Factors

- **No alert for lease expiry**: No `PrometheusRule` existed for operator lease staleness. The 31h window was not detected by monitoring.
- **No alert for NIC error rate**: No alert on `node_network_receive_frame_total` — the node-03 rxFrame accumulation was only discovered during manual investigation.
- **linstor-controller not constrained to CP nodes**: The controller was free to schedule on any node, including degraded workers. No Layer 0 placement policy enforced.
- **Cilium Stopped(25) modules on node-03**: Abnormal Cilium health state on node-03 was present but undetected due to no alert.

---

## What Went Well

- ArgoCD sync status gave clear signal once the CNP was corrected
- Hubble `Egress allowed: {}` on the Cilium endpoint was a definitive indicator of policy failure
- The CCNP endpointSelector was readable and the fix was clean once PNI was consulted
- All changes were committed and pushed before verification — no direct-apply drift

---

## What Went Wrong

- PNI was not consulted before writing the original CNP or during incident response
- An ad-hoc CNP fix was committed before the correct mechanism (PNI pod label) was identified
- No validation that new CNPs allow required traffic paths before shipping
- Two incorrect commits pushed to main before the correct fix (`020a639` then `daf220e`)

---

## Action Items

| # | Action | Issue | Owner |
|---|---|---|---|
| 1 | Fix node-03 NIC: investigate rxFrame errors, force duplex on SG3428 | #74 | — |
| 2 | Investigate Cilium Stopped(25) modules on node-03 | #75 | — |
| 3 | Enforce Layer 0 components on CP nodes only (hard affinity) | #76 | — |
| 4 | Add storage/operator/NIC alerting PrometheusRules | #77 | — |
| 5 | Add PNI pod-label compliance validation script or Kyverno policy | #78 | — |
| 6 | Manifest PNI-first check in CNP authoring rules (`.claude/rules/cilium-network-policy.md`) | done | — |

---

## Lessons Learned

### PNI is the central network policy system — always check first

Before adding any egress rule to a CNP, verify:
1. Does the namespace have `platform.io/network-interface-version: v1`?
2. Does a CCNP exist for the needed capability?
3. Does the pod have the required `platform.io/capability-consumer.<capability>: "true"` pod-level label?

If 1+2 are true but 3 is missing: add the pod label (via Helm `podLabels`). Do not copy CCNP rules into the CNP.

### CNPs require runtime validation after shipping

A CNP that passes `--dry-run=server` can still silently block all traffic if it omits required egress. After shipping any CNP change, verify reachability for the affected component (operator logs, lease timestamps) before closing the change.

### Layer 0 components need placement guardrails

Storage controllers and operators are not general-purpose workloads. They should be constrained to CP nodes via hard affinity, not left to the default scheduler. Worker nodes are drained more freely and are less stable.

### Missing alerts amplify blast radius

A 31h outage went undetected because no alert existed for lease staleness. Operator health (lease renewTime) and node NIC error rates are now identified gaps.
