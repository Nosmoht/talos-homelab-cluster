---
paths:
  - "kubernetes/bootstrap/cilium/**"
  - "talos/patches/controlplane.yaml"
---

# Cilium Bootstrap (via Talos extraManifests)

## Scope

**Inclusion**: behaviours specific to the Talos `extraManifests` → Cilium bootstrap pipeline. Anything that surfaces when running `make cilium-bootstrap`, when `talosctl upgrade-k8s` re-applies `cilium.yaml`, or when editing the bootstrap render's inputs.

**Exclusion** (with named pointers):
- Cilium runtime / dataplane / network policy → `.claude/rules/cilium-network-policy.md`
- Gateway API / HTTPRoute / Envoy listener config → `.claude/rules/cilium-gateway-api.md`
- Cilium agent ↔ service BPF-map desync, ClusterIP timeouts → `.claude/rules/cilium-service-sync.md`

## Hubble Components

The bootstrap render includes Hubble: `hubble-relay` Deployment, `hubble-ui` Deployment, and `hubble-generate-certs` Job. The cert-gen Job creates `hubble-server-certs` and `hubble-relay-client-certs` Secrets in `kube-system`.

## `hubble-generate-certs` Job Blocks `upgrade-k8s`

The Job is generated with a hash-based name (e.g. `hubble-generate-certs-b36ef54b9b`) and an immutable `spec.selector`. If the Job from a previous run still exists when `talosctl upgrade-k8s` re-applies the bootstrap manifest, the apply fails with `Job.batch ... is invalid: spec.selector: ... field is immutable`.

**Fix before each `upgrade-k8s` run**:
```bash
kubectl delete job -n kube-system -l k8s-app=hubble-generate-certs
```

The Job re-creates with a fresh hash on the next bootstrap apply and produces the same Secrets. Already-issued Hubble certs in `kube-system` survive — no Hubble outage.

## `upgrade-k8s` Does Not Reliably Update Existing ConfigMaps

When `talosctl upgrade-k8s` re-applies the bootstrap `cilium.yaml`, ConfigMap **creation** works, but **updating** existing ConfigMaps with new keys is unreliable — `upgrade-k8s` reports `no changes` and skips them. Observed for `cilium-config` when adding `enable-wireguard` and other knobs.

**Workaround** — apply the ConfigMap directly with SSA, then restart consumers:
```bash
yq 'select(.kind == "ConfigMap" and .metadata.name == "cilium-config")' \
  kubernetes/bootstrap/cilium/cilium.yaml | \
  kubectl apply --server-side --force-conflicts --field-manager=talos -f -
kubectl -n kube-system rollout restart daemonset/cilium
```

The `--field-manager=talos` matches what `upgrade-k8s` would have used, preventing field-ownership thrash on the next legitimate `upgrade-k8s` run.

## Cross-link

`talos-config.md` §Patch Files documents the `extraManifests` URL-cache trap (cache-bust query param `?v=<n>` must be bumped when bootstrap content changes). That is the upstream-of-bootstrap behaviour: nodes only fetch a fresh manifest when the URL changes. The two gotchas chain — bump the cache-bust, then `upgrade-k8s` runs, then the ConfigMap workaround above kicks in if you've added new keys.
