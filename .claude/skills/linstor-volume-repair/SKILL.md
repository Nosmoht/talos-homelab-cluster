---
name: linstor-volume-repair
description: "Repair corrupted XFS on a DRBD-backed LINSTOR volume: detach CSI, promote DRBD, xfs_repair, demote, re-attach. Use when mount exit code 32 or bad superblock. Do NOT use for DRBD D-state (power-cycle) or ArgoCD sync issues."
argument-hint: "--resource <linstor-resource-name> --node <node-name>"
disable-model-invocation: true
allowed-tools: Bash, Read
---

You are performing a LINSTOR volume repair on a Talos Linux node. This is a destructive,
multi-step operation. Present each destructive command to the user and wait for explicit
confirmation ("yes" or "proceed") before executing it.

## Environment Setup

Read `cluster.yaml` for kubeconfig path and node name map.

```bash
KUBECONFIG=$(yq '.kubeconfig' cluster.yaml)
```

If missing, stop: "Copy `cluster.yaml.example` to `cluster.yaml`."

## Reference Files

Read before acting:
- `.claude/skills/linstor-volume-repair/references/xfs-drbd-repair-procedure.md`
- `.claude/rules/linstor-storage-guardrails.md`
- `.claude/rules/talos-mcp-first.md` — D-state recovery section (§Node Recovery)

## Inputs

Both arguments are required. If either is missing, stop and ask:

- `--resource <name>`: LINSTOR resource name (not PVC name). Format: `pvc-<uuid>`. Find with:
  ```bash
  kubectl linstor resource list  # or: kubectl -n piraeus-datastore exec <ctrl-pod> -- linstor resource list
  ```
- `--node <name>`: Node name where the corrupted replica lives (e.g., `node-06`).

## Scope Guard

- General LINSTOR health check → use `/linstor-storage-triage` instead.
- DRBD D-state (node stuck in "Shutting Down") → physical power cycle required. Do not attempt repair.
- ArgoCD sync failure for Piraeus operator → use `/gitops-health-triage` instead.
- Volume in split-brain → resolve split-brain first, then repair.

## Workflow

### Step 1: Preflight

Check if the `kubectl-linstor` plugin is available. If not, fall back to exec via the controller pod:
```bash
if kubectl linstor version &>/dev/null; then
  LINSTOR="kubectl linstor"
else
  CTRL_POD=$(KUBECONFIG=$KUBECONFIG kubectl -n piraeus-datastore get pods \
    -l app.kubernetes.io/component=linstor-controller \
    --field-selector status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}')
  LINSTOR="kubectl -n piraeus-datastore exec $CTRL_POD -- linstor"
fi
```

Run:
```bash
KUBECONFIG=$KUBECONFIG $LINSTOR node list
KUBECONFIG=$KUBECONFIG $LINSTOR resource list -r $RESOURCE
KUBECONFIG=$KUBECONFIG $LINSTOR volume list -r $RESOURCE
```

Check:
1. Target node satellite shows Online. If Offline, stop: "Satellite is OFFLINE. Repair cannot proceed — resolve satellite connectivity first."
2. Resource exists and has a replica on the target node.
3. DRBD connection state: if any replica shows `StandAlone`, stop: "Resource is in split-brain (StandAlone). Resolve split-brain before attempting repair."
4. Find DRBD minor number from `volume list` output (MinorNr column). Save as `MINOR`.

Then find the satellite pod on the target node:
```bash
SATELLITE_POD=$(KUBECONFIG=$KUBECONFIG kubectl -n piraeus-datastore get pods \
  -l app.kubernetes.io/component=linstor-satellite \
  --field-selector spec.nodeName=$NODE \
  -o jsonpath='{.items[0].metadata.name}')
echo "Satellite pod: $SATELLITE_POD on node $NODE"
```

Verify the pod's `spec.nodeName` matches the target node (DRBD minor numbers are node-local).

Check that `xfs_repair` is available in the satellite container:
```bash
KUBECONFIG=$KUBECONFIG kubectl exec -n piraeus-datastore $SATELLITE_POD -- which xfs_repair
```

If missing, stop and present options:
- Option A (ephemeral debug container, no cluster changes): use `kubectl debug` with an image that includes xfsprogs.
- Option B (permanent): patch `LinstorSatelliteConfiguration` to add xfsprogs to the satellite image.
Do not proceed until `xfs_repair` is available.

