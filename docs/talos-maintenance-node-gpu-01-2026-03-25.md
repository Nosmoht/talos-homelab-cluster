# Talos Maintenance: node-gpu-01 (2026-03-25)

## Change Summary
- **Node:** node-gpu-01 (GPU worker, 192.168.2.67)
- **Operation:** apply
- **Mode:** auto (no reboot)
- **Rationale:** Added USB NIC NAPI budget sysctls (`net.core.netdev_budget: 600`, `net.core.netdev_budget_usecs: 8000`) to mitigate RX drops on RTL8153 USB NIC

## Commands Executed
1. `make -C talos gen-configs` — configs already up to date
2. `make -C talos dry-run-node-gpu-01` — diff confirmed 2 new sysctls, no reboot required
3. `make -C talos apply-node-gpu-01` — applied configuration without a reboot

## Verification Results
- talosctl version: v1.12.6 confirmed
- talosctl health: N/A (worker node, etcd check not applicable)
- kubectl get node: Ready (Kubernetes v1.35.0)

## Recovery Notes
None — operation completed successfully.
