# Tetragon Runtime Security Observability — Deployment Verification

This document provides step-by-step verification procedures for the Tetragon deployment. Use this guide to validate the deployment meets all acceptance criteria and functions correctly.

## Overview

Tetragon provides kernel-level runtime security observability through eBPF, capturing:
- Process execution events in privileged namespaces
- Sensitive file access (credentials, SSH keys, service account tokens)
- External network connections from security-critical workloads

**Expected Resource Overhead:** <1% CPU per node (verified in production deployments)

---

## Pre-Deployment Checklist

Before ArgoCD sync, verify the following files exist:

```bash
# Namespace configuration
grep -A15 'name: tetragon' kubernetes/overlays/homelab/infrastructure/namespaces-psa.yaml

# ArgoCD Application
test -f kubernetes/overlays/homelab/infrastructure/tetragon/application.yaml && echo "OK"

# Base Helm values
test -f kubernetes/base/infrastructure/tetragon/values.yaml && echo "OK"

# TracingPolicy CRDs
test -f kubernetes/overlays/homelab/infrastructure/tetragon/resources/tracingpolicy-process-exec.yaml && echo "OK"
test -f kubernetes/overlays/homelab/infrastructure/tetragon/resources/tracingpolicy-file-access.yaml && echo "OK"
test -f kubernetes/overlays/homelab/infrastructure/tetragon/resources/tracingpolicy-network-connect.yaml && echo "OK"

# CiliumNetworkPolicy
test -f kubernetes/overlays/homelab/infrastructure/tetragon/resources/cnp-tetragon.yaml && echo "OK"

# Grafana dashboard
test -f kubernetes/overlays/homelab/infrastructure/tetragon/resources/grafana-dashboard.yaml && echo "OK"

# Kustomize build validation
kubectl kustomize kubernetes/overlays/homelab/ >/dev/null 2>&1 && echo "Build OK"
```

---

## Deployment Verification (Post-Sync)

### Step 1: ArgoCD Application Health

**Objective:** Confirm ArgoCD successfully synced all Tetragon resources.

```bash
# Check Application status
kubectl get application tetragon -n argocd -o jsonpath='{.status.sync.status}' && echo
# Expected: Synced

kubectl get application tetragon -n argocd -o jsonpath='{.status.health.status}' && echo
# Expected: Healthy

# View detailed sync result
kubectl get application tetragon -n argocd -o yaml | grep -A30 'status:'
```

**Acceptance Criteria:**
- [ ] Application sync status: `Synced`
- [ ] Application health status: `Healthy`
- [ ] No errors in `status.conditions`

---

### Step 2: Namespace and PSA Configuration

**Objective:** Verify namespace created with correct Pod Security Admission and PNI labels.

```bash
# Check namespace exists
kubectl get namespace tetragon

# Verify PSA labels
kubectl get namespace tetragon -o yaml | grep -E 'pod-security.kubernetes.io/(enforce|audit|warn)'
# Expected:
#   pod-security.kubernetes.io/enforce: privileged
#   pod-security.kubernetes.io/audit: privileged
#   pod-security.kubernetes.io/warn: privileged

# Verify PNI labels
kubectl get namespace tetragon -o yaml | grep -E 'platform.io/'
# Expected:
#   platform.io/network-interface-version: v1
#   platform.io/network-profile: privileged
```

**Acceptance Criteria:**
- [ ] Namespace `tetragon` exists
- [ ] PSA enforcement level: `privileged`
- [ ] PNI network profile: `privileged`

---

### Step 3: DaemonSet Rollout Status

**Objective:** Verify Tetragon DaemonSet running on all nodes.

```bash
# Check DaemonSet status
kubectl get daemonset -n tetragon
# Expected: DESIRED = CURRENT = READY = UP-TO-DATE = number of nodes

# Wait for rollout completion (timeout 300s)
kubectl rollout status daemonset/tetragon -n tetragon --timeout=300s
# Expected: daemon set "tetragon" successfully rolled out

# Verify pods running
kubectl get pods -n tetragon -l app.kubernetes.io/name=tetragon -o wide
# Expected: All pods in Running state, spread across all nodes

# Check pod resource requests/limits
kubectl get pods -n tetragon -l app.kubernetes.io/name=tetragon -o jsonpath='{.items[0].spec.containers[0].resources}' | jq .
# Expected:
#   requests: { cpu: "50m", memory: "128Mi" }
#   limits: { cpu: "500m", memory: "512Mi" }
```

