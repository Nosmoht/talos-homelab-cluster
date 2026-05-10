# PR #2b — DRBD transport_tls Implementation Plan (v2)

**Closes:** AC #5 of GitHub issue #82.
**Depends on:** PR #2a (commit 2a20dc9) — DRBD VLAN 110 binding live.
**Source of truth for mechanism:** `docs/adr-storage-vlan-and-encryption.md` §Decision (commit d39da7a).
**Reviewed by:** `talos-sre` + `platform-reliability-reviewer` (2026-04-25). v2 integrates all blocking findings; remaining MEDIUM/LOW findings explicitly acknowledged.

> **Note on placeholders.** All node-IP references use shell variables or `<placeholder>` strings. Resolve at runtime against `cluster.yaml` — never hardcode IPs into the runbook.
>
> ```sh
> CP_IPS=$(yq '.nodes.control_plane[].ip' cluster.yaml)
> STORAGE_IPS=$(yq '.nodes[] | select(.role == "worker" or .role == "control_plane" or .role == "gpu_worker") | .ip' cluster.yaml)
> ```

## Goal

Encrypt all DRBD satellite-to-satellite replication traffic on VLAN 110 with kernel TLS (kTLS), driven by tlshd userspace running as a sidecar in each `linstor-satellite` pod. Two control points:

1. `LinstorSatelliteConfiguration.spec.internalTLS.tlsHandshakeDaemon: true` — adds the `ktls-utils` sidecar.
2. `LinstorCluster.spec.properties[]: {name: DrbdOptions/Net/tls, value: "yes"}` — makes LINSTOR render `net { tls yes; }` into generated DRBD `.res` files.

## Pre-flight Gates (must pass before merge)

Each must be verified and the evidence pasted into the PR description.

### G1. Kernel TLS support on every node (Talos-aware)

`/proc/config.gz` is NOT exposed on Talos (kernel built without `CONFIG_IKCONFIG_PROC`). Probe the kernel-side surface tlshd actually uses:

```bash
# (a) Confirm tls ULP module loaded
for ip in $STORAGE_IPS; do
  printf '%-15s tls-module: ' "$ip"
  talosctl -n $ip -e $ip ls /sys/module/tls 2>/dev/null | head -1 | grep -q . && echo "loaded" || echo "MISSING"
done

# (b) Confirm /proc/net/tls_stat readable (kernel exposes TLS stats)
for ip in $STORAGE_IPS; do
  printf '%-15s tls_stat: ' "$ip"
  talosctl -n $ip -e $ip read /proc/net/tls_stat 2>/dev/null | head -1 >/dev/null && echo "readable" || echo "MISSING"
done

# (c) Confirm handshake netlink family available (tlshd dependency)
for ip in $STORAGE_IPS; do
  printf '%-15s handshake-genl: ' "$ip"
  talosctl -n $ip -e $ip dmesg 2>/dev/null | grep -ic 'handshake' >/dev/null 2>&1 && echo "kernel built with CONFIG_NET_HANDSHAKE" || echo "PROBE-INCONCLUSIVE — verify out-of-band"
done
```

Out-of-band: confirm Sidero's published kernel config for the pinned Talos version (`talos/versions.mk`) sets `CONFIG_TLS=y`, `CONFIG_TLS_DEVICE` (irrelevant for offload here, but builds in the netlink interface tlshd needs), and `CONFIG_NET_HANDSHAKE=y`. Link the source URL in the PR description.

### G2. DRBD ≥ 9.2.6 in satellite image

```bash
for sat in $(kubectl -n piraeus-datastore get pod -l app.kubernetes.io/component=linstor-satellite -o jsonpath='{.items[*].metadata.name}'); do
  printf '%-30s ' "$sat"
  kubectl -n piraeus-datastore exec --request-timeout=15s "$sat" -- head -1 /proc/drbd 2>/dev/null | tr -d '\n'; echo
done
```

Expected on every line: `version: 9.2.X` with X ≥ 6. If any node is below, abort — bump satellite image first.

### G3. All DRBD resources currently UpToDate

```bash
kubectl linstor resource list-volumes --all 2>&1 | awk '/UpToDate/ {ok++} /(Inconsistent|Outdated|StandAlone|Diskless)/ {bad++} END {print "ok=" ok " bad=" bad}'
```

