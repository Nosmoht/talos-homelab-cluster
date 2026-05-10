---
paths:
  - "kubernetes/**/cni/**"
---

<!-- INTENTIONALLY MINIMAL: scope anchor for future CNI-driver-agnostic content.
     Created in plan "hubble-certs-sind-cilium-giggly-matsumoto" alongside the
     talos-mcp-first.md scope refactor. Do not delete as "abandoned" — empty
     by design until a concrete CNI-general entry surfaces. -->

# Kubernetes CNI

## Scope

**Inclusion**: CNI-driver-agnostic patterns — Multus / secondary networks, eBPF datapath generalities applicable across CNIs, NetworkPolicy semantics that hold across CNI implementations.

**Exclusion** (with named pointers):
- Cilium runtime / dataplane / network policy → `.claude/rules/cilium-network-policy.md`
- Cilium Gateway API / HTTPRoute / Envoy listener → `.claude/rules/cilium-gateway-api.md`
- Cilium agent ↔ service BPF-map desync, ClusterIP timeouts → `.claude/rules/cilium-service-sync.md`
- Cilium bootstrap via Talos extraManifests (Hubble cert-gen, ConfigMap update gotcha) → `.claude/rules/cilium-bootstrap.md`

*(no concrete entries yet — anchor file for future CNI-general content)*
