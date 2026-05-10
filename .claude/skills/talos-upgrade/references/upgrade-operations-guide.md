# Upgrade Operations Guide

## Upgrade and `--preserve`

`talosctl upgrade` without `--preserve` wipes the EPHEMERAL partition (logs, pod data). The Makefile `upgrade-<node>` target passes `--preserve`.

Note: `talosctl upgrade` does not support `--dry-run` (tracked in [siderolabs/talos#10804](https://github.com/siderolabs/talos/issues/10804)). The `dry-run-<node>` Makefile target only validates config generation.

## Kubernetes Drain/Uncordon

For upgrades (which trigger a reboot):

```bash
# Before upgrade — 120s timeout mitigates DRBD CSI D-state deadlock
KUBECONFIG=<kubeconfig> kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --timeout=120s
# After verification passes
KUBECONFIG=<kubeconfig> kubectl uncordon <node>
```

## Rollback

Talos uses an A/B image scheme. If an upgrade boots into a broken state:

```bash
talosctl rollback -n <ip> -e <ip>
```

Warning: nodes stuck "shutting down" (D-state on DRBD) are only fixable with physical power cycle.

## Etcd Backup (Control-Plane Only)

Before any CP operation that may trigger a reboot:

```bash
talosctl etcd snapshot /tmp/etcd-backup-$(date +%Y%m%d).snapshot -n <ip> -e <ip>
talosctl get machineconfig -n <ip> -e <ip> -o yaml > /tmp/machineconfig-<node>-$(date +%Y%m%d).yaml
```

## Etcd Quorum Check

After CP node rejoin, verify quorum before declaring success:

```bash
talosctl etcd members -n <ip> -e <ip>    # all members should show "started"
talosctl etcd status -n <ip> -e <ip>
```

## Scope

- **OS image/boot-arg/extension changes:** `talosctl apply-config` + `talosctl upgrade --preserve` (this skill)
- **Config/sysctl changes:** `talosctl apply-config -n <ip> -e <ip> -f talos/generated/<role>/<node>.yaml` (use `/talos-apply`)
- **Kubernetes version upgrade:** `talosctl upgrade-k8s` (distinct from both)