Expected: zero `bad`. If any resource is degraded, fix via `/linstor-volume-repair` or wait for sync.

### G4. Cilium / network healthy + LINSTOR companion controllers ready

```bash
# Cilium: per cluster-health-snapshot SKILL note (commit e776427)
# Each node should show Stopped(24) Degraded(0) OK(N) — only Degraded != 0 matters

# LINSTOR companion controllers
kubectl -n piraeus-datastore get pod \
  -l 'app.kubernetes.io/component in (linstor-affinity-controller,ha-controller)' \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\trestarts="}{.status.containerStatuses[0].restartCount}{"\n"}{end}'
```

Expected: every line `Running\trestarts=0` (or low single-digit if cluster has been up >>1d). Any restart in last 1h is a yellow flag — investigate before proceeding.

### G5. etcd snapshot to persistent location (covers LINSTOR DB)

LINSTOR uses the k8s-backend (CRDs in etcd), so an etcd snapshot **does** cover LINSTOR controller state — no separate LINSTOR DB dump needed.

```bash
mkdir -p ~/backups/etcd
SNAP=~/backups/etcd/etcd-snapshot-pre-pr2b-$(date +%Y%m%d-%H%M%S).db
talos_etcd_snapshot --nodes <cp-node-ip> --output "$SNAP"
ls -la "$SNAP"
```

Expected: file exists, size > 1 MiB. `/tmp/` is **forbidden** as snapshot location — ephemeral, defeats rollback purpose.

### G6. Cert/Issuer alignment sanity (cert-rotation trap)

Per `linstor-storage-guardrails.md`:

```bash
kubectl -n piraeus-datastore get issuer linstor-internal-ca -o yaml | yq '.spec'
kubectl -n piraeus-datastore get certificate -o custom-columns='NAME:.metadata.name,ALGO:.spec.privateKey.algorithm,ISSUER:.spec.issuerRef.name'
kubectl -n piraeus-datastore get certificate linstor-internal-ca -o jsonpath='{.status.renewalTime}'
```

Verify: (1) Issuer algorithm matches issued certificate algorithms (no ECDSA-CA-with-RSA-leaf); (2) `renewalTime` is **not within ±24h of the planned maintenance window** — defer if it is.

### G7. Render-order dry-run (sidecar vs strip-patch collision)

The existing `LinstorSatelliteConfiguration` patch deletes `drbd-shutdown-guard` + `drbd-module-loader` initContainers. Adding `tlsHandshakeDaemon: true` injects `ktls-utils` into `containers[]`. Verify the operator's render produces a coherent Pod template **before** committing to main:

```bash
# Test on one node via temporary nodeSelector — NOT cluster-wide
NODE=node-04   # pick a worker, never a CP
kubectl apply -f - <<EOF
apiVersion: piraeus.io/v1
kind: LinstorSatelliteConfiguration
metadata:
  name: pr2b-canary
  namespace: piraeus-datastore
spec:
  nodeSelector:
    kubernetes.io/hostname: $NODE
  internalTLS:
    certManager:
      name: linstor-internal-ca
      kind: Issuer
    tlsHandshakeDaemon: true
EOF

# Wait for rolling restart of just that node's satellite
sleep 20
kubectl -n piraeus-datastore get pod \
  --field-selector spec.nodeName=$NODE \
  -l app.kubernetes.io/component=linstor-satellite \
  -o yaml > /tmp/canary-pod-rendered.yaml

# Verify rendered pod
yq '.items[0].spec.template.spec' /tmp/canary-pod-rendered.yaml || \
  yq '.spec' /tmp/canary-pod-rendered.yaml
```

Confirm: (a) `ktls-utils` container present in `containers[]`; (b) `drbd-shutdown-guard` + `drbd-module-loader` still absent from `initContainers[]` (strip patch survived); (c) `internal-tls` volume mounted into the sidecar at `/etc/tlshd.d`. If any check fails, fix the patch interaction before Phase A.

**Cleanup the canary**: `kubectl delete linstorsatelliteconfiguration pr2b-canary -n piraeus-datastore` and confirm the canary node's satellite returns to baseline before proceeding to Phase A.

