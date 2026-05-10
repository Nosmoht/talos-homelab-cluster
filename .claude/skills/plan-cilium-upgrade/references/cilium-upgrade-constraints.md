# Cilium Upgrade Constraints

## One Minor Version at a Time

Cilium only supports upgrades between consecutive minor releases. Rollback is only tested for one minor version back.

- Valid: 1.15.x -> 1.16.x
- Invalid: 1.15.x -> 1.17.x (requires staged path: 1.15 -> 1.16 -> 1.17)

If a hop spans more than one minor, flag it and recommend a staged upgrade path.

Source: [Cilium Upgrade Guide](https://docs.cilium.io/en/stable/operations/upgrade/)

## Never Use `--reuse-values`

Cilium's Helm chart introduces new required values between versions. `--reuse-values` silently drops these, causing broken or degraded Cilium installations.

Instead: export current values, diff against new chart defaults, pass reviewed values explicitly.

Source: [Cilium Upgrade Guide](https://docs.cilium.io/en/stable/operations/upgrade/)

## Patch First

Before jumping to a new minor, upgrade to the latest patch of the current minor first (e.g., if on 1.15.2, upgrade to 1.15.latest before moving to 1.16.x).

## Preflight Check

Run Cilium's preflight validation before any upgrade:

```bash
KUBECONFIG=<kubeconfig> cilium preflight check
```

## Kubernetes Compatibility

Verify the target Cilium version supports the cluster's Kubernetes version:
- Matrix: https://docs.cilium.io/en/stable/network/kubernetes/compatibility/