**Acceptance Criteria:**
- [ ] DaemonSet `tetragon` exists in `tetragon` namespace
- [ ] One pod running on each node (DESIRED = CURRENT = READY)
- [ ] All pods in `Running` state
- [ ] Resource requests/limits configured correctly

---

### Step 4: TracingPolicy CRDs Deployed

**Objective:** Verify TracingPolicy custom resources created and active.

```bash
# List all TracingPolicies
kubectl get tracingpolicy -A

# Verify process execution policy
kubectl get tracingpolicy process-execution-monitoring -o yaml | grep -A5 'kprobes:'
# Expected: Monitors sys_execve in kube-system, argocd, tetragon namespaces

# Verify file access policy
kubectl get tracingpolicy file-access-monitoring -o yaml | grep -A10 'matchArgs:'
# Expected: Monitors /etc/shadow, /etc/passwd, /var/run/secrets/kubernetes.io, etc.

# Verify network connection policy
kubectl get tracingpolicy network-connection-monitoring -o yaml | grep -A5 'kprobes:'
# Expected: Monitors sys_connect in privileged namespaces

# Check TracingPolicy status (Tetragon >= 1.2.0)
kubectl get tracingpolicy -o jsonpath='{.items[*].metadata.name}' && echo
# Expected: process-execution-monitoring file-access-monitoring network-connection-monitoring
```

**Acceptance Criteria:**
- [ ] TracingPolicy `process-execution-monitoring` exists
- [ ] TracingPolicy `file-access-monitoring` exists
- [ ] TracingPolicy `network-connection-monitoring` exists
- [ ] All policies reference correct namespaces and syscalls

---

### Step 5: ServiceMonitor and Prometheus Integration

**Objective:** Verify Prometheus scraping Tetragon metrics.

```bash
# Check ServiceMonitor exists
kubectl get servicemonitor -n tetragon -l app.kubernetes.io/name=tetragon
# Expected: ServiceMonitor with matching label

# Verify ServiceMonitor configuration
kubectl get servicemonitor -n tetragon -o yaml | grep -A5 'endpoints:'
# Expected: port: metrics (2112), interval: 30s

# Check Prometheus target (from Prometheus UI or API)
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 &
# Open http://localhost:9090/targets and search for "tetragon"
# Expected: Target "tetragon/tetragon/0" with state UP

# Query Tetragon metrics from Prometheus
kubectl exec -n monitoring prometheus-kube-prometheus-stack-prometheus-0 -- \
  wget -qO- 'http://localhost:9090/api/v1/query?query=up{job="tetragon"}' | jq '.data.result'
# Expected: value = [<timestamp>, "1"]

# Verify metrics available
kubectl exec -n monitoring prometheus-kube-prometheus-stack-prometheus-0 -- \
  wget -qO- http://tetragon.tetragon.svc:2112/metrics | grep -c '^tetragon_'
# Expected: >0 (multiple tetragon_* metrics)
```

**Acceptance Criteria:**
- [ ] ServiceMonitor created in `tetragon` namespace
- [ ] Prometheus target `tetragon` showing state `UP`
- [ ] Tetragon metrics (`tetragon_*`) available in Prometheus

---

### Step 6: CiliumNetworkPolicy Validation

**Objective:** Verify network policies applied without blocking legitimate traffic.

