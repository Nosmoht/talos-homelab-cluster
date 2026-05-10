# Day 2 — Cluster Operations & Maintenance

This document covers all ongoing operational workflows for the homelab cluster
after initial installation is complete.

## Quick Reference: Makefile Targets

| Target | Description |
|--------|-------------|
| `make -C talos gen-configs` | Generate configs (SOPS decryption automatic) |
| `make -C talos schematics` | Create factory schematics, update image URLs in patches |
| `make -C talos install-<node>` | Initial config apply to fresh node (`--insecure`) |
| `make -C talos bootstrap` | Bootstrap etcd on node-01 |
| `make -C talos apply-<node>` | Dry-run then apply config to node (192.168.2.x) |
| `make -C talos apply-all` | Apply config to all nodes |
| `make -C talos dry-run-<node>` | Regenerate configs, then dry-run (192.168.2.x) |
| `make -C talos upgrade-<node>` | Apply config + upgrade to new install image |
| `make -C talos talosconfig` | Regenerate talosconfig |
| `make -C talos clean` | Remove generated configs + decrypted secrets |

## Cluster Access

### Kubeconfig

```bash
talosctl -n 192.168.2.61 -e 192.168.2.61 kubeconfig --force /tmp/homelab-kubeconfig
export KUBECONFIG=/tmp/homelab-kubeconfig
```

### Talosctl

Reachable via VIP by default:

```bash
talosctl -n 192.168.2.60 -e 192.168.2.60 version
```

If VIP is unreachable, connect directly to a control plane node:

```bash
talosctl -n 192.168.2.61 -e 192.168.2.61 version
```

**Important:** Always use explicit `-n` and `-e` flags when VIP or default
endpoints are unreachable.

`talos/Makefile` apply/dry-run/upgrade targets use per-node explicit endpoints
by default (`--nodes <ip> --endpoints <ip>`) to avoid endpoint ambiguity during
partial control-plane outages.

## Applying Config Changes

### Workflow

```bash
# 1. Edit patch files (patches/ or nodes/)
vim patches/common.yaml

# 2. Dry-run (regenerates configs automatically)
make -C talos dry-run-node-01

# 3. Apply (runs dry-run-node-01 first)
make -C talos apply-node-01
```

### Order for Cluster-Wide Changes

1. Control plane nodes one at a time: `node-01` → `node-02` → `node-03`
2. Worker nodes: `node-04` → `node-05` → `node-06`
3. GPU worker: `node-gpu-01`
4. Pi worker: `node-pi-01`

Verify each node is `Ready` before proceeding to the next:

```bash
kubectl get nodes
talosctl -n 192.168.2.61 -e 192.168.2.61 health \
    --control-plane-nodes 192.168.2.61,192.168.2.62,192.168.2.63
```

### Network Interface Changes

Config apply that changes network interfaces automatically triggers a **reboot**.

**Before applying:**
1. Drain DRBD volumes from the node (`kubectl drain` or via LINSTOR)
2. Ensure no DRBD volume has its only replica on this node

**Reason:** DRBD volumes cause D-state processes during shutdown. Nodes get stuck
in a "shutting down" state. `talosctl reboot --mode force` does not help —
only a physical power cycle resolves this.

## Node Upgrade (Talos Version or Schematics)

### When to Upgrade

- New Talos version
- Changed boot kernel parameters (factory schematics)
- Changed Talos extensions (DRBD, NVIDIA, etc.)

### Workflow

```bash
# 1. Update schematics (if boot params or extensions changed)
make -C talos schematics

# 2. For a Talos/Kubernetes/Cilium version bump: update talos/versions.mk

# 3. Generate configs
make -C talos gen-configs

# 4. Per node: apply config + upgrade
make -C talos upgrade-node-01
# Wait until node is Ready again, then proceed to the next
make -C talos upgrade-node-02
make -C talos upgrade-node-03
make -C talos upgrade-node-04
make -C talos upgrade-node-05
make -C talos upgrade-node-06
make -C talos upgrade-node-gpu-01
make -C talos upgrade-node-pi-01
```

`make -C talos upgrade-<node>` performs two steps:
1. `talosctl apply-config` — set new config (sysctls, install image)
2. `talosctl upgrade --image <image> --wait --timeout 10m` — install the new
   UKI image and reboot the node

