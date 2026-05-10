# Cilium Policy Debug: Monitoring — 2026-03-03

## Evidence

Three categories of policy drops observed via `hubble observe -n monitoring --verdict DROPPED`:

### 1. Alertmanager mesh UDP gossip (HIGH)

```
alertmanager-*-1:9094 <> alertmanager-*-0:9094 (ID:24926) Policy denied DROPPED (UDP)
alertmanager-*-1:9094 <> alertmanager-*-2:9094 (ID:24926) Policy denied DROPPED (UDP)
```

Continuous drops between all alertmanager replicas on UDP 9094. Alertmanager uses HashiCorp memberlist for cluster gossip which requires both TCP and UDP on port 9094.

**Affected identity**: 24926 (alertmanager pods)

### 2. Prometheus -> Alertmanager config-reloader (MEDIUM)

```
prometheus-*-1:38574 <> alertmanager-*-1:8080 (ID:24926) Policy denied DROPPED (TCP Flags: SYN)
prometheus-*-0:60646 <> alertmanager-*-1:8080 (ID:24926) Policy denied DROPPED (TCP Flags: SYN)
```

Both Prometheus replicas fail to scrape the alertmanager config-reloader sidecar on port 8080. The ServiceMonitor `monitoring-kube-prometheus-alertmanager` defines two endpoints: `http-web` (9093) and `reloader-web` (8080). The CNP only allowed 9093 from prometheus.

**Affected identity**: 9501 (prometheus) -> 24926 (alertmanager)

### 3. Alloy -> stats.grafana.org telemetry (LOW)

```
alloy-fknpt:38492 <> 34.96.126.106:443 (world) Policy denied DROPPED (TCP Flags: SYN)
```

Alloy's built-in usage reporting to `stats.grafana.org` (34.96.126.106, Google-hosted) is correctly blocked. Logs confirm: `"failed to send usage report"` retrying indefinitely.

**Affected identity**: 37912 (alloy)

## Root Causes

| # | Root Cause | File |
|---|-----------|------|
| 1 | Alertmanager CNP mesh rules only had `protocol: TCP` for port 9094; memberlist gossip requires UDP too | `cnp-alertmanager.yaml` |
| 2 | Alertmanager CNP ingress from prometheus only allowed port 9093; config-reloader sidecar serves metrics on 8080 | `cnp-alertmanager.yaml` |
| 3 | Alloy usage reporting enabled by default; no egress rule (correct) but generates constant drop noise | `alloy/values.yaml` |

## Patches Applied

### cnp-alertmanager.yaml

- **Ingress**: Added `port: "8080" / TCP` from prometheus (config-reloader scrape)
- **Ingress + Egress mesh**: Added `port: "9094" / UDP` alongside existing TCP rule

### alloy/values.yaml

- Added `alloy.extraArgs: ["--disable-reporting"]` to suppress telemetry egress

## Validation Commands

After ArgoCD syncs (or force refresh):

```bash
# Verify alertmanager mesh gossip (should show FORWARDED, not DROPPED)
KUBECONFIG=/tmp/homelab-kubeconfig kubectl -n kube-system exec ds/cilium -- \
  hubble observe -n monitoring -l app.kubernetes.io/name=alertmanager --port 9094 --protocol UDP --last 20

# Verify prometheus -> alertmanager:8080 (should show FORWARDED)
KUBECONFIG=/tmp/homelab-kubeconfig kubectl -n kube-system exec ds/cilium -- \
  hubble observe -n monitoring --to-port 8080 --last 20

# Verify no more alloy -> world drops
KUBECONFIG=/tmp/homelab-kubeconfig kubectl -n kube-system exec ds/cilium -- \
  hubble observe -n monitoring -l app.kubernetes.io/name=alloy --verdict DROPPED --last 20

# Verify alloy no longer logs usage report failures
KUBECONFIG=/tmp/homelab-kubeconfig kubectl -n monitoring logs -l app.kubernetes.io/name=alloy --tail=20 | grep "usage report"

# Confirm alertmanager cluster is healthy (all members visible)
KUBECONFIG=/tmp/homelab-kubeconfig kubectl -n monitoring exec alertmanager-monitoring-kube-prometheus-alertmanager-0 -c alertmanager -- \
  wget -q -O- http://localhost:9093/api/v2/status | jq '.cluster'
```
