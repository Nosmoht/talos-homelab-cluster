# Cilium Policy Debug: piraeus-datastore

**Date:** 2026-03-03
**Scope:** piraeus-datastore namespace (LINSTOR/Piraeus storage infrastructure)
**Type:** Hardening (no active drops — namespace had zero policies)

## 1. Evidence

### Current state
- **Zero CiliumNetworkPolicies** in piraeus-datastore namespace
- **Zero Kubernetes NetworkPolicies** in piraeus-datastore namespace
- **Zero CiliumClusterwideNetworkPolicies** affecting the namespace
- **No Hubble drops observed** — all traffic forwarded (no implicit deny)

### Traffic flows observed via Hubble
| Source | Destination | Port | Protocol | Purpose |
|--------|-------------|------|----------|---------|
| linstor-controller | linstor-satellite | 3367/TCP | overlay | Controller→satellite communication |
| linstor-satellite | linstor-satellite | 7001/TCP | overlay | DRBD data replication |
| host (kubelet) | linstor-satellite | 3367/TCP | local | Liveness probe (tcpSocket) |
| host (kubelet) | ha-controller | 8000/TCP | local | Liveness probe (httpGet /healthz) |
| ha-controller | kube-apiserver | 6443/TCP | stack | HA failover decisions |
| linstor-csi-nfs-server | kube-apiserver | 6443/TCP | stack | Resource watches |

### Components inventory (29 pods, 9 component types)
| Component | Type | Count | Network | Ports |
|-----------|------|-------|---------|-------|
| piraeus-operator | Deployment | 1 | pod | 9443 (webhook), 8081 (healthz), 8443 (metrics) |
| linstor-controller | Deployment | 1 | pod | 3371 (secure-api), 3370 (api) |
| linstor-satellite | DaemonSet | 6 | pod | 3367 (linstor), 9942 (drbd-reactor metrics) |
| ha-controller | DaemonSet | 6 | pod | 8000 (healthz) |
| linstor-affinity-controller | Deployment | 1 | pod | 8000 (health), 8081 (metrics) |
| linstor-csi-controller | Deployment | 1 | pod | 9808-9813 (healthz per sidecar) |
| linstor-csi-node | DaemonSet | 6 | **host** | N/A (hostNetwork — no CNP needed) |
| linstor-csi-nfs-server | DaemonSet | 6 | pod | 111 (portmapper), 2049 (NFS) |
| linstor-storage-pool-autovg | Deployment | 1 | pod | none |

## 2. Root Cause

No root cause (no active issue). This is a **hardening exercise** — the piraeus-datastore namespace was the last remaining infrastructure namespace without CiliumNetworkPolicies, leaving all 29 pods open to unrestricted network access.

## 3. Manifest Files Patched

### New CNP files (8 total)
All in `kubernetes/overlays/homelab/infrastructure/piraeus-operator/resources/`:

| File | endpointSelector | Ingress | Egress |
|------|-----------------|---------|--------|
| `cnp-piraeus-operator.yaml` | `piraeus-operator` | webhook(kube-api:9443), probes(host:8081) | linstor-ctrl:3370/3371, kube-api, DNS |
| `cnp-linstor-controller.yaml` | `linstor-controller` | clients(satellite,csi,affinity,autovg,operator:3370/3371), probes+csi-node(host:3370/3371) | satellites:3367, kube-api, DNS |
| `cnp-linstor-satellite.yaml` | `linstor-satellite` | ctrl:3367, DRBD(satellite:7000-7999), probes(host:3367), prometheus:9942 | ctrl:3370/3371, DRBD(satellite:7000-7999), DNS |
| `cnp-ha-controller.yaml` | `ha-controller` | probes(host:8000) | kube-api, DNS |
| `cnp-linstor-csi-controller.yaml` | `linstor-csi-controller` | probes(host:9808-9813) | linstor-ctrl:3370/3371, kube-api, DNS |
| `cnp-linstor-csi-nfs-server.yaml` | `linstor-csi-nfs-server` | NFS(host:111/2049) | kube-api, DNS |
| `cnp-linstor-affinity-controller.yaml` | `linstor-affinity-controller` | probes(host:8000) | linstor-ctrl:3370/3371, kube-api, DNS |
| `cnp-linstor-storage-pool-autovg.yaml` | `linstor-storage-pool-autovg` | (egress-only) | linstor-ctrl:3370/3371, kube-api, DNS |

### Modified files
- `kubernetes/overlays/homelab/infrastructure/piraeus-operator/resources/kustomization.yaml` — added 8 CNP entries
- `kubernetes/overlays/homelab/infrastructure/kube-prometheus-stack/resources/cnp-prometheus.yaml` — added cross-namespace egress rule for drbd-reactor metrics (port 9942)

### Key design decisions
- **linstor-csi-node skipped** — uses hostNetwork, has host identity, not subject to CNPs
- **DRBD port range 7000-7999** — LINSTOR assigns ports starting at 7000, one per resource/volume
- **NFS server ingress from host only** — kubelet mounts NFS via host, not pod identity
- **kube-apiserver dual port pattern** — ClusterIP:443 via toCIDRSet + DNAT endpoint:6443 via toEntities (standard cluster pattern)
- **Prometheus cross-namespace scrape** — satellite pods expose drbd-reactor metrics on 9942 via ServiceMonitor

## 4. Validation Commands

### Pre-deployment: verify kustomize renders
```bash
kubectl kustomize kubernetes/overlays/homelab/infrastructure/piraeus-operator/resources/ | grep "kind: CiliumNetworkPolicy" | wc -l
# Expected: 8
```

### Post-deployment: verify CNPs are synced
```bash
KUBECONFIG=/tmp/homelab-kubeconfig kubectl get cnp -n piraeus-datastore
# Expected: 8 policies, all with STATUS OK

KUBECONFIG=/tmp/homelab-kubeconfig kubectl get application -n argocd piraeus-operator -o jsonpath='{.status.sync.status}'
# Expected: Synced
```

### Post-deployment: verify no drops on critical flows
```bash
# DRBD replication between satellites
KUBECONFIG=/tmp/homelab-kubeconfig kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
  hubble observe --namespace piraeus-datastore --verdict DROPPED --last 500

# Controller → satellite communication
KUBECONFIG=/tmp/homelab-kubeconfig kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
  hubble observe --namespace piraeus-datastore --to-port 3367 --verdict DROPPED --last 100

# HA controller → kube-apiserver
KUBECONFIG=/tmp/homelab-kubeconfig kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
  hubble observe --from-namespace piraeus-datastore --to-port 6443 --verdict DROPPED --last 100

# Prometheus → drbd-reactor metrics
KUBECONFIG=/tmp/homelab-kubeconfig kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
  hubble observe --to-namespace piraeus-datastore --to-port 9942 --verdict DROPPED --last 100
```

### Post-deployment: verify all pods still healthy
```bash
KUBECONFIG=/tmp/homelab-kubeconfig kubectl get pods -n piraeus-datastore -o wide
# All pods should remain Running with no restarts

KUBECONFIG=/tmp/homelab-kubeconfig kubectl linstor node list
# All satellites should be Online

KUBECONFIG=/tmp/homelab-kubeconfig kubectl linstor resource list-volumes
# All volumes should be UpToDate
```
