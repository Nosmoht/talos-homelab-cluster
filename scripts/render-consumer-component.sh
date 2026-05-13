#!/usr/bin/env bash
# render-consumer-component.sh — Stage-3 of the rendered-manifests
# pipeline. Builds a single consumer overlay against the vendored
# talos-platform-base OCI tree and writes the result to
# <overlay>/_rendered/manifests.yaml (+ crds.yaml when CRDs exist).
#
# Usage:
#   scripts/render-consumer-component.sh <component>
#
# Prerequisites:
#   - vendor/base/ populated by `make pull-base-oci` (or the full
#     pull-base-oci.sh chain). The component's overlay kustomization.yaml
#     references vendor/base/kubernetes/base/infrastructure/<comp>/_rendered/
#     via relative path.
#   - kustomize CLI pinned via .tool-versions.
#
# Exit codes:
#   0 — render succeeded
#   1 — usage error / missing input
#   2 — kustomize build failed
#   3 — output empty (unexpected)

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <component>" >&2
  exit 1
fi
COMP="$1"
OVERLAY_DIR="${ROOT}/kubernetes/overlays/homelab/infrastructure/${COMP}"
RENDERED_DIR="${OVERLAY_DIR}/_rendered"

[ -d "${OVERLAY_DIR}" ] || { echo "error: overlay dir not found: ${OVERLAY_DIR}" >&2; exit 1; }
[ -f "${OVERLAY_DIR}/kustomization.yaml" ] || { echo "error: kustomization.yaml missing in ${OVERLAY_DIR}" >&2; exit 1; }
[ -d "${ROOT}/vendor/base" ] || { echo "error: vendor/base/ missing — run \`make pull-base-oci\` first" >&2; exit 1; }

mkdir -p "${RENDERED_DIR}"

# --load-restrictor=LoadRestrictionsNone is required because consumer
# overlays reference vendored manifests via paths that traverse `..`
# (e.g. ../../../../../vendor/base/kubernetes/base/infrastructure/...).
# kustomize 5.x rejects such traversal by default.
echo "==> [${COMP}] Stage-3 render (kustomize build of consumer overlay)"
stage3_out="$(mktemp)"
trap 'rm -f "${stage3_out}"' EXIT
kustomize build --load-restrictor=LoadRestrictionsNone "${OVERLAY_DIR}" > "${stage3_out}" \
  || { echo "error: kustomize build failed" >&2; exit 2; }

[ -s "${stage3_out}" ] || { echo "error: kustomize build produced empty output for ${COMP}" >&2; exit 3; }

echo "==> [${COMP}] Splitting CRDs from manifests"
yq 'select(.kind != "CustomResourceDefinition")' "${stage3_out}" > "${RENDERED_DIR}/manifests.yaml"
crds_tmp="$(mktemp)"
yq 'select(.kind == "CustomResourceDefinition")' "${stage3_out}" > "${crds_tmp}"
if [ -s "${crds_tmp}" ]; then
  mv "${crds_tmp}" "${RENDERED_DIR}/crds.yaml"
else
  rm -f "${crds_tmp}" "${RENDERED_DIR}/crds.yaml"
fi

# Normalize trailing newlines.
for f in "${RENDERED_DIR}/manifests.yaml" "${RENDERED_DIR}/crds.yaml"; do
  [ -f "${f}" ] && perl -0pi -e 's/\n*\z/\n/' "${f}"
done

manifest_lines="$(wc -l < "${RENDERED_DIR}/manifests.yaml" | tr -d ' ')"
if [ -f "${RENDERED_DIR}/crds.yaml" ]; then
  crd_lines="$(wc -l < "${RENDERED_DIR}/crds.yaml" | tr -d ' ')"
  echo "==> [${COMP}] Done. manifests.yaml=${manifest_lines}L, crds.yaml=${crd_lines}L"
else
  echo "==> [${COMP}] Done. manifests.yaml=${manifest_lines}L, no CRDs"
fi
