#!/usr/bin/env bash
# cleanup-csa-annotation.sh — strip kubectl's legacy
# `kubectl.kubernetes.io/last-applied-configuration` annotation from
# every resource ArgoCD will take over in the Phase D cutover.
#
# Why this exists (team-red finding H3):
# The 18 components migrating to rendered-manifests are currently live
# with Client-Side Apply (CSA) ownership. ArgoCD will switch to
# Server-Side Apply (SSA) at cutover. CSA leaves the
# `last-applied-configuration` annotation on every resource;
# subsequent SSA does not strip it. If a future tool (manual
# `kubectl apply`, an out-of-tree controller, anything) issues CSA
# against the same resource, it diffs the live state against the
# stale annotation and may revert fields that SSA is now authoritative
# for. Stripping the annotation pre-cutover prevents this entire
# class of regression.
#
# Run order:
#   1. Operator runs this script ONCE on the live cluster, BEFORE
#      the first ArgoCD sync with the new directory-source apps.
#   2. ArgoCD syncs with `syncOptions: ServerSideApply=true` and
#      `--force-conflicts` on the first pass to take ownership.
#   3. From that point on, SSA managedFields is the truth; CSA cannot
#      sneak in via the annotation pathway.
#
# Usage:
#   scripts/cleanup-csa-annotation.sh [namespace [namespace ...]]
#
# If no namespaces are given, the script operates on the migration's
# 18 component namespaces (hardcoded list at the bottom of the file).
# Pass `--dry-run` as the first arg to log what would be stripped
# without changing anything.

set -euo pipefail

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=1
  shift
fi

# Default namespace list — the full migration scope. cluster-scoped
# resources (CRDs, ClusterRoles, ClusterRoleBindings) are handled by
# the special `__cluster__` pseudo-namespace at the end.
DEFAULT_NAMESPACES=(
  alloy
  argocd
  cert-manager
  dex
  external-secrets
  kube-system
  kubelet-serving-cert-approver
  kubevirt
  cdi
  kyverno
  monitoring
  node-feature-discovery
  nvidia-dcgm-exporter
  nvidia-device-plugin
  piraeus-datastore
  tetragon
  vault
)

if [ "$#" -gt 0 ]; then
  NAMESPACES=("$@")
else
  NAMESPACES=("${DEFAULT_NAMESPACES[@]}")
fi

ANNOTATION='kubectl.kubernetes.io/last-applied-configuration'
SCOPED_KINDS='deployment,statefulset,daemonset,job,cronjob,service,configmap,secret,serviceaccount,role,rolebinding'
CLUSTER_KINDS='clusterrole,clusterrolebinding,crd,validatingwebhookconfiguration,mutatingwebhookconfiguration'

strip_in_ns() {
  local ns="$1"
  if ! kubectl get ns "${ns}" >/dev/null 2>&1; then
    echo "SKIP:    namespace ${ns} does not exist"
    return
  fi
  local count
  count="$(kubectl get -n "${ns}" "${SCOPED_KINDS}" -o name 2>/dev/null | wc -l | tr -d ' ')"
  echo "==> ${ns} (${count} candidate resources)"
  if [ "${DRY_RUN}" -eq 1 ]; then
    kubectl get -n "${ns}" "${SCOPED_KINDS}" -o name 2>/dev/null \
      | while IFS= read -r res; do
          if kubectl get -n "${ns}" "${res}" -o jsonpath="{.metadata.annotations.${ANNOTATION//\./\\.}}" 2>/dev/null \
              | grep -q .; then
            echo "  WOULD STRIP: ${res}"
          fi
        done
  else
    # `annotate --overwrite ... key-` removes the annotation if present;
    # silent no-op if absent. Process in parallel for speed.
    kubectl get -n "${ns}" "${SCOPED_KINDS}" -o name 2>/dev/null \
      | xargs -I{} -P 8 kubectl annotate -n "${ns}" --overwrite {} "${ANNOTATION}-" >/dev/null 2>&1 || true
    echo "  done"
  fi
}

strip_cluster_scoped() {
  local count
  count="$(kubectl get "${CLUSTER_KINDS}" -o name 2>/dev/null | wc -l | tr -d ' ')"
  echo "==> __cluster__ (${count} candidate resources)"
  if [ "${DRY_RUN}" -eq 1 ]; then
    kubectl get "${CLUSTER_KINDS}" -o name 2>/dev/null \
      | while IFS= read -r res; do
          if kubectl get "${res}" -o jsonpath="{.metadata.annotations.${ANNOTATION//\./\\.}}" 2>/dev/null \
              | grep -q .; then
            echo "  WOULD STRIP: ${res}"
          fi
        done
  else
    kubectl get "${CLUSTER_KINDS}" -o name 2>/dev/null \
      | xargs -I{} -P 8 kubectl annotate --overwrite {} "${ANNOTATION}-" >/dev/null 2>&1 || true
    echo "  done"
  fi
}

echo "CSA annotation cleanup (${ANNOTATION})"
echo "Mode: $([ "${DRY_RUN}" -eq 1 ] && echo DRY-RUN || echo APPLY)"
echo ""

for ns in "${NAMESPACES[@]}"; do
  strip_in_ns "${ns}"
done

strip_cluster_scoped

echo ""
echo "Cleanup complete. Verify with:"
echo "  kubectl get deploy -A -o jsonpath='{range .items[*]}{.metadata.annotations.${ANNOTATION}}{\"\\n\"}{end}' | grep -c ."
echo "  (should print 0 if cleanup succeeded)"