Present preflight summary:
```
Preflight results:
- Resource: <name>
- Target node: <node>
- Satellite pod: <pod-name>  [VERIFIED on correct node]
- DRBD minor: <minor>  → /dev/drbd<minor>
- xfs_repair: available
- Connection state: Connected (no split-brain)
- Replica state: <state>
```

### Step 2: Identify CSI Consumer

Find the PVC and pod consuming this volume:
```bash
# Map LINSTOR resource name to PV
KUBECONFIG=$KUBECONFIG kubectl get pv -o json | \
  jq -r --arg res "$RESOURCE" \
  '.items[] | select(.spec.csi.volumeHandle == $res) | [.metadata.name, .spec.claimRef.namespace, .spec.claimRef.name] | @tsv'

# Find pod using this PVC
KUBECONFIG=$KUBECONFIG kubectl get pods -A -o json | \
  jq -r --arg pvc "$PVC_NAME" --arg ns "$PVC_NS" \
  '.items[] | select(.metadata.namespace == $ns) | select(.spec.volumes[]?.persistentVolumeClaim.claimName == $pvc) | [.metadata.namespace, .metadata.name] | @tsv'
```

Present:
```
CSI consumer:
- PV: <pv-name>
- PVC: <namespace>/<pvc-name>
- Pod: <namespace>/<pod-name>  [stuck in ContainerCreating / reason]
```

Identify the workload type (StatefulSet / Deployment) and its name for the scale-down command.

### Step 3: Scale Down Workload

Present the exact command and wait for confirmation:

```
To proceed, I will run:
  kubectl scale statefulset <name> -n <namespace> --replicas=0
  (or: kubectl scale deployment <name> -n <namespace> --replicas=0)

This terminates the pod and stops CSI mount attempts.
Type "yes" or "proceed" to continue, or "no" to abort.
```

After confirmation, run the command. Then wait for the pod to terminate:
```bash
KUBECONFIG=$KUBECONFIG kubectl wait pod/<pod-name> -n <namespace> \
  --for=delete --timeout=60s
```

If the pod does not terminate within 60s, report: "Pod did not terminate. Check for finalizers or stuck volumes. Do not proceed until the pod is gone."

### Step 4: Verify DRBD Detached

After pod termination, verify the volume is no longer in use:
```bash
KUBECONFIG=$KUBECONFIG $LINSTOR resource list -r $RESOURCE
```

All replicas should show `UpToDate` (not `InUse`). If still InUse after 30s, repeat once. If still InUse, stop: "Volume still InUse — CSI driver has not released the resource. Check the LINSTOR CSI node pod logs."

### Step 5: Promote and Repair

First, verify the device is not mounted inside the satellite pod:
```bash
KUBECONFIG=$KUBECONFIG kubectl exec -n piraeus-datastore $SATELLITE_POD -- \
  sh -c "mount | grep drbd$MINOR || echo 'not mounted'"
```

If mounted output is shown (not "not mounted"), stop: "Device /dev/drbd$MINOR is still mounted inside the satellite. The workload has not fully released the volume."

Present the promote command and wait for confirmation:
```
I will now promote DRBD to Primary to enable xfs_repair:
  kubectl exec -n piraeus-datastore $SATELLITE_POD -- drbdadm primary $RESOURCE

Type "yes" or "proceed" to continue.
```

After confirmation:
```bash
KUBECONFIG=$KUBECONFIG kubectl exec -n piraeus-datastore $SATELLITE_POD -- \
  drbdadm primary $RESOURCE

# Verify Primary
KUBECONFIG=$KUBECONFIG kubectl exec -n piraeus-datastore $SATELLITE_POD -- \
  drbdadm status $RESOURCE
```

Confirm the output shows `role:Primary`. If not, stop and report.

Run xfs_repair:
```bash
KUBECONFIG=$KUBECONFIG kubectl exec -n piraeus-datastore $SATELLITE_POD -- \
  xfs_repair /dev/drbd$MINOR
```

Capture the exit code and output. Interpret:
- **Exit 0**: Repair succeeded. Continue to Step 6.
- **Exit 1**: Repair failed. Go to Step 6 (demote) and report failure. Do not attempt mkfs.
- **Exit 2** or output mentioning "log is not empty" / "please mount and umount": The XFS log has uncommitted transactions. Present this to the user and wait for a **separate, explicit confirmation**:

