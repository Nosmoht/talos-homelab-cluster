---
paths:
  - "kubernetes/**/piraeus-operator/**"
  - "kubernetes/base/**/piraeus-operator/**"
  - "docs/day2-operations.md"
---

# LINSTOR / DRBD Storage Guardrails

## Architecture

```
Piraeus Operator (Helm, piraeus-datastore namespace)
  └── LINSTOR Controller (stateful, API server)
       └── LINSTOR Satellites (DaemonSet, one per storage node)
            └── DRBD kernel module (loaded natively by Talos)
                 └── LVM volume group "linstor" on /dev/nvme0n1
```

- Satellites run as privileged pods with host `/dev` access
- LINSTOR CLI: `kubectl linstor` plugin or `kubectl exec` into controller pod
- CSI driver promotes DRBD to Primary before mount, demotes after unmount
- Storage nodes: nodes with `feature.node.kubernetes.io/storage-nvme.present=true`

## StorageClasses

| Class | Replicas | FS | Use for |
|-------|----------|----|---------|
| `linstor-csi` (default) | 2 | XFS | General workloads |
| `linstor-nvme-noreplica` | 1 | XFS | Non-critical, single-replica |
| `linstor-vm` | 2 | raw block | KubeVirt VMs |

## Known Failure Modes

**XFS superblock corruption** (most common): Unclean DRBD demotion (node crash, power loss) corrupts XFS metadata. Symptom: mount exit code 32, "bad superblock" in CSI logs, pod stuck in ContainerCreating with a looping promote/demote cycle. Fix: `/linstor-volume-repair`.

**DRBD D-state deadlock**: DRBD volumes in D-state block node shutdown. DRBD processes enter an uninterruptible sleep waiting for I/O that never completes. Only fixable with physical power cycle. Do not attempt `kubectl drain`, `talosctl upgrade`, or satellite pod restart to resolve D-state. (This is the DRBD-specific manifestation of the general CSI-unmount-deadlock pattern documented in `.claude/rules/k8s-csi.md`. The mitigation here — `kubectl drain` BEFORE Talos lifecycle ops, never AFTER D-state has set in — is the same.)

**Controller-Satellite SSL handshake failure after cert rotation**: After a cert-manager rotation (which can be triggered by `rollout restart deploy linstor-controller`), satellites may go OFFLINE if the CA and leaf-cert algorithms diverge (e.g. ECDSA CA vs. RSA leaf). Symptoms: `linstor node list` reports all satellites OFFLINE even though `LinstorSatellite` CRs still show `CONNECTED=True`; `linstor-affinity-controller` logs `x509: signature algorithm specifies an ECDSA public key, but have public key of type *rsa.PublicKey` against `linstor-controller:3371`. Fix: reconcile the cert-manager Issuer, then coordinated restart of the controller **and** all `linstor-satellite.*` StatefulSets so both sides re-read the new CA bundle. **Nuance:** if the controller pod happens to start during the cert-rotation window (init container builds JKS truststore from half-mounted secret symlinks), the Java process can carry a corrupt in-memory truststore even though the on-disk JKS is later correct. Verify with `openssl s_client -CAfile <JKS-extracted-ca>` from inside the controller pod — if openssl validates but Java still rejects, the JVM truststore state is stuck. Fix: a second controller pod restart after cert state has stabilised.

**DRBD resource zombie on removed node**: When LINSTOR removes a node as a replica for a resource (e.g. diskless client reassignment), the DRBD kernel state on that node can persist. `drbdadm` will not list the resource (no config file written), but `drbdsetup show <resource>` and `drbdsetup status <resource>` still report it with `connection:StandAlone` to every peer and `quorum:no`. The HA controller sees `quorum:no` and sets `drbd.linbit.com/lost-quorum:NoSchedule` on the node, blocking all scheduling. `linstor resource list` is consistent and shows only the live replicas — this is a node-local kernel artefact, not a control-plane inconsistency. Fix: `kubectl -n piraeus-datastore exec <satellite-pod> -- drbdsetup down <resource>` (netlink, no config required). The taint clears automatically on the next HA-controller reconcile.

**Split-brain**: Two nodes both promoted to Primary simultaneously (typically after network partition + manual intervention). LINSTOR/DRBD auto-resolution is configured, but if manual promotion occurred, one replica will have diverged data. Do not continue mounting until split-brain is resolved.

## Safety Constraints

- Never delete a LINSTOR resource to fix corruption — this destroys all replica data permanently.
- Never run `mkfs` on a DRBD device that may contain data. Use `xfs_repair` for XFS corruption.
- Never resize a LINSTOR volume while DRBD is in a degraded state.
- Never change StorageClass replica count on existing PVCs.
- Never promote DRBD manually on a node where the satellite pod is not Running.
- Talos nodes have no host shell — all device-level operations must go through satellite pod exec.
- Satellite exec for device ops: `kubectl exec -n piraeus-datastore <satellite-pod> -- <command>`
- Never restart the `linstor-controller` Deployment casually. It can trigger a cert-manager cert rotation that breaks SSL trust with ALL satellites. Before any controller restart, run `kubectl -n piraeus-datastore get certificate,secret | grep -i linstor` and inspect the CA/leaf algorithm alignment.
- If a `linstor-controller` restart is required for a real fix, plan a coordinated restart of `linstor-satellite.*` StatefulSets immediately afterwards so satellites re-read the CA bundle. Prefer `kubectl exec` into the controller pod for diagnostics over restart.
- Never use a `linstor-controller` restart as a first-order remedy for "stale" taints or HA quirks. Diagnose the specific subsystem first: run `/linstor-storage-triage`, check `LinstorSatellite` CRs, and inspect DRBD state directly on the node via Talos MCP.
- **Never `kubectl delete pod` a `linstor-satellite` pod showing D-state symptoms** (drbdadm hangs, satellite pod stuck Terminating, exec returning immediately with no effect). Pod restart cannot kill in-kernel I/O wait — DRBD in D-state survives the satellite container restart and the new pod inherits the wedged kernel state. Recovery is physical power cycle only (`runbook-cold-cluster-cutover.md` shutdown-umount escape hatch). Pod delete makes diagnosis harder by losing logs and confuses the operator about which kernel context is wedged.
- **For DRBD-touch operations across multiple storage nodes (TLS flip, satellite-config rollout, DRBD version bump, `drbdadm adjust` campaigns), order the nodes workers-first, then non-leader CPs, then leader CP last.** DRBD quorum and etcd quorum are independent — a DRBD I/O suspend that mis-fires on a CP node can starve concurrent etcd snapshot/compaction and trigger leader-election storms. Workers have no etcd co-tenancy. Identify etcd leader first via `talos_etcd subcommand=members` (look for `isLeader: true`).

## Access Patterns

```bash
# List nodes
kubectl linstor node list

# List resource replicas and their states
kubectl linstor resource list [-r <resource-name>]

# List volumes (shows DRBD minor number)
kubectl linstor volume list [-r <resource-name>]

# Storage pool capacity
kubectl linstor storage-pool list

# Find satellite pod on a specific node
kubectl -n piraeus-datastore get pods \
  -l app.kubernetes.io/component=linstor-satellite \
  --field-selector spec.nodeName=<node>

# Exec into satellite for device-level operations
kubectl exec -n piraeus-datastore <satellite-pod> -- <command>
```
