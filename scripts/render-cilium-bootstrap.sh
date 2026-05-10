#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP_DIR="${ROOT_DIR}/kubernetes/bootstrap/cilium"
OUTPUT_FILE="${BOOTSTRAP_DIR}/cilium.yaml"
VALUES_FILE="${BOOTSTRAP_DIR}/values.yaml"
EXTRAS_FILE="${BOOTSTRAP_DIR}/extras.yaml"
CHART_VERSION="${CILIUM_CHART_VERSION:?CILIUM_CHART_VERSION must be set}"

tmp_render="$(mktemp)"
trap 'rm -f "${tmp_render}"' EXIT

# Ensure the cilium chart repo is available locally.
if ! helm repo list 2>/dev/null | awk 'NR > 1 {print $1}' | grep -qx 'cilium'; then
  helm repo add cilium https://helm.cilium.io >/dev/null
fi
helm repo update cilium >/dev/null

# Full render of the Cilium chart with the repo-managed values file.
helm template cilium cilium/cilium \
  --version "${CHART_VERSION}" \
  --namespace kube-system \
  -f "${VALUES_FILE}" > "${tmp_render}"

# Append hand-crafted extras (GatewayClass, Gateway API RBAC).
if [[ -f "${EXTRAS_FILE}" ]]; then
  printf '\n' >> "${tmp_render}"
  cat "${EXTRAS_FILE}" >> "${tmp_render}"
fi

# Normalize leading/trailing separators and force a single trailing newline.
perl -0pi -e 's/\A\n+//; s/\n---\n\z/\n/; s/\n*\z/\n/;' "${tmp_render}"

mv "${tmp_render}" "${OUTPUT_FILE}"

echo "Updated ${OUTPUT_FILE} using Cilium chart ${CHART_VERSION}"
