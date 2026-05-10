# Apply Operations Guide

## Apply Modes

| Mode | Behavior | When to Use |
|------|----------|-------------|
| `--mode=auto` | Talos decides: reboot if needed, otherwise live apply | Default for most changes |
| `--mode=staged` | Pre-loads config, defers reboot to next maintenance window | CP nodes during business hours |
| `--mode=no-reboot` | Applies only if no reboot required; fails otherwise | Safe probing of sysctl-only changes |

The Makefile `apply-<node>` target uses `--mode=auto` by default.

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

- **Config/sysctl changes:** `talosctl apply-config -n <ip> -e <ip> -f talos/generated/<role>/<node>.yaml` (this skill)
- **OS image/boot-arg/extension changes:** `talosctl apply-config` + `talosctl upgrade --preserve` (use `/talos-upgrade`)
- **Kubernetes version upgrade:** `talosctl upgrade-k8s` (distinct from both)