```bash
# Check CiliumNetworkPolicy exists
kubectl get ciliumnetworkpolicy -n tetragon
# Expected: cnp-tetragon

# Verify policy selects Tetragon pods
kubectl get ciliumnetworkpolicy cnp-tetragon -n tetragon -o yaml | grep -A3 'endpointSelector:'
# Expected: matchLabels: app.kubernetes.io/name: tetragon

# Check for policy drops (should be zero for Prometheus scraping)
kubectl exec -n kube-system ds/cilium -- \
  cilium-dbg policy get -n tetragon | grep -i drop
# Expected: No drops for port 2112 from monitoring namespace

# Test Prometheus scraping (from Prometheus pod)
kubectl exec -n monitoring prometheus-kube-prometheus-stack-prometheus-0 -- \
  wget -qO- --timeout=5 http://tetragon.tetragon.svc:2112/metrics | head -5
# Expected: Successfully retrieves metrics (HTTP 200)

# Verify DNS egress allowed
kubectl exec -n tetragon -l app.kubernetes.io/name=tetragon -- nslookup kubernetes.default.svc.cluster.local
# Expected: DNS resolution succeeds

# Verify kube-apiserver egress allowed
kubectl logs -n tetragon -l app.kubernetes.io/name=tetragon --tail=50 | grep -i 'connection refused\|timeout'
# Expected: No connection errors to kube-apiserver
```

**Acceptance Criteria:**
- [ ] CiliumNetworkPolicy `cnp-tetragon` exists
- [ ] No policy drops for Prometheus scraping (port 2112)
- [ ] Tetragon pods can reach kube-apiserver
- [ ] Tetragon pods can resolve DNS

**Troubleshooting:**
- If Prometheus scraping fails: Check `kubernetes/overlays/homelab/infrastructure/kube-prometheus-stack/resources/cnp-prometheus.yaml` includes tetragon namespace egress rule
- If DNS fails: Verify `toFQDNs.matchPattern` in cnp-tetragon.yaml

---

### Step 7: Grafana Dashboard Import

**Objective:** Verify Grafana imported Tetragon dashboard via sidecar.

```bash
# Check dashboard ConfigMap exists
kubectl get configmap -n tetragon -l grafana_dashboard="1"
# Expected: tetragon-dashboard ConfigMap

# Verify Grafana sidecar processed dashboard
kubectl logs -n monitoring deploy/monitoring-grafana -c grafana-sc-dashboard | grep -i tetragon
# Expected: "Writing /tmp/dashboards/tetragon-dashboard.json" or similar

# Access Grafana and verify dashboard
kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80 &
# Open http://localhost:3000/dashboards
# Search for "Tetragon Runtime Security"
# Expected: Dashboard appears in list

# Verify dashboard panels show data
# Open dashboard and check:
# - "Tetragon Events by Type" panel shows metrics
# - "Total Events" gauge shows non-zero value (if events occurred)
# - No "No data" errors on panels
```

**Acceptance Criteria:**
- [ ] ConfigMap with label `grafana_dashboard="1"` exists in `tetragon` namespace
- [ ] Grafana sidecar logs show dashboard import
- [ ] Dashboard "Tetragon Runtime Security" visible in Grafana UI
- [ ] Dashboard panels display metrics (no "No data" errors)

**Troubleshooting:**
- If dashboard not imported: Check Grafana sidecar pod logs for errors
- If panels show "No data": Verify Prometheus target is UP (Step 5)

---

### Step 8: Event Validation (TracingPolicy Triggers)

**Objective:** Verify Tetragon capturing events based on TracingPolicies.

```bash
# Generate test process execution event
kubectl run test-proc-exec --image=busybox --restart=Never -n kube-system -- sh -c 'ls -la /etc'
# Wait a few seconds for event to be captured

# Check Tetragon logs for process execution event
kubectl logs -n tetragon -l app.kubernetes.io/name=tetragon --tail=100 | jq 'select(.process_exec != null)'
# Expected: JSON event with process_exec type, namespace=kube-system, binary=/bin/ls

# Generate test file access event
kubectl run test-file-access --image=busybox --restart=Never -n kube-system -- sh -c 'cat /etc/passwd'
# Wait a few seconds

# Check Tetragon logs for file access event
kubectl logs -n tetragon -l app.kubernetes.io/name=tetragon --tail=100 | jq 'select(.process_kprobe != null and .process_kprobe.function_name == "sys_openat")'
# Expected: JSON event with sys_openat, path=/etc/passwd

# Cleanup test pods
kubectl delete pod test-proc-exec -n kube-system --ignore-not-found
kubectl delete pod test-file-access -n kube-system --ignore-not-found
```

**Acceptance Criteria:**
- [ ] Process execution events captured for `sys_execve` in privileged namespaces
- [ ] File access events captured for sensitive paths (`/etc/passwd`, `/etc/shadow`, etc.)
- [ ] Events exported in JSON format to stdout (for Alloy collection)

