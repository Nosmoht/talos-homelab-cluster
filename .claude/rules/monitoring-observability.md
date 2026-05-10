---
paths:
  - "kubernetes/**/kube-prometheus-stack/**"
  - "kubernetes/**/alloy/**"
  - "kubernetes/**/loki/**"
  - "kubernetes/**/tetragon/**"
  - "talos/patches/controlplane.yaml"
---

# Monitoring & Observability

## Scheduler Dashboard Gotchas
- **"No data" has two independent causes**:
  1. Scheduler not reachable: on Talos control planes, `kube-scheduler` may run with `--bind-address=127.0.0.1`; Prometheus scrapes on `:10259` fail with `connection refused`
  2. Dashboard query filtering: dashboard JSON filters by `cluster="$cluster"` while metrics have no `cluster` label
- **Permanent scheduler metrics fix**: set `cluster.scheduler.extraArgs.bind-address: 0.0.0.0` in `talos/patches/controlplane.yaml`, regenerate controlplane configs, apply to all CP nodes
- **Permanent dashboard fix**: use a repo-managed dashboard JSON without the `$cluster` variable/matchers; wire via `configMapGenerator` with `grafana_dashboard: "1"` and `disableNameSuffixHash: true`
- **Verify quickly**: `sum(up{job="kube-scheduler"})` should be `3`; `count({__name__=~"scheduler_.*",job="kube-scheduler"})` should be non-zero
- **Grafana sidecar import verification**: check `deploy/monitoring-grafana` container `grafana-sc-dashboard` logs for `Writing /tmp/dashboards/<dashboard>.json`
