# Phase 1 Implementation Log: Enterprise Network Architecture Blueprint

**Date:** 2026-03-30
**Blueprint:** `docs/enterprise-network-architecture-blueprint.md`, Section 15 Phase 1
**Plan:** `Plans/spicy-hugging-barto.md`
**Reviewed by:** platform-reliability-reviewer, talos-sre, gitops-operator

## Summary

Phase 1 ("Quick Wins — Software-Only Changes") of the Enterprise Network Architecture Blueprint has been implemented. Three changes deployed across all 8 cluster nodes:

1. **Hubble Dynamic Flow Export** — DROPPED verdict and DNS query flows persisted to filesystem
2. **WireGuard Strict Mode Encryption** — all inter-node pod traffic encrypted
3. **Kyverno PNI Policy Enforcement** — namespace contract validation enforced at admission

## Commits

| Commit | Description |
|--------|-------------|
| `5fc2399` | feat(cilium): enable Hubble dynamic flow export for dropped + DNS flows |
| `f0de11a` | fix(cilium): correct Hubble flowlog includeFilters proto format |
| `590e9ff` | feat(cilium): enable WireGuard best-effort encryption |
| `7243acd` | feat(cilium): enable WireGuard strict mode encryption |
| `0d764db` | fix(cilium): set explicit PodCIDR for WireGuard strict mode |
| `c0d0ff5` | feat(pni): switch Kyverno PNI policies to enforce mode, add missing namespace labels |

## Step 1: Hubble Dynamic Flow Export

**Config:** `kubernetes/bootstrap/cilium/values.yaml` — `hubble.export.dynamic`

Two export targets configured:
- `/var/run/cilium/hubble/dropped.log` — policy DROPPED verdicts with source/dest/reason
- `/var/run/cilium/hubble/dns.log` — DNS protocol flows with L7 details

**Issues encountered:**
1. `talosctl upgrade-k8s` did not create the new `cilium-flowlog-config` ConfigMap or update the `cilium-config` ConfigMap with `hubble-flowlogs-config-path`. Required manual `kubectl apply --server-side --force-conflicts --field-manager=talos` for both.
2. `hubble-generate-certs` Job with hash-based name conflicts on `upgrade-k8s` re-runs — must delete before each run.
3. Initial `includeFilters` format used `fields: [{name: verdict, values: [DROPPED]}]` (from blueprint). Cilium agent rejected with `unknown field "fields"`. Correct proto format: `verdict: [DROPPED]`, `protocol: [DNS]`.

**Verification:** Both log files actively receiving flows on all 8 nodes. DNS flows show coredns queries; dropped flows show policy denials with drop_reason codes.

## Step 2: WireGuard Encryption (Two-Pass)

**Config:** `kubernetes/bootstrap/cilium/values.yaml` — `encryption`

Deployed in two passes per SRE recommendation:
- **Pass 1 (best-effort):** `strictMode.enabled: false` — WireGuard tunnels established without dropping unencrypted traffic
- **Pass 2 (strict):** `strictMode.enabled: true` — unencrypted inter-node pod traffic dropped

**Issues encountered:**
1. Same `upgrade-k8s` ConfigMap issue — `enable-encryption: wireguard` and strict mode keys not applied to live ConfigMap. Required manual server-side apply.
2. `strictMode.cidr: ""` (empty string, omitted from Helm values but Helm rendered as empty) caused cilium-agent fatal crash: `Cannot parse CIDR from --encryption-strict-egress-cidr option: no '/'`. Fixed by setting explicit `cidr: "10.244.0.0/16"`.
3. `cilium-dbg encrypt status` does not display "Strict Mode: true/false" in Cilium 1.19.2. Verification via `cilium-dbg config -a | grep EnableEncryptionStrictModeEgress`.

**Design decisions from reviewer feedback:**
- `allowRemoteNodeIdentities: true` — required because `linstor-csi-node` runs with hostNetwork; `false` would break DRBD replication
- No `cidr` field auto-detect — Helm renders empty string which crashes agent; explicit PodCIDR required
- Two-pass avoids rolling-restart blackhole where restarted nodes (WireGuard ON) cannot communicate with not-yet-restarted nodes (WireGuard OFF)

**Verification:** All 8 nodes show `Encryption: Wireguard` with 7 peers each (full mesh). `EnableEncryptionStrictModeEgress: true` on all nodes. DRBD zero faulty resources.

## Step 3: Kyverno PNI Policy Enforcement

**Files:** `kubernetes/base/infrastructure/platform-network-interface/resources/kyverno-clusterpolicy-pni-*-enforce.yaml`

Three ClusterPolicies transitioned from `Audit` to `Enforce`:
- `pni-contract-audit` — requires `platform.io/network-interface-version=v1` + `platform.io/network-profile` on namespaces
- `pni-reserved-labels-audit` — blocks provider-reserved labels on consumer resources
- `pni-capability-validation-audit` — validates `consume.*` labels against 13-capability catalog

**Pre-flight findings:**
- 4 namespaces lacked PNI labels: `cilium-secrets`, `kagent`, `nvidia-device-plugin`, `redis-operator`
- All were operator-created namespaces not in `namespaces-psa.yaml`
- Added all 4 to `namespaces-psa.yaml` with appropriate PNI labels and PSA levels
- Added `kube-system` and `default` to policy exclusion list (defense-in-depth)

**Safety mechanisms retained:**
- `allowExistingViolations: true` — existing non-compliant resources exempt from admission enforcement on UPDATE
- `.metadata.name` unchanged (ArgoCD tracks by GVK+namespace+name, not filename)
- `Makefile` target `validate-kyverno-policies` updated with new filenames

**Verification:**
- `kubectl create namespace test-enforce-check --dry-run=server` → DENIED by Kyverno
- Namespace with PNI labels → allowed (server dry-run)
- ArgoCD `platform-network-interface` app: Synced + Healthy

## Gotchas Added to CLAUDE.md

- `upgrade-k8s` does NOT reliably update ConfigMaps or create new resources
- `hubble-generate-certs` Job blocks upgrade-k8s (immutable field)
- WireGuard strict mode `cidr: ""` fatal crash
- WireGuard `allowRemoteNodeIdentities: true` required for hostNetwork pods
- WireGuard does not encrypt macvlan traffic
- WireGuard two-pass deployment pattern
- Hubble `includeFilters` proto format (not `fields` wrapper)
- Hubble dynamic export config is hot-reloadable

## Next Steps (Phase 2+)

Per blueprint Section 15:
- **Phase 2:** VLAN separation (storage VLAN 20, management VLAN 10) — requires switch 802.1q configuration
- **Phase 3:** Tetragon runtime security, DNS-aware egress filtering
- **Phase 4:** Auto-generate default-deny CiliumNetworkPolicy on namespace labeling
- **Follow-up for Phase 1:** Fluentbit log shipping pipeline (dropped.log/dns.log → MinIO with Object Lock for compliance retention)