**Note:** Network connection events require actual external connections from monitored namespaces to validate.

---

### Step 9: Performance Verification (CPU Overhead)

**Objective:** Verify Tetragon CPU overhead <1% per node.

```bash
# Get baseline CPU usage across all nodes (Prometheus query)
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 &

# Query Tetragon CPU usage (30m average)
# Open http://localhost:9090/graph and run query:
# rate(container_cpu_usage_seconds_total{namespace="tetragon",container="tetragon"}[30m])
# Expected: Values < 0.01 (1% of 1 core)

# Alternative: Use kubectl top
kubectl top pods -n tetragon -l app.kubernetes.io/name=tetragon
# Expected: CPU usage < 10m (1% of 1 core) under normal load

# Check for any resource throttling
kubectl describe pods -n tetragon -l app.kubernetes.io/name=tetragon | grep -A5 'Limits:\|Requests:'
# Verify no throttling warnings

# Verify memory usage within limits
kubectl top pods -n tetragon -l app.kubernetes.io/name=tetragon
# Expected: Memory < 512Mi (within limits)
```

**Acceptance Criteria:**
- [ ] Tetragon CPU usage <1% per node (averaged over 30 minutes)
- [ ] Memory usage within limits (< 512Mi)
- [ ] No CPU throttling warnings

**Troubleshooting:**
- If CPU >1%: Check for excessive TracingPolicy event volume; consider narrowing namespace filters
- If memory near limits: Review event buffer configuration in Helm values

---

### Step 10: Logs Export to Alloy/Loki

**Objective:** Verify Tetragon events flowing to Loki via Alloy.

```bash
# Verify export.stdout.enabled in Helm values
kubectl get application tetragon -n argocd -o yaml | grep -A10 'values.yaml'
# Check that base values reference includes export.stdout settings

# Check Tetragon logs format (should be JSON)
kubectl logs -n tetragon -l app.kubernetes.io/name=tetragon --tail=5
# Expected: JSON lines (not plain text)

# Query Loki for Tetragon logs (via Grafana Explore)
# Open Grafana → Explore → Loki datasource
# Query: {namespace="tetragon", app_kubernetes_io_name="tetragon"}
# Expected: Log entries visible

# Verify event types in Loki
# Query: {namespace="tetragon"} |= "process_exec"
# Expected: Process execution events visible in Loki
```

**Acceptance Criteria:**
- [ ] Tetragon logs exported in JSON format to stdout
- [ ] Alloy collecting logs from Tetragon pods
- [ ] Logs visible in Loki via Grafana Explore

**Note:** Alloy must be configured with a scrape config for namespace=tetragon. If logs not appearing in Loki, verify Alloy configuration.

---

## Acceptance Criteria Summary

Use this checklist to confirm deployment meets all requirements:

### Infrastructure
- [ ] **Namespace:** `tetragon` namespace created with privileged PSA and PNI labels
- [ ] **ArgoCD Application:** Synced and Healthy status
- [ ] **DaemonSet:** Running on all nodes (DESIRED = CURRENT = READY)
- [ ] **Resource Overhead:** CPU usage <1% per node, memory within limits

### Security Policies
- [ ] **TracingPolicy CRDs:** 3 policies deployed (process-exec, file-access, network-connect)
- [ ] **CiliumNetworkPolicy:** Applied without blocking Prometheus/DNS/kube-apiserver
- [ ] **PNI Contract:** Namespace labeled with `platform.io/network-profile: privileged`

### Observability
- [ ] **Prometheus Metrics:** ServiceMonitor created, target UP, metrics available
- [ ] **Grafana Dashboard:** Imported via sidecar, panels show data
- [ ] **Loki Logs:** Events exported in JSON format, visible in Loki/Grafana Explore
- [ ] **Event Validation:** Process execution and file access events captured

### Operational
- [ ] **No Policy Drops:** CiliumNetworkPolicy not blocking legitimate traffic
- [ ] **No Errors in Logs:** Tetragon pods running without connection/permission errors
- [ ] **Sync Wave Ordering:** Application deployed at correct wave (sync-wave: 4)

