---
paths:
  - "kubernetes/**/cnp-*.yaml"
  - "kubernetes/**/ccnp-*.yaml"
  - "kubernetes/bootstrap/cilium/**"
  - "kubernetes/**/platform-network-interface/**"
  - "docs/day2-operations.md"
---

# Cilium Service BPF Sync Troubleshooting

## Symptom

Pods report TCP dial timeouts to arbitrary in-cluster ClusterIPs even though target pods are healthy, Cilium agents are Running, and EndpointSlice objects show all expected endpoints as `ready: true, serving: true`.

Examples observed in production:
- LINSTOR controller pod can reach `linstor-controller:3371` but pods from other namespaces time out
- MinIO-operator pod can't reach the `kubernetes` API service — reports `dial tcp <kube-api-clusterip>:443: i/o timeout` on its Watch clients
- Loki write pods report `dial tcp <minio-clusterip>:443: i/o timeout` on every S3 PUT despite other pods on the same node reaching MinIO fine the minute before

## Root Cause

Cilium agents write service backends to BPF maps keyed by `(ClusterIP, port)` → list of `(backend-pod-ip, backend-port)`. The agent keeps these in sync with Kubernetes `EndpointSlice` objects via a watch. **If the Cilium operator loses API-server connectivity for an extended period** (observed: >24 h of `Error retrieving lease lock` messages against its local Cilium kube-apiserver proxy), leader re-election and event-replay can leave all agents holding an incomplete service map — typically only the first backend of each service is programmed.

## Diagnosis

Pick any Cilium agent and dump its service table for the `kubernetes` default service (which should show every control-plane node as a backend):

```
agent=$(kubectl -n kube-system get pod -l k8s-app=cilium -o jsonpath='{.items[0].metadata.name}')
kubectl -n kube-system exec "$agent" -c cilium-agent -- cilium-dbg service list | grep '<kube-api-clusterip>:443' -A 4
```

Expected output for a healthy N-control-plane cluster is N backend lines. A single backend line — or a line resolving to a non-backend address — confirms BPF desync. Cross-check against `kubectl get endpointslice -n default -l kubernetes.io/service-name=kubernetes -o yaml` to prove the EndpointSlice itself is correct (i.e. the desync is in Cilium, not upstream).

## Fix

**Escalating severity, lowest first:**

1. **Cilium operator restart** — often sufficient if only the operator's own lease/watch loop was stuck:
   ```
   kubectl -n kube-system rollout restart deploy cilium-operator
   ```
   Wait ~30 s, re-run the diagnosis. If backends are still wrong, escalate.

2. **Cilium agent DaemonSet rolling restart** — the canonical fix that rebuilds every agent's BPF map from the current EndpointSlice state. Each agent drops its map on shutdown and the new pod rebuilds from scratch:
   ```
   kubectl -n kube-system rollout restart ds cilium
   kubectl -n kube-system rollout status ds cilium --timeout=5m
   ```
   Each node experiences ~10–15 s of service-networking blackhole during its agent rotation; rolling order skips nodes until the previous is Ready, so the window is sequential, not simultaneous.

## Post-Fix Action

Several long-running pods cache their own DNS/TLS/client state and will keep reporting the old failures even after the BPF maps are correct. After a Cilium fix, restart:

- Any pod whose logs still show `dial tcp ...: i/o timeout` to a ClusterIP
- `linstor-csi-controller` and `linstor-affinity-controller` (known to cache TLS handshake failures in Go x509 packages — see `linstor-storage-guardrails.md` Known Failure Modes)
- Any Go-based operator reconciling against API services (MinIO operator, cert-manager webhooks, Kyverno if observed degraded)

## Prevention

Monitor `cilium-operator` restart count and leader-lease churn:

- Log lines matching `Error retrieving lease lock.*Client.Timeout exceeded` indicate the operator is losing API-server connectivity.
- More than 3 operator pod restarts per week is a strong signal — investigate API-server health, webhook latency, or node resource pressure before the desync manifests in service maps.
