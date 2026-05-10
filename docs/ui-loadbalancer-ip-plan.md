# UI LoadBalancer IP Plan (homelab.local)

## Reserved Cilium UI Pool
- `192.168.2.130-192.168.2.150`
- Selector: `homelab.local/expose: "true"`

## Fixed UI IP Allocations
- `192.168.2.131` -> `dex.homelab.local` (`dex`)
- `192.168.2.133` -> `prometheus.homelab.local` (`prometheus-oauth2-proxy`)
- `192.168.2.134` -> `alertmanager.homelab.local` (`alertmanager-oauth2-proxy`)

## Notes
- Existing Gateway LB IP pool remains separate (`192.168.2.70/32`).
- L2 announcements for UI services are controlled by `CiliumL2AnnouncementPolicy` with `homelab.local/expose: "true"`.
- Ensure designated announcer nodes are labeled with `homelab.local/edge-gateway=true`.

## Example /etc/hosts entries
```text
192.168.2.70 argocd.homelab.local
192.168.2.131 dex.homelab.local
192.168.2.70 grafana.homelab.local
192.168.2.133 prometheus.homelab.local
192.168.2.134 alertmanager.homelab.local
```
