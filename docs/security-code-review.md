# Security Code Review

Date: 2026-03-01  
Reviewer: Staff Engineer / Principal Architect (Kubernetes, CI/CD, Security)  
Scope: `kubernetes/`, `talos/`, root `Makefile`, GitOps control path

## Executive Summary

Security posture improved materially since the initial baseline. Major GitOps governance gaps (wildcard AppProject scope, mutable revisions, root app in `default` project, dead cert-approver source URL) were remediated.

Current top risks are now concentrated in:

1. Argo repo-server executable kustomize plugin mode.
2. etcd metrics exposure (`0.0.0.0:2381` over HTTP).
3. Argo internal HTTP mode (`server.insecure: true`).
4. Broad Gateway route attachment (`from: All`).
5. Local plaintext Talos secret intermediate workflow.
6. Missing CI security gates.

Overall risk rating: **Medium-High** (improved from prior High baseline).

## Confirmed Remediations

- AppProject scope hardened (destinations and cluster resource allowlists constrained).
- Root app moved from `default` to dedicated constrained `root-bootstrap` project.
- Argo Git and chart revisions pinned (no `HEAD` or wildcard chart ranges in active app specs).
- Cert-manager secret structure normalized (metadata plaintext, secret payload encrypted).
- Kubelet serving cert approver source fixed (dead chart repo replaced with upstream Git source).
- Talos `extraManifests` no longer manages cert-approver/metrics-server (single Argo ownership path).

## Active Findings

## High

### 1) Argo repo-server allows executable plugin rendering

Evidence:
- [kubernetes/base/infrastructure/argocd/values.yaml](../kubernetes/base/infrastructure/argocd/values.yaml#L59)

Risk:
- Manifest render path can execute binaries if trusted source boundaries are violated.

Recommendation:
- Remove `--enable-exec`, or isolate repo-server with strict node/SA/egress controls if unavoidable.

### 2) etcd metrics exposed on plaintext all-interfaces bind

Evidence:
- [talos/patches/controlplane.yaml](../talos/patches/controlplane.yaml#L8)

Risk:
- Increases control-plane telemetry exposure for internal reconnaissance.

Recommendation:
- Bind to loopback/management interface and enforce network segmentation.

## Medium

### 3) Argo server runs in insecure mode behind edge TLS

Evidence:
- [kubernetes/base/infrastructure/argocd/values.yaml](../kubernetes/base/infrastructure/argocd/values.yaml#L46)

Risk:
- In-cluster traffic to Argo server remains HTTP.

Recommendation:
- Prefer end-to-end TLS, or enforce strict in-cluster network access controls.

### 4) Shared Gateway allows routes from any namespace

Evidence:
- [kubernetes/overlays/homelab/infrastructure/gateway-api/gateway.yaml](../kubernetes/overlays/homelab/infrastructure/gateway-api/gateway.yaml#L12)
- [kubernetes/overlays/homelab/infrastructure/gateway-api/gateway.yaml](../kubernetes/overlays/homelab/infrastructure/gateway-api/gateway.yaml#L23)

Risk:
- Weak tenant boundary at ingress layer.

Recommendation:
- Restrict via namespace selector/policy and explicit route admission boundaries.

### 5) Talos secret generation writes decrypted intermediate file

Evidence:
- [talos/Makefile](../talos/Makefile#L50)

Risk:
- Workstation compromise or backup leakage can expose bootstrap secrets.

Recommendation:
- Switch to ephemeral secure temp handling (`umask 077`, trap cleanup, pipe/process-substitution where possible).

## Low

### 6) Root app finalizer missing

Evidence:
- [kubernetes/bootstrap/argocd/root-application.yaml](../kubernetes/bootstrap/argocd/root-application.yaml#L3)

Risk:
- Deleting root app can orphan child resources.

Recommendation:
- Add `resources-finalizer.argocd.argoproj.io`.

### 7) CI security controls not codified in repository

Evidence:
- No in-repo CI workflow files for policy/schema/security checks.

Risk:
- Regressions can merge without automated guardrails.

Recommendation:
- Add mandatory PR gates for render/schema validation, policy-as-code, secret scanning, and IaC checks.

## Priority Remediation Order

1. Disable/contain Argo `--enable-exec`.  
2. Restrict etcd metrics exposure.  
3. Tighten Argo internal transport model.  
4. Restrict Gateway route attachment scope.  
5. Remove decrypted Talos secret intermediate persistence.  
6. Add CI security gates.