---

## Troubleshooting Guide

### Issue: DaemonSet Pods CrashLoopBackOff

**Symptoms:**
```bash
kubectl get pods -n tetragon
# NAME           READY   STATUS             RESTARTS   AGE
# tetragon-xxx   0/1     CrashLoopBackOff   5          3m
```

**Resolution:**
1. Check pod logs:
   ```bash
   kubectl logs -n tetragon -l app.kubernetes.io/name=tetragon --previous
   ```
2. Common causes:
   - Missing PSA `privileged` label → Verify Step 2
   - Insufficient permissions → Check RBAC (should be in Helm chart)
   - Kernel version incompatibility → Tetragon requires kernel >=4.19

---

### Issue: Prometheus Target Down

**Symptoms:**
- Prometheus UI shows tetragon target with state `DOWN`
- Grafana dashboard panels show "No data"

**Resolution:**
1. Verify ServiceMonitor selector matches Service:
   ```bash
   kubectl get svc -n tetragon -l app.kubernetes.io/name=tetragon
   kubectl get servicemonitor -n tetragon -o yaml | grep -A5 selector
   ```
2. Test metrics endpoint directly:
   ```bash
   kubectl exec -n tetragon -l app.kubernetes.io/name=tetragon -- wget -qO- localhost:2112/metrics | head
   ```
3. Check CiliumNetworkPolicy allows Prometheus ingress (Step 6)

---

### Issue: No Events Captured

**Symptoms:**
- Tetragon logs show no `process_exec` or `process_kprobe` events
- Grafana dashboard shows zero events

**Resolution:**
1. Verify TracingPolicies applied:
   ```bash
   kubectl get tracingpolicy -A
   ```
2. Check TracingPolicy namespace selectors match target pods:
   ```bash
   kubectl get tracingpolicy process-execution-monitoring -o yaml | grep -A10 podSelector
   ```
3. Trigger test event manually (Step 8)
4. Check Tetragon agent status:
   ```bash
   kubectl logs -n tetragon -l app.kubernetes.io/name=tetragon | grep -i 'tracingpolicy\|started'
   ```

---

### Issue: High CPU Usage (>1%)

**Symptoms:**
```bash
kubectl top pods -n tetragon
# NAME           CPU(cores)   MEMORY(bytes)
# tetragon-xxx   25m          256Mi    # >1% of 1 core
```

**Resolution:**
1. Review TracingPolicy event volume:
   ```bash
   kubectl logs -n tetragon -l app.kubernetes.io/name=tetragon --tail=100 | jq -r '.process_exec.process.pod.namespace' | sort | uniq -c
   ```
2. Consider narrowing namespace filters in TracingPolicies
3. Adjust event buffer size in Helm values if events being dropped
4. Verify no runaway processes in monitored namespaces

---

## Post-Deployment Actions

After successful verification:

1. **Commit verification results** to build-progress.txt:
   ```bash
   echo "## $(date +%Y-%m-%d) - Tetragon Deployment Verified" >> .auto-claude/specs/004-deploy-tetragon-runtime-security-observability/build-progress.txt
   echo "- All acceptance criteria validated" >> .auto-claude/specs/004-deploy-tetragon-runtime-security-observability/build-progress.txt
   echo "- CPU overhead: <1% (measured via kubectl top)" >> .auto-claude/specs/004-deploy-tetragon-runtime-security-observability/build-progress.txt
   ```

2. **Update BACKLOG.md** to mark task complete:
   ```bash
   # Mark item as [x] in BACKLOG.md
   ```

3. **Monitor for 24 hours**:
   - Check Grafana dashboard daily for anomalies
   - Review Loki logs for unexpected events
   - Verify no performance degradation on nodes

4. **Document any custom TracingPolicies** added after initial deployment

---

## Reference

- **Tetragon Documentation:** https://tetragon.io/docs/
- **TracingPolicy Examples:** https://github.com/cilium/tetragon/tree/main/examples/tracingpolicy
- **Helm Chart Values:** https://github.com/cilium/tetragon/blob/main/install/kubernetes/tetragon/values.yaml
- **CLAUDE.md Gotchas:** See project CLAUDE.md for Cilium/Tetragon operational notes
