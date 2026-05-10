# XFS / DRBD Repair Procedure Reference

## Finding the DRBD Minor Number

```bash
kubectl linstor volume list -r <resource-name>
```

Look for the `MinorNr` column. The DRBD block device is `/dev/drbd<minor>`.

Example output:
```
ResourceName                         | Node    | StorPoolName | VlmNr | MinorNr | DevicePath    | Allocated | State
pvc-62e631ed-bdb0-4df9-acd0-d03214a | node-06 | lvm-thick    |     0 |    1021 | /dev/drbd1021 | 1.00 GiB  | InUse
pvc-62e631ed-bdb0-4df9-acd0-d03214a | node-04 | lvm-thick    |     0 |    1021 | /dev/drbd1021 | 1.00 GiB  | UpToDate
```

Note: `/dev/drbd<minor>` is node-local. Minor 1021 on node-06 is NOT the same device as minor 1021 on node-04.

## Satellite Pod Discovery

```bash
kubectl -n piraeus-datastore get pods \
  -l app.kubernetes.io/component=linstor-satellite \
  --field-selector spec.nodeName=<target-node> \
  -o jsonpath='{.items[0].metadata.name}'
```

Always verify the pod's `spec.nodeName` matches your target before exec.

## Checking xfs_repair Availability

```bash
kubectl exec -n piraeus-datastore <satellite-pod> -- which xfs_repair
```

If missing (`which: no xfs_repair`), options:
1. **Ephemeral debug container** (preferred, no cluster changes needed):
   ```bash
   kubectl debug -it -n piraeus-datastore <satellite-pod> \
     --image=registry.k8s.io/e2e-test-images/busybox:1.29 \
     --target=linstor-satellite \
     --share-processes -- sh
   # Inside: install xfsprogs or use pre-installed image
   ```
   Better: use an image with xfsprogs: `ubuntu:22.04` or `alpine:3` + `apk add xfsprogs`

2. **Patch LinstorSatelliteConfiguration** to add xfsprogs to the satellite image (permanent fix, requires LinstorSatelliteConfiguration update and satellite pod restart).

## DRBD Promote / Demote

Inside the satellite pod:

```bash
# Promote to Primary (required before xfs_repair)
drbdadm primary <resource-name>
# OR by device path:
drbdsetup primary /dev/drbd<minor>

# Check state after promote
drbdadm status <resource-name>
# Should show: role:Primary

# Demote back to Secondary (required after repair)
drbdadm secondary <resource-name>
# Should show: role:Secondary
```

Resource name format matches LINSTOR resource name (e.g., `pvc-62e631ed-bdb0-4df9-acd0-d03214aba956`).

## Verifying Device is Not Mounted

Before running xfs_repair:

```bash
kubectl exec -n piraeus-datastore <satellite-pod> -- \
  mount | grep drbd<minor>
```

If any output is shown, the device is still mounted. Do not proceed — the workload has not been fully terminated.

Also check via lsblk:
```bash
kubectl exec -n piraeus-datastore <satellite-pod> -- \
  lsblk -o NAME,MOUNTPOINT | grep drbd<minor>
```

## xfs_repair Decision Tree

```bash
kubectl exec -n piraeus-datastore <satellite-pod> -- \
  xfs_repair /dev/drbd<minor>
```

**Exit codes:**
- `0`: Repair completed successfully (or no repairs needed)
- `1`: Repair failed — filesystem may be unmountable. Do NOT try `mkfs`. Report to user.
- `2`: Filesystem is dirty (log not empty). This means `xfs_repair` requires `-L` to proceed.

**When you see exit code 2 or "Please mount and umount the filesystem" error:**
This means the XFS log has uncommitted transactions. Running with `-L` zeroes the log, which discards those transactions (typically < 30 seconds of writes before the crash). Present this to the user and wait for explicit confirmation:

```
xfs_repair with -L will zero the log, discarding uncommitted transactions.
For a Redis cache that has been inaccessible for 14+ days, this is acceptable.
Type "yes" to continue with xfs_repair -L, or "no" to abort.
```

**Running with -L (after explicit user confirmation only):**
```bash
kubectl exec -n piraeus-datastore <satellite-pod> -- \
  xfs_repair -L /dev/drbd<minor>
```

**xfs_repair duration:** Scales with volume size. For volumes >10 GiB, expect 1-5 minutes. Do not interrupt the session — partial repair is worse than no repair.

## CSI Promote/Demote Loop Explanation

When XFS is corrupt, the loop looks like this:
1. Kubernetes kubelet calls CSI NodeStageVolume
2. LINSTOR CSI promotes DRBD on this node (→ Primary)
3. CSI calls `mount -t xfs ... /dev/drbd<minor> <target>`
4. mount returns exit code 32 ("wrong fs type, bad option, bad superblock")
5. CSI unmounts (which triggers LINSTOR demote → Secondary)
6. Kubernetes retries ~every 2 minutes
7. dmesg shows "Primary" / "Secondary" flipping every ~2 minutes

This is why `kubectl describe pod` shows "ContainerCreating" indefinitely with no crash count — the container never starts, only the mount is attempted and fails.

## Verification Commands After Repair

```bash
# 1. Verify DRBD is Secondary and UpToDate on all nodes
kubectl linstor resource list -r <resource-name>
# Expected: all replicas show UpToDate, none show InUse

# 2. After scaling workload back up, verify mount succeeded
kubectl describe pod <pod-name> -n <namespace>
# Should NOT show "bad superblock" or "mount" errors
# ContainerCreating should resolve within 30 seconds

# 3. Check LINSTOR CSI node logs stop looping
kubectl -n piraeus-datastore logs -l app.kubernetes.io/component=linstor-csi-node \
  --field-selector spec.nodeName=<target-node> -c linstor-csi --tail=20
# Should NOT show repeated "exit status 32" messages

# 4. Verify pod is Running
kubectl get pod <pod-name> -n <namespace>
# Expected: STATUS=Running, READY=1/1
```