```
xfs_repair reports the XFS log is dirty and requires -L to zero it.
This discards uncommitted transactions (typically <30s of writes before the crash).
Since this volume has been inaccessible for an extended period, the data is already
effectively lost. However, running xfs_repair -L is a destructive action.

Type "yes -L" (must include "-L" to confirm you understand) to proceed with log zeroing,
or "no" to abort.
```

If confirmed with "yes -L":
```bash
KUBECONFIG=$KUBECONFIG kubectl exec -n piraeus-datastore $SATELLITE_POD -- \
  xfs_repair -L /dev/drbd$MINOR
```

### Step 6: Demote

Present the demote command and wait for confirmation:
```
Repair is complete. I will demote DRBD back to Secondary:
  kubectl exec -n piraeus-datastore $SATELLITE_POD -- drbdadm secondary $RESOURCE

Type "yes" or "proceed" to continue.
```

After confirmation:
```bash
KUBECONFIG=$KUBECONFIG kubectl exec -n piraeus-datastore $SATELLITE_POD -- \
  drbdadm secondary $RESOURCE
```

Verify:
```bash
KUBECONFIG=$KUBECONFIG kubectl exec -n piraeus-datastore $SATELLITE_POD -- \
  drbdadm status $RESOURCE
```

If the demote command hangs (no output after 30s) or fails: stop immediately. Do NOT restart the satellite pod. Report:
"DRBD demote is hanging — the device may be in D-state. Physical power cycle of the node may be required. See `.claude/rules/talos-mcp-first.md` §Node Recovery. Do not attempt further actions on this node."

After successful demote, verify LINSTOR resource state:
```bash
KUBECONFIG=$KUBECONFIG $LINSTOR resource list -r $RESOURCE
```

All replicas should show `UpToDate`.

### Step 7: Scale Up and Verify

Present the scale-up command and wait for confirmation:
```
Repair complete. I will restore the workload:
  kubectl scale statefulset <name> -n <namespace> --replicas=<original-count>

Type "yes" or "proceed" to continue.
```

After confirmation, run the command and verify:
```bash
# Wait for pod to start
KUBECONFIG=$KUBECONFIG kubectl rollout status statefulset/<name> -n <namespace> --timeout=120s

# Check pod status
KUBECONFIG=$KUBECONFIG kubectl get pod <pod-name> -n <namespace>

# Check CSI node logs for mount success (no more exit 32)
KUBECONFIG=$KUBECONFIG kubectl -n piraeus-datastore logs \
  -l app.kubernetes.io/component=linstor-csi-node \
  --field-selector spec.nodeName=$NODE \
  -c linstor-csi --tail=20
```

## Output

Present a repair report:

```
## LINSTOR Volume Repair: $RESOURCE on $NODE

| Field | Value |
|-------|-------|
| Resource | <name> |
| Node | <node> |
| DRBD minor | <minor> → /dev/drbd<minor> |
| PVC | <namespace>/<pvc-name> |
| Workload | <statefulset/deployment name> |
| xfs_repair result | clean / required -L / failed |
| Post-repair DRBD state | UpToDate / degraded |
| Workload status | Running / still failing |
```

If any step failed, list the failure and the last good state.

## Hard Rules

- Every destructive command requires explicit user confirmation ("yes" or "proceed").
- `xfs_repair -L` requires a separate confirmation — the user must type "yes -L".
- Never promote DRBD on a node where the satellite pod is not Running.
- Never run `mkfs` on any DRBD device.
- Always demote DRBD after repair, even if the repair failed. If demote hangs, halt and report — do not restart the satellite pod.
- Always verify the satellite pod's `spec.nodeName` matches the target node before any exec.
- If the resource has only 1 replica (`linstor-nvme-noreplica` StorageClass), state clearly before proceeding: "This is a single-replica volume. If xfs_repair fails or the device is physically damaged, data loss is permanent."
- If both replicas show corruption (dual unclean shutdown), warn: "Both replicas may be corrupted. xfs_repair -L is the only recovery path. There is a risk of permanent data loss."
- This skill does not delete or recreate LINSTOR resources. If repair fails and data loss is acceptable, the recovery path is: delete the PVC, let the CSI provisioner create a fresh one.