The correct image (standard vs. GPU) is assigned automatically:
- **Standard nodes** (node-01..06): image from `INSTALL_IMAGE` (built from `.schematic-ids.mk` + `TALOS_VERSION`)
- **GPU node** (node-gpu-01): image from `GPU_INSTALL_IMAGE` (built from `.schematic-ids.mk` + `TALOS_VERSION`)
- **Pi node** (node-pi-01): image from `PI_INSTALL_IMAGE` (built from `.schematic-ids.mk` + `TALOS_VERSION`)

### Post-Upgrade Verification

```bash
# Check boot parameters
talosctl -n 192.168.2.61 -e 192.168.2.61 read /proc/cmdline
# Expected: cpufreq.default_governor=performance intel_idle.max_cstate=0 ...

# Check sysctls
talosctl -n 192.168.2.61 -e 192.168.2.61 read /proc/sys/net/ipv4/tcp_slow_start_after_idle
# Expected: 0

talosctl -n 192.168.2.61 -e 192.168.2.61 read /proc/sys/vm/dirty_ratio
# Expected: 10

# Check CPU governor
talosctl -n 192.168.2.61 -e 192.168.2.61 read /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
# Expected: performance

# Check IOMMU
talosctl -n 192.168.2.61 -e 192.168.2.61 dmesg | grep -i iommu
# Expected: "DMAR: IOMMU enabled"

# Check I/O scheduler
talosctl -n 192.168.2.61 -e 192.168.2.61 read /sys/block/sda/queue/scheduler
# Expected: [none]

# Check Talos version
talosctl -n 192.168.2.61 -e 192.168.2.61 version
```

## Cluster Health Checks

### Vault Config Operator PKI Post-Deploy

Use this checklist after changes under:
- `kubernetes/overlays/homelab/infrastructure/vault-config-operator/`
- `kubernetes/overlays/homelab/infrastructure/vault-operator/`
- `kubernetes/overlays/homelab/infrastructure/cert-manager/`

```bash
# Argo CD application status
kubectl -n argocd get application vault-operator vault-config-operator cert-manager

# Vault Config Operator pod status and recent logs
kubectl -n vault get pods -l app.kubernetes.io/name=vault-config-operator
kubectl -n vault logs deploy/vault-config-operator --tail=100

# cert-manager issuer readiness (must stay Ready)
kubectl -n cert-manager get clusterissuer vault-internal -o yaml | yq '.status.conditions'

# Canary certificate readiness
kubectl -n cert-manager get certificate vault-pki-canary vault-pki-canary-atlas-svc
kubectl -n cert-manager get certificaterequest --sort-by=.metadata.creationTimestamp | tail -n 5
```

### Talos Level

```bash
# Full cluster health check
talosctl -n 192.168.2.61 -e 192.168.2.61 health \
    --control-plane-nodes 192.168.2.61,192.168.2.62,192.168.2.63

# Etcd members
talosctl -n 192.168.2.61 -e 192.168.2.61 etcd members

# Services on a node
talosctl -n 192.168.2.61 -e 192.168.2.61 services

# Dmesg from a node
talosctl -n 192.168.2.61 -e 192.168.2.61 dmesg --follow
```

### Kubernetes Level

```bash
kubectl get nodes -o wide
kubectl get pods -A | grep -v Running
kubectl top nodes
```

### Cilium

```bash
kubectl -n kube-system get pods -l k8s-app=cilium
kubectl -n kube-system get pods -l app.kubernetes.io/name=cilium-operator
kubectl get ciliumnode
```

### LINSTOR / Piraeus (Storage)

```bash
# Node status
kubectl linstor node list

# DRBD resources
kubectl linstor resource list

# Storage pools
kubectl linstor storage-pool list

# Piraeus operator pods
kubectl -n piraeus-datastore get pods
```

## Troubleshooting

### CiliumNode Retains Old IPs After Node IP Change

**Symptom:** Cross-node pod networking is broken. CiliumNode CRD shows
old IP addresses.

**Fix:**
```bash
kubectl delete ciliumnode <node-name>
kubectl -n kube-system delete pod -l k8s-app=cilium \
    --field-selector spec.nodeName=<node-name>
```