## Implementation — Manifest Diff

### File 1: `kubernetes/overlays/homelab/infrastructure/piraeus-operator/resources/linstor-satellite-configuration.yaml`

```diff
   internalTLS:
     certManager:
       name: linstor-internal-ca
       kind: Issuer
+    tlsHandshakeDaemon: true
```

Single field addition. The operator reuses the existing `linstor-internal-ca` Issuer for the sidecar's mounted Secret — no new Issuer/Secret/cert-manager resource.

### File 2: `kubernetes/overlays/homelab/infrastructure/piraeus-operator/resources/linstor-cluster.yaml`

```diff
 spec:
   nodeSelector:
     feature.node.kubernetes.io/storage-nvme.present: "true"
   nfsServer:
     enabled: false
+  properties:
+    - name: DrbdOptions/Net/tls
+      value: "yes"
   apiTLS:
```

Adds the cluster-wide DRBD property routed through the operator (NOT via `linstor controller set-property` — see ADR §Important).

## Freeze List (must be in effect for entire window)

Mid-Phase-B compounding risk is unacceptable. Suspend or pause the following before starting Phase A; restore after Phase C smoke test passes:

1. **ArgoCD auto-sync** for these Apps:
   ```bash
   for app in piraeus-operator cilium cert-manager kube-prometheus-stack node-feature-discovery; do
     argocd app set $app --sync-policy none
   done
   ```
   Restore after window with `--sync-policy automated --auto-prune --self-heal`.
2. **Scheduled MCP check skills** — verify no firing inside window: `cilium-update-check`, `talos-update-check`, `nvidia-extension-check`, hourly `cluster-health-snapshot`, `etcd-automatic-defragmentation` (if scheduled). Pause via `crontab` or scheduler.
3. **NFD worker DaemonSet** — pause to prevent label drift evicting satellites mid-flip:
   ```bash
   kubectl -n node-feature-discovery scale daemonset/nfd-worker --replicas=0
   ```
   Restore: `--replicas=$(kubectl get nodes -l feature.node.kubernetes.io/storage-nvme.present=true -o name | wc -l)`.
4. **cert-manager renewal**: G6 already gates on `renewalTime` not within ±24h.
5. **MTU on VLAN 110**: confirm uniform across all storage nodes (if mixed, abort):
   ```bash
   for ip in $STORAGE_IPS; do
     printf '%-15s ' "$ip"
     talosctl -n $ip -e $ip get linkstatus 2>/dev/null | grep -E '\.110|vlan110' | awk '{print $4, "MTU:", $7}'
   done
   ```
   Note: kTLS adds ~21 B per record; standard MTU 1500 has headroom but document the value.
6. **No `drbd-reactor` deployed** in this cluster (confirmed) — no coordination needed.

## Apply Sequence

ArgoCD-managed resources. Per AGENTS.md §Hard Constraints: commit + push, let ArgoCD sync, never `kubectl apply` directly.

### Phase A — manifest application (5–10 min, partial-disruption tolerated)

1. Re-enable ArgoCD auto-sync for `piraeus-operator` only (other Apps stay paused per Freeze List).
2. Commit + push the two-file diff above on a branch; merge to `main` only after G1–G7 pass.
3. ArgoCD reconciles `piraeus-operator` Application. Operator sees the CR change.
4. Operator rolls the `linstor-satellite` DaemonSet — each pod restarts with `ktls-utils` sidecar attached.

   **Honest impact statement**: each satellite pod restart causes local DRBD resources to detach/reattach for 30–90s. With 2× replication (`linstor-csi`, `linstor-vm`) every resource has another replica online. **Single-replica `linstor-nvme-noreplica` PVCs** see I/O hangs of 30–90s — sufficient to:
   - trip default kubelet liveness probes (30s threshold)
   - OOM mmap-backed processes if backing store is unavailable >10s
   - cause Postgres WAL fsync timeouts; JVM heap allocator stalls
   - trigger restarts of consumers without a robust retry loop

   **Required pre-Phase-A action for noreplica PVCs**:
   ```bash
   kubectl get pvc -A -o json | jq -r '
     .items[]
     | select(.spec.storageClassName == "linstor-nvme-noreplica")
     | "\(.metadata.namespace)/\(.metadata.name)"'
   ```
   For each PVC listed: either (a) cordon + drain the host node, or (b) document explicit owner sign-off in the PR description before proceeding. **No silent acceptance.**

