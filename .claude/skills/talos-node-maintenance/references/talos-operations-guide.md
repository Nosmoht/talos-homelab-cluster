# Talos Node Operations Guide

## Apply Modes

| Mode | Behavior | When to Use |
|------|----------|-------------|
| `--mode=auto` | Talos decides: reboot if needed, otherwise live apply | Default for most changes |
| `--mode=staged` | Pre-loads config, defers reboot to next maintenance window | CP nodes during business hours |
| `--mode=no-reboot` | Applies only if no reboot required; fails otherwise | Safe probing of sysctl-only changes |

The Makefile `apply-<node>` target uses `--mode=auto` by default.

## Upgrade and `--preserve`

`talosctl upgrade` without `--preserve` wipes the EPHEMERAL partition (logs, pod data). Always ensure the Makefile `upgrade-<node>` target passes `--preserve`.

Note: `talosctl upgrade` does not support `--dry-run` (tracked in [siderolabs/talos#10804](https://github.com/siderolabs/talos/issues/10804)). The `dry-run-<node>` Makefile target only validates config generation.

## Etcd Backup (Control-Plane Only)

Before any CP operation that may trigger a reboot:

```bash
talosctl etcd snapshot /tmp/etcd-backup-$(date +%Y%m%d).snapshot -n <ip> -e <ip>
talosctl get machineconfig -n <ip> -e <ip> -o yaml > /tmp/machineconfig-<node>-$(date +%Y%m%d).yaml
```

## Etcd Quorum Check

After CP node rejoin, verify quorum before proceeding to next node:

```bash
talosctl etcd members -n <ip> -e <ip>    # all members should show "started"
talosctl etcd status -n <ip> -e <ip>
```

## Kubernetes Drain/Uncordon

For upgrades (which trigger a reboot):

```bash
# Before upgrade
KUBECONFIG=<kubeconfig> kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
# After verification passes
KUBECONFIG=<kubeconfig> kubectl uncordon <node>
```

## Rollback

Talos uses an A/B image scheme. If an upgrade boots into a broken state:

```bash
talosctl rollback -n <ip> -e <ip>
```

## Separate Operations

- **OS image/boot-arg/extension changes:** `talosctl apply-config` + `talosctl upgrade --preserve`
- **Sysctl/config changes:** `talosctl apply-config -n <ip> -e <ip> -f talos/generated/<role>/<node>.yaml`
- **Kubernetes version upgrade:** `talosctl upgrade-k8s` (distinct from OS upgrade)
