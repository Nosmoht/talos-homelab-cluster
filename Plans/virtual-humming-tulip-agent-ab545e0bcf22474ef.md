# ArgoCD GitOps Review: virtual-humming-tulip Plan

## 1. Deletion of L2 Announcement and IP Pool Resources

### Where These Resources Live

The four resources targeted for deletion are all in the **root app's** gateway-api kustomization, NOT in a child Application:

- `kubernetes/overlays/homelab/infrastructure/gateway-api/kustomization.yaml` lists:
  - `cilium-ip-pool.yaml` (CiliumLoadBalancerIPPool `homelab-pool`)
  - `cilium-ui-ip-pool.yaml` (CiliumLoadBalancerIPPool `homelab-ui-pool`)
  - `cilium-l2-announcement.yaml` (CiliumL2AnnouncementPolicy `homelab-l2`)
  - `cilium-l2-announcement-ui.yaml` (CiliumL2AnnouncementPolicy `homelab-ui-l2`)

These are raw resources rendered directly by the `root` Application (project: `root-bootstrap`). The root app has `prune: true` in its syncPolicy.

### Pruning Analysis

**Will pruning work?** Yes, with one caveat.

- The `root-bootstrap` AppProject explicitly whitelists both `CiliumLoadBalancerIPPool` and `CiliumL2AnnouncementPolicy` in `clusterResourceWhitelist`. ArgoCD can manage them.
- Root app has `prune: true` + `selfHeal: true`, so removing the files from git and the references from `kustomization.yaml` will trigger automatic deletion.
- **Finalizer risk: LOW.** Cilium CRDs (`CiliumLoadBalancerIPPool`, `CiliumL2AnnouncementPolicy`) do not have built-in finalizers by default. Pruning should complete immediately.

**Recommendation:** The plan should explicitly state that BOTH the yaml files AND the kustomization.yaml references must be removed in the same commit. Otherwise, removing only the files but keeping the references would break the kustomize build entirely. The plan implies this but does not state it.

### Sequencing Concern

The plan removes L2 announcement and IP pool (Step 4) BEFORE the ingress-front pod is confirmed working (Step 3). This creates a **window of total external inaccessibility**:

- If Steps 0-3 fail or are delayed, removing the L2 resources in Step 4 kills the current working path (Cilium L2 on 192.168.2.70) with no fallback.
- **Recommendation:** Step 4 should only be executed after Step 3 is verified working end-to-end. The plan's numbered steps suggest sequential execution, but this dependency should be an explicit gate: "Do NOT commit Step 4 until Step 3 verification passes."

## 2. Service Type Change (LoadBalancer to ClusterIP)

### Dex Service (Helm-managed)

The Dex Service is managed by the `dex` Helm chart via the `dex` Application CR (project: `infrastructure`). The service type is set via `values.yaml`:
```yaml
service:
  type: LoadBalancer
  loadBalancerIP: 192.168.2.131
```

Changing to `type: ClusterIP` and removing `loadBalancerIP` is a **clean Helm values change**. The chart will template the Service with `type: ClusterIP` and no `loadBalancerIP` field. Since the `dex` Application uses `ServerSideApply=true`, this will work without issues -- SSA handles type transitions cleanly by replacing the managed fields.

**Potential issue:** After the type changes, the Service object may retain a stale `status.loadBalancer.ingress` entry until Cilium's LB controller cleans it up. This is cosmetic and resolves on its own. No ArgoCD impact because ArgoCD does not diff `status` fields.

**Verdict: CLEAN.** No immutable field issues. No action needed.

### OAuth2-Proxy Services (raw manifests, kube-prometheus-stack resources/)

The Prometheus and Alertmanager oauth2-proxy Services are raw manifests in `kube-prometheus-stack/resources/`. Changing `type: LoadBalancer` to `type: ClusterIP` and removing `loadBalancerIP` is straightforward since these are managed via `ServerSideApply=true` on the `kube-prometheus-stack` Application.

**Verdict: CLEAN.** Same reasoning as Dex. SSA handles the transition.

### Removing `homelab.local/expose: "true"` Label