5. Watch the rollout:
   ```bash
   kubectl -n piraeus-datastore rollout status daemonset/linstor-satellite --timeout=10m
   ```
6. Verify sidecar present and ready on every satellite:
   ```bash
   kubectl -n piraeus-datastore get pod -l app.kubernetes.io/component=linstor-satellite \
     -o jsonpath='{range .items[*]}{.spec.nodeName}{"\t"}{.status.containerStatuses[?(@.name=="ktls-utils")].ready}{"\n"}{end}'
   ```
   Expected: every line `<node>\ttrue`. If any `false` or missing, STOP and triage before Phase B.

### Phase B — per-node TLS flip (~3 min × N nodes, sequential, workers first)

DRBD does NOT support online TLS reconfiguration. After the operator change, sidecars exist and DRBD has `net { tls yes; }` in generated `.res`, but *running* connections still hold pre-existing plaintext sockets. Each connection must be torn down and re-adjusted.

**Order — workers first, control planes last (etcd co-tenancy)**:
- Workers: `node-04` → `node-05` → `node-06` → `node-gpu-01`
- Control planes (non-leader first; check leader via `talos_etcd subcommand=members`): typically `node-03` → `node-02` → `node-01`
- Skip `node-pi-01` (no NVMe label, no satellite)

**Why not CP-first**: control planes host etcd (3-member quorum). DRBD I/O suspend that mis-fires can starve concurrent etcd snapshot/compaction. DRBD quorum and etcd quorum are independent — workers have no such co-tenancy.

**Per-CP additional pre-step** (skip for workers):
```bash
# Verify no etcd defrag/snapshot in flight
talosctl -n <cp-ip> -e <cp-ip> etcd status 2>&1 | tee /tmp/etcd-pre-$NODE.txt
# Abort flip if dbSizeInUse vs dbSize differ by >50% (compaction pending)
```

**Per-node flip sequence** — every command wrapped in 60s exec timeout to avoid silent hangs:

```bash
NODE=node-04   # change per iteration
SAT=$(kubectl -n piraeus-datastore get pod -l app.kubernetes.io/component=linstor-satellite \
  --field-selector spec.nodeName=$NODE -o jsonpath='{.items[0].metadata.name}')
EXEC="kubectl exec -n piraeus-datastore --request-timeout=60s $SAT --"

# Snapshot current state
$EXEC drbdsetup status all > /tmp/drbd-pre-$NODE.txt

# Flip
$EXEC drbdadm suspend-io all
$EXEC drbdadm disconnect --force all
$EXEC drbdadm adjust all

# Wait for reconnect and verify TLS active
sleep 5
$EXEC cat /proc/net/tls_stat
# Expected: nonzero TlsRxSw and TlsTxSw counters (software TLS — no NIC offload on our hardware)

# Pairwise TLS check — every connection record must show tls:yes
$EXEC drbdsetup events2 --now all | grep -E '^exists connection' | grep -v 'tls:yes' && \
  { echo "FAIL: connection without tls:yes — abort and rollback"; exit 1; }

# Verify handshake log
kubectl -n piraeus-datastore logs --tail=20 -c ktls-utils $SAT | grep -i 'Handshake.*successful'
# Expected: at least one "Handshake with <peer> was successful" line per peer

# Verify DRBD reconverged UpToDate
$EXEC drbdsetup status all | grep -E 'connection:|disk:'
# Expected: all connection: Connected, all disk: UpToDate

# Cleartext-leak probe — capture 50 packets on the satellite host network and grep for plaintext DRBD magic
talosctl -n <node-ip> -e <node-ip> pcap -i vlan110 -d 30s --filter "tcp portrange 7000-7999" 2>/dev/null | \
  od -An -tx1 -N 8192 | grep -i '83 74 02 67' && \
  { echo "FAIL: plaintext DRBD magic on the wire — abort and rollback"; exit 1; }
```

**Strict serialisation rule**: never start the next node's flip until the previous node's resources are all `Connected` + `UpToDate`. Parallelism across replicas of the same resource = quorum loss.

