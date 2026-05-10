# ADR-0002: Tenant Cluster Exposure

**Status**: Accepted  
**Date**: 2026-04-11  
**Issue**: #64 — Tenant exposure model

---

## Context

The homelab cluster hosts KubeVirt-based tenant Kubernetes clusters. These clusters need to:
1. Expose their Services to external clients (ingress path)
2. Communicate with seed cluster APIs for VM lifecycle management (egress path)

The original design considered a shared Cilium Gateway (`.70`) for tenant traffic, reusing the
platform's seed-edge GatewayClass. This ADR rejects that approach and establishes a dedicated
LoadBalancer VIP per tenant.

---

## Decision

### Dedicated VIP per tenant via `cloud-provider-kubevirt` CCM

Each tenant cluster receives a **dedicated LoadBalancer IP** allocated from a tenant-scoped
`CiliumLoadBalancerIPPool`. Services published by `cloud-provider-kubevirt` (CCM) get IPs from
this pool, one IP per Service.

This inverts the original "shared seed-edge" framing:
- **Rejected**: Route tenant traffic through a shared seed Gateway at `192.168.2.70` with
  hostname-based routing. This couples all tenants to the platform GatewayClass, requires
  hostname-ownership enforcement, and creates a shared point of failure.
- **Accepted**: Each tenant's Services are published as `type: LoadBalancer` by CCM. The seed
  cluster assigns a unique IP from the tenant pool. No shared listener; no hostname collision.

### IP pool: `192.168.2.80-91` (mgmt VLAN)

Allocated from the management `/24` (`192.168.2.0/24`). No overlap with:
- API VIP: `.60`
- Node IPs: `.61-.67`
- Gateway VIP (platform): `.70`

Pool capacity: 12 addresses (`.80-.91`). Ceiling: **3 tenants × 4 VIPs** (HTTP + HTTPS ×
admin-tenant + personal-tenant). A 4th tenant requires pool expansion — next candidate:
`192.168.2.92-95` (still in mgmt `/24`); beyond that, carve a new `/28` from a neighbor VLAN.

Addresses `.80-.81` reserved for admin-tenant; `.82-.83` for personal-tenant (PR #4 initial
allocation; adjust in ADR addendum when tenants grow).

### L2 advertisement via `CiliumL2AnnouncementPolicy`

Tenant VIPs are advertised on the management VLAN via the existing Cilium L2 announcement
mechanism — the same native VLAN 1 path used by platform services. No new trunk configuration
needed on the SG3428 for tenant VIP exposure.

Policy binds to nodes labeled `node-role.kubernetes.io/gateway: ""` (existing label on worker
nodes where macvlan `ingress-front` and Envoy hostNetwork already live).

**Spike #7 dependency**: Cilium L2 announcements (`l2announcements.enabled: true`) and
`loadBalancer.l2.enabled: true` are currently **absent** from
`kubernetes/bootstrap/cilium/values.yaml`. Both must be added in PR #3 alongside the
`bpf.vlanBypass` update. Spike #7 produces the empirical feasibility confirmation (arping +
curl from off-cluster host) before PR #4 is drafted.

### Tenant Gateway API resources live inside the tenant cluster

The seed-side object is the CCM-published `Service` (type LoadBalancer with a tenant pool
IP). Gateways, HTTPRoutes, TLS termination, and all routing logic are owned by the tenant
cluster — not the seed. The seed does not route on hostname; it routes on destination IP.

### Tenant VLANs 120/130 via KubeVirt bridge CNI

Tenant VMs are placed on dedicated tagged VLANs:
- VLAN 120 (`admin-tenant`)
- VLAN 130 (`personal-tenant`)

Both carried by `br-vm` bridge (same pattern as existing VLAN 100). Cross-tenant L2 isolation
between VLANs 120 and 130 is enforced by the SG3428 deny-ACL (see §Threat Model).