The CiliumNode is automatically recreated with correct IPs.

### Node Stuck in "Shutting Down"

**Symptom:** Node remains stuck after reboot/shutdown in "shutting down" state.
`talosctl reboot --mode force` does not work.

**Cause:** D-state processes on DRBD volumes.

**Fix:** Physical power cycle (disconnect and reconnect power).

**Prevention:** Before config changes that trigger a reboot,
drain DRBD volumes from the node.

### Etcd Member Permanently Removed

If an etcd member cannot rejoin:

```bash
talosctl -n <node-ip> -e <node-ip> reset \
    --system-labels-to-wipe EPHEMERAL \
    --reboot \
    --graceful=false
```

This wipes etcd data on the node. The node rejoins as a learner and is
automatically promoted to voter after ~1-2 minutes.

### Kubelet CSR Pending

If the cert-approver pod is running on an unreachable node:

```bash
kubectl get csr
kubectl certificate approve <csr-name>
```

### XFS Corruption on DRBD Volume

**Symptom:** Pod stuck in ContainerCreating. Events show mount exit code 32
or "bad superblock" on `/dev/drbd<N>`. CSI logs show promote/demote loop repeating every ~2 minutes.

**Cause:** Unclean DRBD demotion (node crash, power loss) corrupts XFS metadata.

**Fix:**
```
/linstor-volume-repair --resource <linstor-resource-name> --node <node-name>
```

Manual steps: scale down workload → promote DRBD in satellite pod → `xfs_repair /dev/drbd<N>` → demote → scale up.
Find resource name with `kubectl linstor resource list`. Find DRBD minor with `kubectl linstor volume list -r <resource>`.

### LINSTOR Controller CrashLoopBackOff

Transient errors often resolve with a pod restart:

```bash
kubectl -n piraeus-datastore delete pod -l app.kubernetes.io/name=linstor-controller
```

### Etcd Cannot Be Restarted via API

`talosctl service etcd restart` is **not supported**. Etcd restarts are only
possible via node reboot:

```bash
talosctl -n <node-ip> -e <node-ip> reboot
```

## Secrets Management

### SOPS Workflow

`secrets.yaml` is encrypted with SOPS (AGE backend). Makefile targets
automatically decrypt to `.secrets.dec.yaml` (gitignored).

```bash
# Manually decrypt secrets (for inspection)
sops -d secrets.yaml

# Edit secrets (opens editor with decrypted contents)
sops secrets.yaml

# Clean up decrypted file
make clean    # also removes .secrets.dec.yaml
```

### Customer Runtime Secrets (Vault + ESO)

Bootstrap and platform lifecycle secrets remain in SOPS/KSOPS.

Customer runtime secrets are sourced from Vault and materialized by External
Secrets Operator (ESO) through `ExternalSecret` resources.

Network baseline for ESO is platform-owned and managed in PNI resources.
Customer namespaces do not own ESO control-plane network policy.

Operational checks:

```bash
# ESO control plane health
kubectl -n external-secrets get pods
kubectl -n argocd get application external-secrets

# Tenant-side resources (example namespace)
kubectl -n <tenant-namespace> get secretstore,externalsecret,secret
kubectl -n <tenant-namespace> describe externalsecret <name>
```

Reference:
- `docs/external-secrets-customer-guide.md`

### Regenerate Talosconfig

```bash
make -C talos talosconfig
```

Uses the (unencrypted) secrets directly. If `secrets.yaml` is SOPS-encrypted,
manually decrypt first or run `make -C talos gen-configs` beforehand (creates
`.secrets.dec.yaml`).

## IP Reference

| Node | IP | Role |
|------|-----|------|
| node-01 | 192.168.2.61 | control-plane |
| node-02 | 192.168.2.62 | control-plane |
| node-03 | 192.168.2.63 | control-plane |
| node-04 | 192.168.2.64 | worker |
| node-05 | 192.168.2.65 | worker |
| node-06 | 192.168.2.66 | worker |
| node-gpu-01 | 192.168.2.67 | worker (GPU) |
| VIP | 192.168.2.60 | kube-apiserver HA |
| Gateway/DNS/NTP | 192.168.2.1 | — |