#### If a flip stalls

DRBD `suspend-io` issued + handshake stuck = kernel D-state. `kubectl exec` cannot kill in-kernel I/O wait. Satellite pod restart will NOT free it; node will NOT drain; `talos_reboot` will hang at unmount.

1. **Try `resume-io` ONLY if the exec process is responsive** (returns within 30s):
   ```bash
   $EXEC drbdadm resume-io all   # 60s timeout already wrapped
   ```
2. **If exec hangs or returns immediately with no effect**: STOP. Do NOT issue further drbdadm commands — they queue and worsen state.
3. Capture diagnostics for the postmortem:
   ```bash
   talosctl -n <node-ip> dmesg | grep -iE 'drbd|tls|handshake' > /tmp/drbd-stall-$NODE.dmesg
   talosctl -n <node-ip> get processes | awk '$5=="D"' > /tmp/drbd-stall-$NODE.dprocs
   ```
4. Escalate to maintenance-window power cycle per `talos-mcp-first.md` §Node Recovery + `runbook-cold-cluster-cutover.md` shutdown-umount escape hatch.

#### Forbidden shortcuts during incident

The following will look tempting under pressure. **Each is forbidden** with reason from `linstor-storage-guardrails.md`:

- ❌ `kubectl delete pod <satellite>` — DRBD D-state risk; pod restart will not unstick kernel waits.
- ❌ `kubectl rollout restart deploy linstor-controller` — explicitly forbidden by guardrails §Safety Constraints; can trigger cert rotation breaking ALL satellite SSL trust.
- ❌ `drbdadm down + up` to "reset" a confused resource — risks split-brain; never run on a resource still listed by LINSTOR.
- ❌ `drbdadm primary --force` to "make a node usable again" — guarantees split-brain.
- ❌ `mkfs` on any DRBD device — destroys all replica data permanently.

**Only `drbdadm resume-io all` and `drbdadm reconnect all` are permitted as recovery within Phase B.** Anything else → abort and trigger Rollback.

### Phase C — final verification (5 min)

```bash
# Cluster-wide TLS active on every node
for ip in $STORAGE_IPS; do
  printf '%-15s ' "$ip"
  talosctl -n $ip -e $ip read /proc/net/tls_stat 2>/dev/null | grep -E 'TlsTxSw|TlsRxSw' || echo "NO TLS"
done

# DRBD globally healthy
kubectl linstor resource list-volumes --all | awk '!/UpToDate/ {bad++} END {print "non-UpToDate=" (bad+0)}'
# Expected: non-UpToDate=1 (the awk header line)

# Pairwise TLS — sweep ALL nodes, ALL connections
for SAT in $(kubectl -n piraeus-datastore get pod -l app.kubernetes.io/component=linstor-satellite -o jsonpath='{.items[*].metadata.name}'); do
  printf '%-30s ' "$SAT"
  bad=$(kubectl exec -n piraeus-datastore --request-timeout=30s $SAT -- drbdsetup events2 --now all 2>/dev/null | \
    grep -E '^exists connection' | grep -cv 'tls:yes')
  [ "$bad" = "0" ] && echo "all-tls" || echo "FAIL: $bad connections without tls:yes"
done

# Sample resource shows TLS in .res (pick any storage node)
SAT=$(kubectl -n piraeus-datastore get pod -l app.kubernetes.io/component=linstor-satellite -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n piraeus-datastore --request-timeout=30s $SAT -- sh -c 'cat /var/lib/linstor.d/*.res | grep -i tls | head -3'
# Expected: line containing "tls yes;"

# Smoke test — round-trip writeable bytes on a fresh 2-replica PVC
kubectl create ns pr2b-smoke
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: smoke
  namespace: pr2b-smoke
spec:
  storageClassName: linstor-csi
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: smoke
  namespace: pr2b-smoke
spec:
  restartPolicy: Never
  containers:
    - name: smoke
      image: mirror.gcr.io/library/busybox:1.37
      command: [sh, -c, 'echo "pr2b-tls-smoke-$(date +%s)" > /data/sentinel && cat /data/sentinel && sleep 30']
      volumeMounts: [{name: data, mountPath: /data}]
  volumes:
    - {name: data, persistentVolumeClaim: {claimName: smoke}}
EOF
kubectl -n pr2b-smoke wait pod/smoke --for=condition=Ready --timeout=60s
kubectl -n pr2b-smoke logs smoke
# Expected: line "pr2b-tls-smoke-<timestamp>"
kubectl delete ns pr2b-smoke
```

