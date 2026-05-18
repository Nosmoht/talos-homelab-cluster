#!/usr/bin/env bash
# migrate-platform-ns-ownership.sh
#
# One-time migration: transfer ArgoCD tracking-id annotation on platform
# namespaces from the consumer `root` Application to the per-component
# Application. Implements Architecture C from
# talos-platform-base#39 (docs/adr-namespace-ownership-rendered-manifests.md).
#
# After this script runs, each platform namespace has the per-component
# Application as its sole ArgoCD lifecycle owner. The follow-up commit
# can then remove the namespace entry from
# kubernetes/overlays/homelab/infrastructure/namespaces-psa.yaml without
# triggering root prune.
#
# Idempotent. Safe to re-run. Skips namespaces already on the target
# tracking-id.
#
# Usage:
#   ./scripts/migrate-platform-ns-ownership.sh            # dry-run
#   ./scripts/migrate-platform-ns-ownership.sh --apply    # execute
#
# Out of scope:
#   - argocd namespace: argocd Application is still on the legacy
#     non-Rendered-Manifests pattern. Vendor namespace.yaml is not in
#     its _rendered/manifests.yaml. Until argocd App is migrated
#     (separate work), the argocd NS stays under root tracking-id and
#     stays declared in namespaces-psa.yaml.
#   - monitoring, vault: already on per-component App tracking-id
#     (loki, vault-operator). Script reports them as already-correct.

set -euo pipefail

APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

# NS → owning Application name (the per-component App whose destination
# is that namespace). Verified manually:
#   kubectl get application -n argocd <app> -o jsonpath='{.spec.destination.namespace}'
declare_pair() { printf '%s\n' "$1=$2"; }

PAIRS=$(cat <<'EOF'
kyverno=kyverno
node-feature-discovery=node-feature-discovery
tetragon=tetragon
EOF
)

# Optional informational set: namespaces that ALREADY have the right
# tracking-id. Script verifies and reports no-op.
INFO_PAIRS=$(cat <<'EOF'
monitoring=loki
vault=vault-operator
EOF
)

ARGO_NS=argocd

check_kubectl() {
  command -v kubectl >/dev/null || { echo "error: kubectl not in PATH" >&2; exit 2; }
  kubectl cluster-info >/dev/null 2>&1 || {
    echo "error: kubectl cannot reach the cluster (kubectl cluster-info failed)" >&2
    exit 2
  }
}

build_tracking_id() {
  # ArgoCD resource tracking annotation format:
  #   <app-name>:<group>/<kind>:<app-destination-namespace>/<resource-name>
  # For platform NS where app destination.namespace == ns name (e.g.
  # kyverno App → kyverno NS), this collapses to <app>:/Namespace:<ns>/<ns>.
  # For cases where they differ (loki App → monitoring NS,
  # vault-operator App → vault NS), the App's destination.namespace
  # is queried from the live cluster.
  local app="$1"
  local ns="$2"
  local dest
  dest=$(kubectl get application -n "$ARGO_NS" "$app" -o jsonpath='{.spec.destination.namespace}' 2>/dev/null || true)
  [ -z "$dest" ] && dest="$ns"
  printf '%s:/Namespace:%s/%s' "$app" "$dest" "$ns"
}

migrate_one() {
  local ns="$1"
  local app="$2"
  local target_tid
  target_tid=$(build_tracking_id "$app" "$ns")

  local current_tid
  current_tid=$(kubectl get ns "$ns" -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}' 2>/dev/null || true)

  if [ -z "$current_tid" ]; then
    printf '  %-24s : MISSING (namespace does not exist or no tracking-id annotation)\n' "$ns"
    return
  fi

  if [ "$current_tid" = "$target_tid" ]; then
    printf '  %-24s : already on target tracking-id (%s)\n' "$ns" "$target_tid"
    return
  fi

  printf '  %-24s : %s\n' "$ns" "$current_tid"
  printf '  %-24s    → %s\n' '' "$target_tid"

  # Verify target App exists with matching destination, fail otherwise.
  local app_dest
  app_dest=$(kubectl get application -n "$ARGO_NS" "$app" -o jsonpath='{.spec.destination.namespace}' 2>/dev/null || true)
  if [ "$app_dest" != "$ns" ]; then
    printf '  %-24s    ! target Application argocd/%s destination.namespace=%s, expected %s. SKIP.\n' '' "$app" "$app_dest" "$ns"
    return 1
  fi

  if [ $APPLY -eq 1 ]; then
    kubectl annotate ns "$ns" \
      "argocd.argoproj.io/tracking-id=${target_tid}" \
      --overwrite >/dev/null
    printf '  %-24s    ✓ applied\n' ''
  else
    printf '  %-24s    (dry-run; pass --apply to execute)\n' ''
  fi
}

main() {
  check_kubectl

  if [ $APPLY -eq 1 ]; then
    echo "==> Mode: APPLY (live cluster will be modified)"
  else
    echo "==> Mode: dry-run (read-only)"
  fi
  echo ""

  echo "==> Migrating platform namespaces from root → per-component App"
  while IFS='=' read -r ns app; do
    [ -z "$ns" ] && continue
    migrate_one "$ns" "$app" || true
  done <<< "$PAIRS"

  echo ""
  echo "==> Informational: verify already-correct namespaces"
  while IFS='=' read -r ns app; do
    [ -z "$ns" ] && continue
    current_tid=$(kubectl get ns "$ns" -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}' 2>/dev/null || true)
    target_tid=$(build_tracking_id "$app" "$ns")
    if [ "$current_tid" = "$target_tid" ]; then
      printf '  %-24s : ✓ already correct (%s)\n' "$ns" "$current_tid"
    else
      printf '  %-24s : ⚠ tracking-id=%s (expected %s)\n' "$ns" "$current_tid" "$target_tid"
    fi
  done <<< "$INFO_PAIRS"

  echo ""
  echo "==> argocd namespace: NOT migrated by this script."
  echo "    argocd Application is on the legacy non-Rendered-Manifests pattern."
  echo "    Its vendor namespace.yaml is not in its tracked source. Transferring"
  echo "    tracking-id would cause the argocd App to prune the namespace on next"
  echo "    sync. The argocd NS stays in namespaces-psa.yaml until argocd App is"
  echo "    migrated to the Rendered Manifests Pattern (separate work)."
  echo ""
  echo "==> Done."
}

main "$@"