The `homelab-ui-l2` CiliumL2AnnouncementPolicy and `homelab-ui-pool` CiliumLoadBalancerIPPool both use `serviceSelector.matchLabels: homelab.local/expose: "true"`. Since both the label removal (from Services) and the resource deletion (L2 policy + IP pool) happen in the same plan, the order matters:

- If the L2 resources are deleted BEFORE the label is removed from Services, no issue (the selectors have nothing to match anyway once deleted).
- If the label is removed BEFORE the L2 resources are deleted, no issue either (the Services won't match the selector anymore).
- **Both safe.** But best practice: remove both in the same commit to avoid transient states.

## 3. New Resources in gateway-api (Root App)

### Current Structure

`gateway-api` is NOT a child Application. It is a directory of raw resources (`kustomization.yaml` + individual yaml files) referenced by the infrastructure kustomization, which is referenced by the root overlay kustomization. All gateway-api resources are rendered and managed by the `root` Application.

The current kustomization uses flat files -- there is no `resources/` subdirectory:
```
gateway-api/
  kustomization.yaml    # lists: gateway.yaml, certificate.yaml, etc.
  gateway.yaml
  cilium-ip-pool.yaml
  ...
```

### Plan's Proposed Structure

The plan creates new files in `gateway-api/resources/`:
- `resources/net-attach-def.yaml`
- `resources/ingress-front.yaml`
- `resources/cnp-ingress-front.yaml`

### CRITICAL ISSUE: Kustomize Reference Compatibility

The plan says to add resources to `gateway-api/kustomization.yaml` or "create a `resources/kustomization.yaml`". This needs to be precise:

**Option A: Add files directly to gateway-api/ (no subdirectory)**
- Add `net-attach-def.yaml`, `ingress-front.yaml`, `cnp-ingress-front.yaml` to `gateway-api/`
- Add them to `gateway-api/kustomization.yaml` resources list
- This is consistent with the existing pattern and works immediately.

**Option B: Create a resources/ subdirectory with its own kustomization.yaml**
- Create `gateway-api/resources/kustomization.yaml` listing the new files
- Add `- resources` to `gateway-api/kustomization.yaml`
- This works but creates a structural inconsistency: gateway-api is the only non-Application component with a `resources/` dir. The `resources/` pattern is used by child Applications that have a multi-source setup (Helm + resources path). Since gateway-api has no Application CR, there is no Helm source to complement -- the `resources/` naming would be misleading.

**Recommendation:** Use Option A (flat files in `gateway-api/`). It matches the existing pattern and avoids confusion with the `resources/` convention used by child Applications.

### AppProject Permissions for Root App

The `root-bootstrap` AppProject currently allows:
- `gateway.networking.k8s.io` kinds (Gateway, HTTPRoute, TLSRoute, BackendTLSPolicy)
- `cilium.io` kinds (CiliumLoadBalancerIPPool, CiliumL2AnnouncementPolicy, CiliumGatewayClassConfig)
- `argoproj.io` kinds (AppProject, Application)
- `cert-manager.io` kinds (Certificate)
- Core namespace: `default`, `argocd`

**The new resources have AppProject permission problems:**

1. **NetworkAttachmentDefinition** (`k8s.cni.cncf.io/v1`, namespaced, namespace: `default`):
   - Group `k8s.cni.cncf.io` is NOT in `root-bootstrap` namespaceResourceWhitelist.
   - The whitelist only allows `argoproj.io`, `gateway.networking.k8s.io`, `cert-manager.io`, and `cilium.io` kinds.
   - **This will fail with a permission denied error during sync.**

2. **Deployment** (`apps/v1`, namespaced, namespace: `default`):
   - Group `apps` / kind `Deployment` is NOT in `root-bootstrap` namespaceResourceWhitelist.
   - **This will fail.**

3. **ConfigMap** (`v1`, namespaced, namespace: `default`):
   - Group `""` / kind `ConfigMap` is NOT in `root-bootstrap` namespaceResourceWhitelist.
   - **This will fail.**

4. **CiliumNetworkPolicy** (`cilium.io/v2`, namespaced, namespace: `default`):
   - Group `cilium.io` is NOT in `root-bootstrap` namespaceResourceWhitelist. Only `CiliumGatewayClassConfig` is listed, and that is in `clusterResourceWhitelist`, not namespaced.
   - Wait -- let me re-check. `CiliumGatewayClassConfig` is in `namespaceResourceWhitelist` (line 44 of root-bootstrap.yaml), and it is listed by specific kind. CiliumNetworkPolicy is a different kind.
   - **This will fail.**

### CRITICAL FINDING: root-bootstrap AppProject Must Be Updated

The `root-bootstrap` AppProject needs additions to `namespaceResourceWhitelist` for:
- `{ group: "k8s.cni.cncf.io", kind: "NetworkAttachmentDefinition" }`
- `{ group: "apps", kind: "Deployment" }`
- `{ group: "", kind: "ConfigMap" }`
- `{ group: "", kind: "Service" }` (if ingress-front needs a Service)
- `{ group: "cilium.io", kind: "CiliumNetworkPolicy" }`

**Alternatively**, these resources should NOT be in the root app at all. A cleaner approach would be to create a proper child Application for ingress-front (similar to how multus-cni has its own Application CR under `infrastructure`). This would:
- Keep the root app lean (only AppProjects, Application CRs, gateway-api resources, namespaces)
- Put the Deployment/ConfigMap/CNP under the `infrastructure` AppProject, which already has `namespaceResourceWhitelist: [{ group: "*", kind: "*" }]`
- Only the NetworkAttachmentDefinition needs to be in the right namespace/destination -- the `infrastructure` AppProject allows `default` namespace.

**Strong recommendation:** Do NOT expand `root-bootstrap` permissions for workload resources (Deployments, ConfigMaps). Create a child Application CR for `ingress-front` under `infrastructure/`, following the existing multus-cni pattern. This preserves the architectural principle that the root app only manages ArgoCD meta-resources and gateway-api primitives.

## 4. Sync Wave Ordering

### Current Waves
From the files read:
- Wave -1: AppProjects (projects/kustomization.yaml commonAnnotations), multus-cni Application
- Wave 0: most infrastructure Application CRs (default)
- Wave 3: dex Application
- Wave 4: kube-prometheus-stack Application
- Wave 8: gateway-api resources (commonAnnotations in gateway-api/kustomization.yaml)

### Dependency Chain for ingress-front

The ingress-front pod requires:
1. **Multus DaemonSet running** -- managed by `multus-cni` Application (wave -1). DaemonSet pods must be ready.
2. **NetworkAttachmentDefinition exists** -- must be created BEFORE the pod that references it.
3. **Cilium gateway Service exists** -- `cilium-gateway-homelab-gateway` is auto-created by Cilium when the Gateway resource is applied. The Gateway is at wave 8.

### Wave Analysis

If ingress-front resources are added to gateway-api (wave 8):
- The NetworkAttachmentDefinition and the Deployment would both get wave 8 via `commonAnnotations`.
- **Within the same wave**, ArgoCD applies resources in a deterministic order by kind: Namespaces first, then CRDs, then other resources. The specific order within the same wave for same-kind resources is not guaranteed, but across different kinds, ArgoCD follows the built-in kind priority list. `NetworkAttachmentDefinition` (custom resource) would likely be applied alongside the Deployment -- but the Multus webhook/controller processes the NAD independently of the pod creation.
- **The real dependency is on Multus running**, which is wave -1. By wave 8, Multus will be healthy.
- **The Cilium gateway Service** is created by the Cilium operator in response to the Gateway resource. The Gateway is wave 8. If the ingress-front Deployment is also wave 8, there could be a race: the Gateway and Deployment are applied in the same wave, but the Cilium operator needs time to create the `cilium-gateway-homelab-gateway` Service.

### Timing Risk

The nginx upstream in the ConfigMap references `cilium-gateway-homelab-gateway.default.svc`. If this Service does not exist when nginx starts, DNS resolution fails. However:
- nginx `stream` mode resolves upstreams at connection time, not at startup (unlike `http` upstream blocks).
- Actually, that is not quite right. nginx stream `proxy_pass` with a DNS name resolves at config load time by default. If the Service does not exist yet, nginx will fail to start with "host not found in upstream."

**Mitigation options:**
1. Add a `resolver` directive to the nginx stream config and use a variable for the upstream to force runtime resolution.
2. Give the ingress-front Deployment a higher sync-wave annotation (e.g., wave 9) so it deploys AFTER the Gateway and its auto-created Service.
3. Use an init container that waits for the Service DNS to resolve.

**Recommendation:** Option 2 is the simplest and most GitOps-native. Add `argocd.argoproj.io/sync-wave: "9"` directly on the ingress-front Deployment (overriding the gateway-api commonAnnotations of "8"). The NAD and CNP can stay at wave 8.

Actually, if using the child Application approach from finding #3, the Application CR's sync-wave controls when ArgoCD starts syncing it. Set the ingress-front Application CR to wave 9 and it deploys after wave 8 (gateway-api).

## 5. AppProject Permissions for NetworkAttachmentDefinition

### Is NetworkAttachmentDefinition Cluster-Scoped or Namespaced?

`NetworkAttachmentDefinition` from `k8s.cni.cncf.io/v1` is **namespaced**. The plan puts it in `namespace: default`.

### Which AppProject Needs the Permission?

**If added to root app (gateway-api directory):** `root-bootstrap` needs `{ group: "k8s.cni.cncf.io", kind: "NetworkAttachmentDefinition" }` in `namespaceResourceWhitelist`.

**If using a child Application (recommended):** The `infrastructure` AppProject already has `namespaceResourceWhitelist: [{ group: "*", kind: "*" }]` -- this allows ALL namespaced resources. No changes needed to the infrastructure AppProject. The infrastructure AppProject also has `{ namespace: default, server: ... }` in destinations. So a child Application under `infrastructure` project targeting `default` namespace would work out of the box.

**Verdict:** The child Application approach (recommended in #3) eliminates all AppProject permission concerns.

---

## Summary of Findings

| # | Finding | Severity | Recommendation |
|---|---------|----------|----------------|
| 1 | L2/IP pool deletion via pruning will work correctly | OK | Ensure file removal + kustomization.yaml update in same commit |
| 2 | Step 4 deletion before Step 3 verification creates downtime window | **HIGH** | Gate Step 4 on Step 3 end-to-end verification |
| 3 | Service type LoadBalancer->ClusterIP transitions are clean with SSA | OK | No changes needed |
| 4 | New resources in gateway-api (root app) blocked by root-bootstrap AppProject permissions | **CRITICAL** | Create a child Application for ingress-front under infrastructure/ |
| 5 | nginx DNS resolution race with Cilium gateway Service | **MEDIUM** | Use sync-wave 9 for ingress-front, or use runtime DNS resolution in nginx |
| 6 | `resources/` subdirectory in gateway-api breaks naming convention | **LOW** | Use flat files or child Application pattern instead |
| 7 | NetworkAttachmentDefinition AppProject permission | **CRITICAL** (if root app) / OK (if child app) | Child Application under infrastructure/ resolves this automatically |

### Recommended Architecture Change

Instead of adding Deployment/ConfigMap/CNP/NAD to the gateway-api directory (root app), create:

```
kubernetes/overlays/homelab/infrastructure/ingress-front/
  kustomization.yaml          # resources: [application.yaml]
  application.yaml            # Application CR, project: infrastructure, wave 9
  resources/
    kustomization.yaml        # resources: [deployment.yaml, net-attach-def.yaml, cnp.yaml]
    deployment.yaml           # Deployment + ConfigMap
    net-attach-def.yaml       # NetworkAttachmentDefinition
    cnp-ingress-front.yaml    # CiliumNetworkPolicy
```

Add `- ingress-front` to `kubernetes/overlays/homelab/infrastructure/kustomization.yaml`.

This:
- Follows the established pattern (multus-cni, dex, etc.)
- Uses the `infrastructure` AppProject (already allows `{ group: "*", kind: "*" }` for namespaced resources + `default` namespace destination)
- Avoids expanding `root-bootstrap` permissions
- Enables independent sync-wave control (wave 9 on the Application CR)
- Keeps root app focused on meta-resources
