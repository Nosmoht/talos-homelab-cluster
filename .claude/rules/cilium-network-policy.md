---
paths:
  - "kubernetes/**/cnp-*.yaml"
  - "kubernetes/**/ccnp-*.yaml"
  - "kubernetes/**/platform-network-interface/**"
  - "kubernetes/bootstrap/cilium/**"
  - "kubernetes/**/ingress-front/**"
  - "kubernetes/**/multus-cni/**"
---

# Cilium Network Policy Authoring

## PNI-First Check Before CNP Authoring

Before adding egress rules to a CNP, check whether an existing PNI CCNP already covers the traffic. See `docs/platform-network-interface.md` §Consumer Capability Policies for the full opt-in pattern, including which capabilities require a pod-level label in addition to the namespace label.

- **CCNP exists, traffic still blocked** → verify pod has required pod-level label — see §Troubleshooting in PNI docs
- **No CCNP covers the need** → author the CNP rule directly; consider whether a new PNI capability is warranted

**Validation after shipping any CNP change**: verify the target component is reachable (logs, lease timestamps, Hubble) — `--dry-run=server` passing does not prove traffic flows.

## Identity & Selector Rules
- `fromEntities: ["ingress"]` matches Cilium's `reserved:ingress` identity (ID 8) for Gateway API backend pods
- **kube-apiserver port after DNAT**: use `port: "6443"` in CNP egress rules — Cilium kube-proxy replacement DNATs ClusterIP `10.96.0.1:443` → endpoint:6443 before policy evaluation; `port: "443"` won't match
- **Gateway-backend `toPorts`**: use container ports (post-DNAT) — e.g., `8080` for ArgoCD, not Service port `80`
- **hostNetwork pods** (e.g., `linstor-csi-node`) have host identity — don't write CNPs for them; their traffic appears as `fromEntities: ["host"]`
- **Prefer identity/capability-based selectors** over namespace name allowlists — model connectivity through PNI capabilities and provider/consumer identities
- **K8s NetworkPolicy + CNP AND semantics**: traffic must be allowed by BOTH; don't use K8s default-deny alongside CNPs — per-component CNPs already create implicit default-deny
- **CCNP activates implicit default-deny**: adding a PNI capability label to a namespace with no existing CNP/CCNP selecting its pods activates default-deny; do not opt `privileged` namespaces (e.g., `argocd`) without shipping a full CNP set first
- **ArgoCD hook jobs and CNPs**: Helm hook Jobs (e.g., `admission-create`) run BEFORE resources are synced — CNPs in `resources/` can't unblock them; ensure CNP endpointSelectors cover hook job pod labels and apply CNP fixes live when debugging

## Service-Specific Ports
- **Alertmanager mesh requires TCP + UDP on port 9094** — memberlist gossip uses both; TCP-only CNP causes cluster split-brain
- **kube-prometheus-stack ServiceMonitors have sidecar ports** — alertmanager has `reloader-web:8080` (config-reloader); always `kubectl get servicemonitor <name> -o yaml` to discover all ports before writing CNPs
- **Cross-namespace Prometheus scraping**: when adding CNPs to a namespace with ServiceMonitors, also add egress rule in `cnp-prometheus.yaml` for the target namespace/ports
- **DRBD satellite mesh port range 7000-7999** — LINSTOR assigns per-resource; use Cilium `endPort` for ranges

## WireGuard
- **Strict mode `cidr: ""`** causes fatal crash: `Cannot parse CIDR from --encryption-strict-egress-cidr option: no '/'`. Always set explicit PodCIDR (`10.244.0.0/16`) or omit; Helm renders empty string by default so set it explicitly
- **`allowRemoteNodeIdentities: true` required for hostNetwork pods** — `linstor-csi-node` and other hostNetwork pods use `reserved:remote-node` identity for cross-node traffic; `false` breaks DRBD replication and CSI volume mounts
- **WireGuard does NOT encrypt macvlan or hostNetwork traffic** — traffic entering via a physical NIC is outside Cilium's datapath; only pod-to-pod traffic via eth0/cilium_wg0 is encrypted. Applies to both ingress paths: WAN (`node-pi-01` hostNetwork nginx → gateway nodes, since 2026-04-17) and LAN (`ingress-front` macvlan → nginx → remote worker)
- **Two-pass deployment**: enable with `strictMode.enabled: false` first, verify all 7 tunnels per node, then enable strict mode — rolling restart with strict ON causes traffic blackhole between restarted and not-yet-restarted nodes

## Hubble
- **Dynamic export `includeFilters` uses proto field names** — correct: `verdict: [DROPPED]`, `protocol: [DNS]`; incorrect: `fields: [{name: verdict, values: [DROPPED]}]` (the `fields` wrapper is NOT valid FlowFilter proto format)
- **Export config is hot-reloadable** — updating `cilium-flowlog-config` ConfigMap triggers automatic reconfiguration without pod restart (agent logs: `Configuring Hubble event exporter`)

## eBPF & L7 Policy
- **`cilium.l7policy` applies to ALL eBPF identity-marked traffic** — not just TPROXY-redirected. Any pod traffic via eth0 (Cilium CNI) gets identity-marked. Only external LAN traffic entering via physical NIC (no eBPF marking) bypasses the filter — this is why macvlan (net1) to remote nodes works but eth0 to the same host does not
- **kube-vip does NOT provide virtual MAC** — uses node's real MAC via gratuitous ARP (same as Cilium L2 announcements); only keepalived `use_vmac` provides RFC 5798 virtual MAC

## Macvlan / External Ingress
- **Macvlan bridge mode blocks same-host pod↔host traffic** — kernel limitation; pod cannot reach its own node's LAN IP via net1. Traffic to remote LAN hosts works fine
- **Pod routing table conflict**: `192.168.2.0/24 dev net1` takes precedence over Cilium eth0 default route for all LAN traffic; adding a `/32` host route via eth0 requires `NET_ADMIN` (violates `baseline` PSA)
- **Proxy traffic must go via macvlan to REMOTE nodes** — local node's IP fails silently (macvlan bridge isolation); nginx upstream failover routes to a remote node where traffic arrives as external LAN (no eBPF, no L7 filter)
- **ConfigMap subPath mounts are read-only** — cannot `sed -i` for runtime templating; use init container + emptyDir pattern
- **Stable MAC is a general L2 networking requirement** — VIP MAC changes on failover orphan port forwarding rules and cause ARP cache staleness (1-20+ min)

## Debugging
- Use `hubble observe --from-ip <pod-ip>` for reliable drop visibility — `cilium-dbg monitor --type drop` can miss drops
- Cilium CLI inside agent pods is `cilium-dbg`, not `cilium`