## Rollback Plan

Symmetric reverse of forward path — but with the same gate prerequisites as forward, NOT just "ship it backwards".

### R1. Disable LINSTOR property (immediate effect on new connections only)

Revert the `linstor-cluster.yaml` change via git revert + push. ArgoCD reconciles. LINSTOR stops emitting `net { tls yes; }` for newly generated `.res` files. **Existing connections remain TLS until step R2.**

### R1.5. Re-verify G3 + G4 before R2

DRBD must be healthy before forcing every connection through another disconnect/adjust cycle. If R1 itself caused any resource to go non-UpToDate, fix THAT first (`/linstor-volume-repair`).

### R2. Per-node revert flip (mirror of Phase B)

For each node, **reverse order** of forward sequence (CPs first now to clear the most-coupled state, then workers):
```bash
$EXEC drbdadm suspend-io all
$EXEC drbdadm disconnect --force all
$EXEC drbdadm adjust all
```
Same strict serialisation rule. Same forbidden-shortcuts list applies. After this completes, connections are plaintext again.

### R2.5. Verify each `.res` no longer contains `tls yes;`

```bash
for SAT in $(kubectl -n piraeus-datastore get pod -l app.kubernetes.io/component=linstor-satellite -o jsonpath='{.items[*].metadata.name}'); do
  printf '%-30s ' "$SAT"
  hits=$(kubectl exec -n piraeus-datastore --request-timeout=30s $SAT -- sh -c 'grep -lc "tls yes" /var/lib/linstor.d/*.res 2>/dev/null | wc -l')
  echo "stale-tls-res-files=$hits"
done
# Expected: 0 on every line. Non-zero = operator reconcile lagged or flip-revert missed a resource — fix before declaring revert complete.
```

### R3. Remove sidecar (optional cleanup)

Revert the `linstor-satellite-configuration.yaml` change. Operator rolls satellites; sidecar removed. Plaintext-only state restored, identical to pre-PR-#2b. **Note**: this is a SECOND restart cycle for every node — schedule with the same maintenance-window discipline as Phase A.

### R4. etcd nuclear option

Recourse if R1/R2 leave LINSTOR property state inconsistent and partial revert refuses to settle. Restore from G5 snapshot:

```bash
talos_etcd_snapshot --restore-from $SNAP --nodes <cp-node-ip>
```

This restores ALL k8s API state to the pre-PR-#2b snapshot, including LINSTOR CRDs. Out-of-band procedure — see `etcd-snapshot-restore` skill. Coordinate with workload owners; expect cluster-wide rollback of any change committed during the window.

### Time budget per phase
- R1: 5 min (git revert + push + ArgoCD reconcile)
- R1.5: 5 min
- R2: 20–25 min (same as forward Phase B)
- R2.5: 5 min
- R3 (optional): 10 min
- R4 (nuclear): 60+ min, requires planning

## Acceptance Criteria

- [ ] All G1–G7 pre-flight gates pass; evidence in PR description (per-gate output, not summary).
- [ ] Manifest diff matches §Implementation exactly (no additional fields).
- [ ] `make validate-kyverno-policies` passes.
- [ ] `kubectl kustomize kubernetes/overlays/homelab/infrastructure/piraeus-operator/` renders cleanly.
- [ ] G7 canary verifies sidecar coexists with strip-patch on a single node before cluster-wide change.
- [ ] Freeze List in §Freeze List in effect before Phase A; restored after Phase C.
- [ ] Phase A rollout: `ktls-utils` sidecar Ready=true on every satellite pod.
- [ ] Pre-Phase-A noreplica PVC inventory documented; cordon-or-signoff per item.
- [ ] Phase B: per-node TLS flip executed sequentially in workers-first order; every node verified `Connected`/`UpToDate` before next.
- [ ] Phase B: pairwise TLS check (`drbdsetup events2 --now`) returns zero non-tls:yes connections per node.
- [ ] Phase B: cleartext-leak probe (pcap on VLAN 110) returns zero plaintext DRBD magic matches per node.
- [ ] Phase C: cluster-wide pairwise sweep returns `all-tls` for every satellite.
- [ ] Phase C: smoke test PVC round-trips writable bytes (`pr2b-tls-smoke-<ts>` in pod logs).
- [ ] No new `Degraded` Cilium modules; `kubectl linstor node list` 100% ONLINE.

