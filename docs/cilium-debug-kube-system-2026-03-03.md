# Cilium Policy Debug: kube-system (2026-03-03)

## Evidence

Hubble drops on all 7 cilium agents, single pattern:

```
monitoring/prometheus-…-0 (ID:9501) <> kube-system/coredns-… :9153 (ID:42571)
  policy-verdict:none  TRAFFIC_DIRECTION_UNKNOWN  DENIED (TCP Flags: SYN)
```

Continuous drops — Prometheus cannot scrape CoreDNS metrics on port 9153/TCP.

## Root Cause

The Prometheus CiliumNetworkPolicy (`cnp-prometheus.yaml`) egress rule for CoreDNS
allowed only ports 53/UDP and 53/TCP (DNS resolution) but **not** port 9153/TCP
(CoreDNS Prometheus metrics endpoint).

The fix (adding port 9153) existed in the working tree but was **never committed**,
so ArgoCD never synced it. ArgoCD reported `Synced/Healthy` because the live state
matched the last committed revision.

## Affected Files

- `kubernetes/overlays/homelab/infrastructure/kube-prometheus-stack/resources/cnp-prometheus.yaml`

```diff
     # DNS
     - toEndpoints:
         - matchLabels:
             k8s:io.kubernetes.pod.namespace: kube-system
             k8s-app: kube-dns
       toPorts:
         - ports:
             - port: "53"
               protocol: UDP
             - port: "53"
               protocol: TCP
+            - port: "9153"
+              protocol: TCP
```

## Validation Commands

```bash
# Verify CNP is updated
kubectl get cnp prometheus -n monitoring -o jsonpath='{.spec.egress}' | \
  python3 -c "import sys,json; rules=json.load(sys.stdin); [print(r) for r in rules if '9153' in str(r)]"

# Confirm no more drops on 9153
kubectl exec -n kube-system <cilium-pod> -- \
  hubble observe --namespace kube-system --verdict DROPPED --last 50 | grep 9153

# Verify Prometheus can scrape CoreDNS metrics
kubectl exec -n monitoring prometheus-monitoring-kube-prometheus-prometheus-0 -c prometheus -- \
  wget -qO- http://coredns-7859998f6-b75fm.kube-system:9153/metrics | head -5
```

## Other Findings

- **No CNPs in kube-system namespace** — kube-system pods (coredns, hubble-relay, hubble-ui, metrics-server) have no ingress policy restrictions. This is acceptable since the implicit default-deny only activates when a CNP selects an endpoint.
- **No K8s NetworkPolicies in kube-system** — no AND-semantics conflict.
- **No other drop patterns** in kube-system beyond the coredns:9153 scrape.
