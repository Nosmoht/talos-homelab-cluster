# gateway-api (homelab overlay)

Resources for the shared `homelab-gateway` Cilium Gateway, including TLS
certificates and HTTPRoutes managed alongside the Gateway itself.

## Listeners

| Listener | Hostname | TLS Cert | allowedRoutes |
|---|---|---|---|
| `http` | (any) | — | `from: Same` (only the gateway namespace) |
| `https` | (any) | `homelab-wildcard-tls` (Vault internal CA) | `from: All` namespaces |
| `external-https` | `*.homelab.ntbc.io` | `external-wildcard-tls` (Let's Encrypt) | `from: Selector` matching `platform.io/consume.external-gateway-routes=true` |

A single Envoy serves all three listeners. SNI dispatch on `external-https` is
hostname-bound to `*.homelab.ntbc.io`; the listener attaches only HTTPRoutes from
namespaces that carry the `consume.external-gateway-routes` opt-in label.

## Public (WAN) exposure path

Since 2026-04-17 WAN traffic enters via `node-pi-01` (hostNetwork nginx stream),
not via the `ingress-front` macvlan pod. The macvlan-on-pod WAN path was
declared structurally unsupported under FRITZ!OS ≥ 8.25 on 2026-04-15 — see
[docs/adr-pi-sole-public-ingress.md](../../../../../docs/adr-pi-sole-public-ingress.md)
and [docs/2026-04-15-fritzbox-macvlan-port-forward-exhaustion.md](../../../../../docs/2026-04-15-fritzbox-macvlan-port-forward-exhaustion.md).

```
Internet (TCP 443 only)
  -> FritzBox public IP (port-forward TCP/443 → node-pi-01 NIC)
  -> node-pi-01 hostNetwork nginx stream pod
     (SNI allowlist = *.homelab.ntbc.io; L4 proxy)
  -> gateway worker nodes (hostNetwork Envoy on node-04/05/06)
  -> external-https listener (SNI = *.homelab.ntbc.io)
  -> HTTPRoutes from labelled namespaces
```

Port `80` is intentionally NOT forwarded from the WAN. Let's Encrypt issuance uses
DNS-01 (CloudDNS), not HTTP-01, so port 80 is unnecessary. Public clients must use
HTTPS only.

## LAN (internal) ingress path

Internal LAN clients reach services via the `ingress-front` macvlan pod bound
to a stable MAC + LAN VIP — see
[docs/adr-ingress-front-stable-mac.md](../../../../../docs/adr-ingress-front-stable-mac.md)
(superseded for WAN, retained for LAN).

```
LAN client (TCP 443)
  -> ingress-front macvlan VIP (LAN) — stable MAC for router static-bind quality
  -> nginx L4 stream proxy (SNI dispatch)
  -> gateway worker nodes (hostNetwork Envoy) via macvlan to remote node
  -> https or external-https listener (depending on SNI)
  -> HTTPRoutes from labelled namespaces
```

Traffic flowing via the macvlan path arrives at the gateway worker nodes as
**external LAN traffic** (no eBPF identity marking), which is why the
`cilium.l7policy` filter does not deny it — see
[docs/postmortem-gateway-403-hairpin.md](../../../../../docs/postmortem-gateway-403-hairpin.md)
for the internal reasoning.

## Reviewer checklist for new external HTTPRoutes

Before approving any HTTPRoute that targets the `external-https` listener:

- [ ] Consumer namespace carries `platform.io/consume.external-gateway-routes: "true"`
- [ ] HTTPRoute `parentRefs[].sectionName: external-https`
- [ ] Hostname matches `*.homelab.ntbc.io` (no apex-bare hostname leaks)
- [ ] **Authentication is enforced at the application layer** (Dex/OIDC,
      oauth2-proxy, mTLS, signed cookies, etc.). SNI isolation does NOT
      authenticate clients — anyone on the public internet can reach the route.
- [ ] Service has its own CNP (do NOT rely on the public listener for
      authorization)
- [ ] PR description includes a curl-from-WAN verification log proving the route
      serves the expected response and that internal hostnames return 404 from
      the public IP

## Related

- Gateway resource: `resources/gateway.yaml`
- External wildcard cert: `resources/certificate-external.yaml` (Let's Encrypt)
- Internal wildcard cert: `resources/certificate.yaml` (Vault internal CA)
- PNI capability: `external-gateway-routes` (registered in
  `kubernetes/base/infrastructure/platform-network-interface/resources/capability-registry-configmap.yaml`)
- Reference: `docs/platform-network-interface.md`
