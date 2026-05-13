#!/usr/bin/env bash
# verify-consumer-rendered.sh — re-render every consumer overlay
# component into a tmpdir and diff against the committed _rendered/.
# Drift = workflow exits non-zero. Mirrors the platform-base
# verify-rendered.sh gate but operates on consumer overlays.
#
# Components scanned: every directory under
# kubernetes/overlays/homelab/infrastructure/ that has both a
# kustomization.yaml and a _rendered/ subdirectory.
#
# Exit codes:
#   0 — every overlay's _rendered/ matches what kustomize build
#       would produce now.
#   1 — at least one overlay drifts.
#   2 — render failed for at least one overlay.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
INFRA_DIR="${ROOT}/kubernetes/overlays/homelab/infrastructure"

components="$(find "${INFRA_DIR}" -mindepth 2 -maxdepth 2 -name '_rendered' -type d -exec dirname {} \; \
  | xargs -n1 basename | sort)"

if [ -z "${components}" ]; then
  echo "no consumer overlays with _rendered/ found — nothing to verify"
  exit 0
fi

drift=0
render_fail=0
tmproot="$(mktemp -d)"
trap 'rm -rf "${tmproot}"' EXIT

for comp in ${components}; do
  echo "==> verify ${comp}"
  rendered_dir="${INFRA_DIR}/${comp}/_rendered"
  snapshot="${tmproot}/${comp}.committed"
  cp -r "${rendered_dir}" "${snapshot}"

  if ! "${ROOT}/scripts/render-consumer-component.sh" "${comp}" >/dev/null 2>"${tmproot}/${comp}.err"; then
    echo "  RENDER FAILED for ${comp}:"
    sed 's/^/    /' < "${tmproot}/${comp}.err" >&2
    render_fail=1
    continue
  fi

  if ! diff -ruN "${snapshot}" "${rendered_dir}" > "${tmproot}/${comp}.diff"; then
    echo "  DRIFT in ${comp}:"
    sed 's/^/    /' < "${tmproot}/${comp}.diff" | head -50
    if [ "$(wc -l < "${tmproot}/${comp}.diff")" -gt 50 ]; then
      echo "    ... (diff truncated; full output at ${tmproot}/${comp}.diff)"
    fi
    drift=1
  else
    echo "  OK"
  fi
done

if [ "${render_fail}" -ne 0 ]; then
  echo ""
  echo "::error::one or more consumer overlays failed to render"
  exit 2
fi
if [ "${drift}" -ne 0 ]; then
  echo ""
  echo "::error::committed consumer _rendered/ tree drifts from current overlay sources + vendor/base/"
  echo "Re-run \`make render-consumer-all\` and commit the result."
  exit 1
fi

echo ""
echo "All consumer overlays: rendered output matches committed."