## Risks & Caveats

1. **Cert-rotation trap** (`linstor-storage-guardrails.md`) — G6 + Freeze List item 4 mitigate.

2. **Single-replica `linstor-nvme-noreplica` workloads stall 30–90s** during their host's satellite restart. Mitigation: pre-Phase-A inventory + cordon-or-signoff per PVC. Do NOT downgrade the impact statement.

3. **NIC TLS offload not supported** on Intel I219 / RTL r8152 — software TLS only. Adds CPU cost. At 1 GbE line rate per VLAN this is a few % CPU per node; not measurable as throughput impact.

4. **No upstream documentation of recovery semantics** if a satellite pod is restarted mid-Phase-B flip. Mitigation: G4 + G6 + Freeze List; serialised Phase B; do not begin Phase B during a planned satellite restart, ArgoCD sync of unrelated piraeus changes, or cert renewal window.

5. **DRBD D-state during flip → physical power cycle.** Schedule a maintenance window where physical access is available. The `If a flip stalls` subsection is honest about this boundary.

6. **HA controller may interpret transient `connection:Connecting` as quorum loss** and add `drbd.linbit.com/lost-quorum:NoSchedule` taints. Should clear automatically on reconnect (~10s). If they persist, follow `linstor-storage-guardrails.md` "DRBD resource zombie on removed node" recipe — `drbdsetup down <resource>`, NOT pod delete.

7. **Observability gap (acknowledged)**: kube-prometheus-stack does NOT scrape `/proc/net/tls_stat` and tlshd has no metrics endpoint. Verification is **point-in-time CLI only** during Phase B/C. **Follow-up task**: add node-exporter `--collector.textfile` shim that exposes `node_netstat_TlsRxSw` / `TlsTxSw` from `/proc/net/tls_stat`, and `PrometheusRule` alerting on DRBD `connection!=Connected` (verify piraeus-exporter scrape config first). File as separate issue once PR #2b lands.

8. **Render-order collision G7** — gated by canary; if G7 fails, the operator render needs investigation before any cluster-wide apply.

## Maintenance Window

Conservative estimate, pessimistic bounds:
- Pre-flight gates G1–G7 (G7 includes canary): 30–45 min
- Freeze List activation: 5 min
- Phase A (operator rollout): 5–10 min
- Phase B (7 nodes × 3 min serial + verify): 25–35 min
- Phase C + smoke test: 10 min
- Freeze List restoration: 5 min
- Buffer for surprises (D-state recovery, canary failure, …): 60 min
- **Total: ~2.5–3 h window with physical access standby**

Schedule outside business-critical hours; no concurrent Talos / Cilium / piraeus upgrades; cert renewal not within ±24h.

## Out of Scope for This PR

- DRBD `c-max-rate` review (already applied in PR #2a).
- VLAN 110 ACL hardening on SG3428 (separate change ticket).
- node-exporter textfile shim for kTLS metrics (Risk #7 follow-up — file separately).
- LINSTOR storage pool encryption-at-rest (different threat model, separate ADR).

## Reviewer Sign-Off

- **talos-sre** (2026-04-25): 5 findings integrated (G1 probe rewrite, G7 canary, Phase B order flip, D-state honesty, MTU/NFD/etcd-snapshot-path).
- **platform-reliability-reviewer** (2026-04-25): 6 of 7 findings integrated (impact-honesty, Freeze List, pairwise + tcpdump, rollback gates, forbidden shortcuts, G5 LINSTOR clarification). Risk #7 (Prometheus observability) acknowledged as follow-up.
- **Verdict carried forward**: CONDITIONAL GO — execute only after G1–G7 pass on a real maintenance window with physical access standby.
