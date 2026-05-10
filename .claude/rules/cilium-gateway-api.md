---
paths:
  - "kubernetes/bootstrap/cilium/**"
  - "kubernetes/**/gateway-api/**"
  - "talos/patches/controlplane.yaml"
---

# Cilium CNI & Gateway API

## Cilium Manifest
- Location: `kubernetes/bootstrap/cilium/cilium.yaml` (~1686 lines)
- Referenced via `extraManifests` URL in `talos/patches/controlplane.yaml`
- Cilium stays under `bootstrap/` — CNI must exist before ArgoCD can run
- **Repo must be public** (or accessible from nodes) for extraManifests URL to work

## Gateway API
- Cilium is the Gateway API implementation (embedded Envoy in cilium-agent)
- Gateway API CRDs (v1.2.1 experimental channel) installed via `extraManifests` — must appear **before** Cilium URL (CRDs must exist before Cilium watches them)
- Enabled via `enable-gateway-api: "true"` in Cilium ConfigMap + RBAC in cilium-operator ClusterRole
- Cilium auto-creates `cilium` GatewayClass
- For each Gateway: creates `cilium-gateway-<name>` CiliumEnvoyConfig + ClusterIP Service + EndpointSlice (**NOT a Deployment** — Cilium 1.19 does not create per-Gateway Deployments)
- The CiliumEnvoyConfig has `nodeSelector` matching `gatewayAPI.hostNetwork.nodes.matchLabels` — only agents on matching nodes process the listener
- Gateway resource in `kubernetes/overlays/<overlay>/infrastructure/gateway-api/resources/` (own ArgoCD Application, project: infrastructure, sync-wave: 4, overlay name from `cluster.yaml`)

## Cilium Envoy Mode
- **Current mode**: `envoy.enabled: false` (embedded Envoy in cilium-agent), `external-envoy-proxy: "false"`
- **hostNetwork mode**: `gatewayAPI.hostNetwork.enabled: true` — embedded Envoy binds on `0.0.0.0:80/443` via host network on labeled worker nodes (`node-role.kubernetes.io/gateway`)
- **Required capabilities**: `NET_BIND_SERVICE` in ciliumAgent + `envoy.securityContext.capabilities.keepCapNetBindService: true` — without both, privileged port binding silently fails
- **Known bug** [cilium/cilium#42786]: Gateway shows `Programmed: False` with hostNetwork (ClusterIP Service gets no addresses); traffic routing still works despite the status
- **WAN ingress path** (since 2026-04-17): FritzBox TCP/443 → `node-pi-01` (hostNetwork nginx stream, SNI allowlist `*.homelab.ntbc.io`) → LAN to gateway nodes (`node-04/05/06`) → hostNetwork Envoy → HTTPRoutes. No macvlan in the WAN path — macvlan+FritzBox port-forward is structurally unsupported on FRITZ!OS ≥ 8.25 (see `docs/adr-pi-sole-public-ingress.md`).
- **LAN ingress path**: `ingress-front` macvlan (stable-MAC LAN VIP) → nginx L4 stream upstream via `net1` to a remote gateway worker node → arrives as external LAN traffic (no eBPF identity marking) → embedded Envoy → HTTPRoutes. macvlan bridge-isolation prevents the pod from reaching its own node's LAN IP; nginx upstream failover routes around it.
- **Internal traffic**: pod → Gateway ClusterIP → eBPF TPROXY → embedded Envoy (identity-marked; works for pods without restrictive CNPs)

## Routing Pattern
- GatewayClass → Gateway → HTTPRoute
- **HARD CONSTRAINT: Gateway API only, NO Ingress** — no Ingress resources or Ingress controllers

## ArgoCD Sync — Gateway API Gotchas
- Gateway API webhook auto-defaults fields (e.g., `group: ""` on certificateRefs, `matches: [{path: {type: PathPrefix, value: /}}]` on HTTPRoutes) — always include these explicitly in manifests to prevent perpetual OutOfSync drift
- HTTP listener uses `from: Same` (redirect HTTPRoute is same namespace as Gateway); HTTPS listener uses `from: Selector` with `edge-public: "true"` label
- Bootstrap cilium manifest (`kubernetes/bootstrap/cilium/cilium.yaml`) includes GatewayClass — reconcile drift with `make -C talos upgrade-k8s` (re-applies extraManifests), NOT `kubectl apply`
- `gateway-api` is its own ArgoCD Application (project: `infrastructure`, sync-wave: 4, destination: `default` namespace) — not managed by the main infrastructure Application
