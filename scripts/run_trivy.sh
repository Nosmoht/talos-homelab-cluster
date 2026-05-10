#!/bin/sh
set -eu

# Single point-of-truth Trivy wrapper used by Makefile and .pre-commit-config.yaml
# so local and CI share identical skip-files + severity gates.
# Per-finding exceptions live in .trivyignore.yaml (auto-discovered by trivy).

work_dir=${WORK_DIR:-.work}
report_file="$work_dir/trivy-report.txt"
severity=${TRIVY_SEVERITY:-HIGH,CRITICAL}

skip_files="kubernetes/bootstrap/cilium/cilium.yaml,kubernetes/overlays/homelab/infrastructure/piraeus-operator/resources/storage-pool-autovg.yaml"

if ! command -v trivy >/dev/null 2>&1; then
  cat >&2 <<EOF
error: trivy not found in PATH

Install via:
  macOS:   brew install aquasecurity/trivy/trivy
  Linux:   see https://aquasecurity.github.io/trivy/latest/getting-started/installation/

Pinned target version: $(cat .trivy-version 2>/dev/null || echo 'unpinned')

Or bypass this hook once with:
  SKIP=trivy-config git commit ...
EOF
  exit 1
fi

expected_version=$(cat .trivy-version 2>/dev/null || echo "")
if [ -n "$expected_version" ]; then
  installed_version="v$(trivy --version 2>/dev/null | awk '/^Version:/ {print $2}')"
  if [ "$installed_version" != "$expected_version" ]; then
    echo "warning: trivy version mismatch (installed: $installed_version, pinned: $expected_version from .trivy-version)" >&2
    echo "         install the pinned version to match CI, or ignore if intentionally testing" >&2
  fi
fi

mkdir -p "$work_dir"

echo "trivy config scan (severity: $severity)"
trivy config \
  --severity "$severity" \
  --exit-code 1 \
  --skip-files "$skip_files" \
  --ignorefile .trivyignore.yaml \
  --format table \
  --output "$report_file" \
  . || status=$?

status=${status:-0}
cat "$report_file"

if [ "$status" -ne 0 ]; then
  echo "trivy: HIGH/CRITICAL findings present" >&2
  exit 1
fi

echo "trivy: no HIGH/CRITICAL findings"