`bpf.vlanBypass: [100, 110, 120, 130]` — Cilium is bypassed for all bridge-CNI-backed VLANs.
Primary cross-tenant L2 boundary is the SG3428 ACL, not Cilium.

### Tenant kubeconfigs: SOPS-encrypted, minimal RBAC

Each tenant kubeconfig is stored as `*.sops.yaml`. RBAC scope: `list`/`watch` on `Service`,
`Endpoints`, and `EndpointSlice` in a single tenant namespace. Not tenant admin.

---

## VLAN Schema (tenant-relevant subset)

| VLAN ID | Purpose | Members | Subnet | Bridge | `bpf.vlanBypass` |
|---|---|---|---|---|---|
| 1 (native) | Mgmt / control plane | All 7 nodes | `192.168.2.0/24` | — | n/a |
| 100 | KubeVirt VM network (existing) | Workers + GPU | VM-provided | `br-vm` | yes |
| 120 | Tenant admin | Workers + GPU | Tenant-managed | `br-vm` | yes |
| 130 | Tenant personal | Workers + GPU | Tenant-managed | `br-vm` | yes |

---

## Threat Model

### Cross-tenant isolation layers (VLAN 120 ↔ VLAN 130)

Four independent controls:

1. **SG3428 ACL**: `deny ip from vlan 120 to vlan 130` + inverse. Primary L2 boundary.
2. **Dedicated LoadBalancer VIPs**: Each tenant's Services are on distinct IPs. No shared
   listener that could be hijacked by the other tenant.
3. **Cilium WireGuard**: Intra-seed node-to-node traffic is WireGuard-encrypted. A compromised
   pod on one tenant's worker cannot observe another tenant's pod traffic over the seed network.
4. **Kyverno ClusterPolicy** (`ccnp-tenant-vip-label.yaml`): Enforces `platform.io/tenant: <id>`
   and `platform.io/tenant-vip: "true"` labels on tenant-edge Services. Denies cross-tenant
   overlap by validating `platform.io/tenant` uniqueness.

**Accepted residual risk**: In-host bridge traffic is not visible to the SG3428. A VM that
compromises its hypervisor worker can send frames on other VLANs via `br-vm`. `bpf.vlanBypass`
means Cilium does not enforce policy on VLANs 120/130 for in-host traffic. Mitigated by
KubeVirt hypervisor isolation and Kyverno pod-admission policy restricting `spec.hostNetwork`.

### Mgmt VLAN (native VLAN 1)

- SG3428 management IP locked to mgmt VLAN
- Router firewall restricts web-UI/SSH access by source IP
- Audit: quarterly review of access rules

---

## Implementation (files created/modified)

### New components

- `kubernetes/overlays/homelab/infrastructure/cilium-lbipam/`
  - `application.yaml` (ArgoCD, sync-wave 0)
  - `kustomization.yaml`
  - `resources/ciliumloadbalancerippool-tenant.yaml` — pool `192.168.2.80/29` + `192.168.2.88/30`
    with `serviceSelector.matchLabels: { platform.io/tenant-vip: "true" }`
  - `resources/ciliuml2announcementpolicy-tenant.yaml` — binds to `node-role.kubernetes.io/gateway`
    nodes, native VLAN only

- `kubernetes/overlays/homelab/infrastructure/cloud-provider-kubevirt/`
  - `application.yaml` (ArgoCD, sync-wave 0)
  - `kustomization.yaml`
  - `values.yaml` — pinned version, SOPS-encrypted tenant kubeconfig secret reference
  - `tenant-kubeconfig-admin.sops.yaml`

- `kubernetes/overlays/homelab/infrastructure/kubevirt/resources/net-attach-def-vm-vlan120-admin.yaml`
- `kubernetes/overlays/homelab/infrastructure/kubevirt/resources/net-attach-def-vm-vlan130-personal.yaml`

