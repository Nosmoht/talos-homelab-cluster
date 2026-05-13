#!/usr/bin/env bash
# pull-base-oci.sh — fetch the talos-platform-base OCI artifact into
# vendor/base/ for the consumer render step (Phase C of the rendered-
# manifests migration).
#
# What this script does:
#   1. Reads the pinned tag from .base-version at the repo root.
#   2. Verifies the OCI artifact's cosign signature (keyless OIDC,
#      identity = the OCI publish workflow on the upstream repo).
#   3. Pulls the artifact via `oras pull` into vendor/base/.
#   4. Verifies post-pull that the expected directory tree is present.
#
# Prerequisites:
#   - oras CLI (pinned in .tool-versions)
#   - cosign CLI (pinned in .tool-versions)
#   - GitHub anonymous-pull access to ghcr.io for the artifact (no
#     auth needed since talos-platform-base is a public repo).
#
# Exit codes:
#   0 — pulled and verified successfully
#   1 — usage error / missing prerequisite
#   2 — cosign verification failed (artifact tampered or unknown signer)
#   3 — oras pull failed
#   4 — post-pull tree validation failed

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
VERSION_FILE="${ROOT}/.base-version"
VENDOR_DIR="${ROOT}/vendor/base"
OCI_REPO="ghcr.io/nosmoht/talos-platform-base"

# Identity-regex pattern that the talos-platform-base OCI publish
# workflow uses (cosign keyless OIDC). Documented in
# talos-platform-base/docs/oci-artifact-verification.md.
COSIGN_IDENTITY_REGEX='^https://github\.com/Nosmoht/talos-platform-base/\.github/workflows/oci-publish\.yml@refs/tags/v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$'
COSIGN_OIDC_ISSUER='https://token.actions.githubusercontent.com'

if [ ! -f "${VERSION_FILE}" ]; then
  echo "error: ${VERSION_FILE} not found — required to know which OCI tag to pull" >&2
  exit 1
fi
TAG="$(tr -d '[:space:]' < "${VERSION_FILE}")"
[ -n "${TAG}" ] || { echo "error: .base-version is empty" >&2; exit 1; }

for bin in oras cosign tar; do
  command -v "${bin}" >/dev/null 2>&1 || { echo "error: ${bin} not in PATH" >&2; exit 1; }
done

ARTIFACT="${OCI_REPO}:${TAG}"

echo "==> Verifying cosign signature on ${ARTIFACT}"
if ! cosign verify \
    --certificate-identity-regexp "${COSIGN_IDENTITY_REGEX}" \
    --certificate-oidc-issuer "${COSIGN_OIDC_ISSUER}" \
    "${ARTIFACT}" >/dev/null 2>&1; then
  echo "error: cosign verification failed for ${ARTIFACT}" >&2
  echo "  Expected identity matches: ${COSIGN_IDENTITY_REGEX}" >&2
  echo "  Expected OIDC issuer:      ${COSIGN_OIDC_ISSUER}" >&2
  echo "  This means either (a) the artifact was published by a workflow" >&2
  echo "  that is not the official talos-platform-base oci-publish.yml, or" >&2
  echo "  (b) the signature is missing/invalid. Both are fail-closed events." >&2
  exit 2
fi
echo "==> cosign verified"

echo "==> Pulling ${ARTIFACT} into ${VENDOR_DIR}"
mkdir -p "${VENDOR_DIR}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

if ! (cd "${tmp_dir}" && oras pull "${ARTIFACT}" >/dev/null); then
  echo "error: oras pull failed for ${ARTIFACT}" >&2
  exit 3
fi

# The artifact ships as a single tarball named talos-platform-base-<tag>.tar.gz.
# Unpack into a clean vendor/base/ to avoid stale files from a previous tag.
tarball="$(find "${tmp_dir}" -maxdepth 1 -name 'talos-platform-base-*.tar.gz' | head -n1)"
[ -n "${tarball}" ] || { echo "error: tarball not found in pulled artifact" >&2; exit 3; }

echo "==> Unpacking $(basename "${tarball}")"
rm -rf "${VENDOR_DIR}"
mkdir -p "${VENDOR_DIR}"
tar -xzf "${tarball}" -C "${VENDOR_DIR}"

# Post-pull sanity check — the rendered-manifests tree must be present.
required_paths=(
  "${VENDOR_DIR}/kubernetes/base/infrastructure"
  "${VENDOR_DIR}/AGENTS.md"
)
for p in "${required_paths[@]}"; do
  [ -e "${p}" ] || { echo "error: expected path missing in vendored base: ${p}" >&2; exit 4; }
done

components_count="$(find "${VENDOR_DIR}/kubernetes/base/infrastructure" -mindepth 2 -maxdepth 2 -name '_rendered' -type d | wc -l | tr -d ' ')"
echo "==> Vendored ${components_count} components with _rendered/ output from ${TAG}"
