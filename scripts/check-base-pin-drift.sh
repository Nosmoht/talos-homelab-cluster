#!/usr/bin/env bash
# check-base-pin-drift.sh — fail-closed gate ensuring the Day-0 pin
# (`.base-version`) and the Day-2 pin (`spec.sources[].targetRevision`
# entries pointing at `talos-platform-base.git`) move in lock-step.
#
# Defined in docs/adr-multi-repo-platform-split.md and
# docs/talos-homelab-cluster-creation-plan.md §8.3.
#
# Exit codes:
#   0 — every Application that references the base repo pins the same
#       tag that `.base-version` declares; every AppProject that runs
#       Multi-Source Applications lists the base repo in sourceRepos.
#   1 — drift detected (one or more Applications pin a different tag,
#       or the base repo is missing from an AppProject's sourceRepos
#       while at least one Application in that AppProject's namespace
#       references the base repo).
#   2 — environment error (missing yq, missing .base-version, no
#       Applications matched at all).

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
VERSION_FILE="${ROOT}/.base-version"
OVERLAY_ROOT="${ROOT}/kubernetes/overlays"
BASE_REPO_URL="https://github.com/Nosmoht/talos-platform-base.git"

command -v yq >/dev/null 2>&1 || {
  echo "error: yq not in PATH — pin via .tool-versions" >&2
  exit 2
}

if [ ! -f "${VERSION_FILE}" ]; then
  echo "error: ${VERSION_FILE} missing — Day-0 pin is the source of truth" >&2
  exit 2
fi
PIN="$(tr -d '[:space:]' < "${VERSION_FILE}")"
[ -n "${PIN}" ] || { echo "error: .base-version is empty" >&2; exit 2; }

export BASE_REPO_URL
drift=0
applications_checked=0

while IFS= read -r -d '' f; do
  while IFS= read -r rev; do
    [ -z "${rev}" ] && continue
    applications_checked=$((applications_checked + 1))
    if [ "${rev}" != "${PIN}" ]; then
      rel="${f#${ROOT}/}"
      echo "DRIFT: ${rel} pins base @ ${rev}, but .base-version says ${PIN}"
      drift=1
    fi
  done < <(yq -r \
    '.spec.sources[]? | select(.repoURL == strenv(BASE_REPO_URL)) | .targetRevision // ""' \
    "${f}" 2>/dev/null || true)
done < <(find "${OVERLAY_ROOT}" -name application.yaml -type f -print0)

if [ "${applications_checked}" -eq 0 ]; then
  echo "error: no Applications referencing ${BASE_REPO_URL} found under ${OVERLAY_ROOT}" >&2
  echo "       (script assumes the consumer overlay has at least one Multi-Source Application)" >&2
  exit 2
fi

while IFS= read -r -d '' f; do
  kind="$(yq -r '.kind // ""' "${f}" 2>/dev/null)"
  [ "${kind}" = "AppProject" ] || continue
  if ! yq -e '.spec.sourceRepos[]? | select(. == strenv(BASE_REPO_URL))' \
       "${f}" >/dev/null 2>&1; then
    rel="${f#${ROOT}/}"
    echo "WARN: ${rel} (AppProject) does not list ${BASE_REPO_URL} in sourceRepos —"
    echo "      Applications scoped to this AppProject cannot reference the base repo"
    drift=1
  fi
done < <(find "${OVERLAY_ROOT}/homelab/projects" -name '*.yaml' -type f -print0 2>/dev/null)

if [ "${drift}" -ne 0 ]; then
  echo
  echo "Drift detected. Bump .base-version + every targetRevision in lock-step,"
  echo "or add the missing AppProject sourceRepos entry. See"
  echo "docs/base-pin-drift-analysis.md for the remediation order."
  exit 1
fi

echo "OK: ${applications_checked} Application(s) all pin base @ ${PIN}; AppProjects list ${BASE_REPO_URL}."