- `kubernetes/overlays/homelab/infrastructure/kyverno/resources/ccnp-tenant-vip-label.yaml`
  - Require `platform.io/tenant: <id>` + `platform.io/tenant-vip: "true"` on tenant-edge Services
  - Deny cross-tenant IP collision

### Modified components

- `kubernetes/bootstrap/cilium/values.yaml`
  - Add `l2announcements.enabled: true`
  - Add `loadBalancer.l2.enabled: true`
  (these are also needed for Spike #7 verification — fold into PR #3 if not already present)

- `docs/platform-network-interface.md`
  - Document `platform.io/consume.tenant-edge` capability
  - Document `platform.io/tenant-vip: "true"` label contract
  - Document tenant VIP pool capacity ceiling

---

## Risk Assessment

| Risk | Likelihood | Severity | Mitigation |
|---|---|---|---|
| `cloud-provider-kubevirt` version incompatibility | Low | High | Pin version explicitly; test in pre-PR |
| Stale endpoint publication by CCM (tenant cluster down) | Medium | Medium | Monitor CCM endpoint health; alert on stale Services |
| Tenant VIP pool exhaustion | Low (current) | Medium | Document ceiling; expand pool in ADR addendum before 4th tenant |
| L2 announcement failure (arping unreachable) | Low | High | Spike #7 gates PR #4; fallback: per-tenant macvlan sidecar (same pattern as `ingress-front`) |
| Kyverno policy timing (label not set before CCM publishes IP) | Low | Low | ClusterPolicy is audit/enforce — wrong-labeled Service rejected at admission |

### Fallback path (if Spike #7 fails)

If Cilium L2 IPAM + announcements cannot be made to work:
- Fall back to **per-tenant macvlan sidecars** with static IPs (same pattern as `ingress-front`
  for platform services). Each tenant gets a macvlan NIC on the mgmt interface with a static IP
  from the tenant pool range.
- This approach has no CCM dependency and does not require L2 announcement enablement.
- Documented here even if not taken, so future operators see the option.

---

## What This Approach Does NOT Provide

- **No shared hostname routing at the seed**: Tenants control their own Gateway/HTTPRoute — the
  seed exposes only a dedicated IP, not a hostname.
- **No cross-tenant pod-network reachability**: Tenant VMs on VLAN 120 cannot reach tenant VMs
  on VLAN 130 at L2 (SG3428 ACL). L3 routing between them is not provided.
- **No Cilium visibility into tenant VLAN frames in-host**: `bpf.vlanBypass` means Hubble does
  not see inter-VM traffic within `br-vm`. Troubleshoot via `kubectl exec` on the VM guest, not
  Hubble.

---

## Alternatives Considered

| Alternative | Reason rejected |
|---|---|
| Shared Cilium Gateway (`.70`) for all tenants | Creates shared point of failure; requires hostname-ownership enforcement; couples tenant L7 routing to seed platform; rejected by `platform-reliability-reviewer` |
| macvlan-only (no CCM) for tenant VIPs | Requires manual IP management per tenant; doesn't integrate with tenant's `type: LoadBalancer` Services; more operational burden at scale |
| KubeVirt bridge without dedicated VLANs (flat L2) | No cross-tenant isolation; rejected by threat model |
| Wireguard overlay between seed and tenant (no L2 adjacency) | Over-engineered for the current tenant count; deferred to a future ADR if tenant clusters grow to multiple sites |

---

## Consequences

- Each tenant receives a dedicated IP per Service (not a shared hostname)
- Tenant Gateways/HTTPRoutes are tenant-cluster-owned (seed has no hostname routing complexity)
- Cross-tenant L2 isolation is enforced at the SG3428 plus Kyverno at admission time
- Cilium L2 announcements and `loadBalancer.l2` must be enabled (currently missing from Cilium values)
- VIP pool capacity ceiling: 12 addresses, 3 tenants × 4 VIPs — document before 4th tenant
- Platform Gateway (`.70`) remains unchanged and is used only for platform services
