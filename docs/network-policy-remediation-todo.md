# Network Policy Remediation TODO (homelab)

Date: 2026-03-02
Scope: CiliumNetworkPolicy resources in `monitoring` and `dex` plus uncovered high-value workloads.

- [x] Build runtime inventory of CNPs, selected pods, and recent connectivity failures.
- [x] Fix `prometheus` CNP to allow Kubernetes API egress required for service discovery (`10.96.0.1:443`, `kube-apiserver:443/6443`).
- [x] Fix `loki` CNP to allow Kubernetes API egress for `loki-sc-rules` sidecar.
- [x] Fix `loki` CNP to allow Loki canary <-> Loki gateway connectivity (service `:80` -> backend `:8080`).
- [x] Fix `loki` CNP to allow Loki single-binary <-> Loki memcached caches on TCP/11211.
- [x] Add missing CNP for `monitoring-prometheus-node-exporter` (previously uncovered in `monitoring` namespace) with least-privilege ingress from Prometheus only.
- [x] Re-verify runtime after changes: API connectivity restored for policy-controlled observability components; Grafana/Thanos queries return data.

## Validation Summary
- `prometheus` and `grafana` can reach kube-apiserver (`10.96.0.1:443` and `kube-apiserver:6443` path).
- Loki rule sidecar can reach kube-apiserver.
- Loki policy identities can reach:
  - gateway path (`ClusterIP:80` and backend pod `:8080`)
  - cache backends (`loki-chunks-cache:11211`, `loki-results-cache:11211`)
- `node-exporter` CNP now exists in-cluster with Argo tracking annotation.

## Remaining Observations (not policy-blocking)
- Loki canary still logs intermittent query/tail timeouts under load; direct TCP connectivity tests now pass, indicating likely application/performance behavior rather than network policy denial.
- Many `up` targets remain `0`, which points to scrape endpoint-level issues (service/port/auth/readiness) and not a CNP transport block.
