#!/bin/sh
set -eu

work_dir=${WORK_DIR:-.work}
out_file=${1:-"$work_dir/sops-files.txt"}

mkdir -p "$(dirname "$out_file")"
: > "$out_file"

has_top_level_sops_yaml() {
  file=$1
  awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*---[[:space:]]*$/ { next }
    /^sops:[[:space:]]*$/ { found=1; exit 0 }
    END { exit(found ? 0 : 1) }
  ' "$file"
}

has_top_level_sops_json() {
  file=$1
  if command -v jq >/dev/null 2>&1; then
    jq -e 'type == "object" and has("sops")' "$file" >/dev/null 2>&1
  else
    grep -Eq '"sops"[[:space:]]*:' "$file"
  fi
}

has_pattern() {
  pattern=$1
  file=$2
  if command -v rg >/dev/null 2>&1; then
    rg -q "$pattern" "$file"
  else
    grep -Eq "$pattern" "$file"
  fi
}

has_sops_backend_keys() {
  file=$1
  has_pattern '(^|[[:space:]"])(age|pgp|kms|gcp_kms|azure_kv|hc_vault|hc_vault_transit_uri)[[:space:]"]*:' "$file"
}

has_sops_recipients() {
  file=$1
  has_pattern '(^|[[:space:]"])(recipient|fp|arn|resource_id|vault_url|keyvault_url|aad_client_id|hc_vault_transit_uri)[[:space:]"]*:' "$file"
}

tmp_file_list=$(mktemp)
trap 'rm -f "$tmp_file_list"' EXIT HUP INT TERM

find . -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.json' \) \
  ! -path './.git/*' \
  ! -path './docs/*' \
  ! -path './talos/generated/*' \
  ! -path './vendor/*' \
  ! -path './third_party/*' > "$tmp_file_list"

invalid=0
total=0

while IFS= read -r file; do
  [ -n "$file" ] || continue

  has_sops=1
  case "$file" in
    *.yaml|*.yml)
      if has_top_level_sops_yaml "$file"; then
        has_sops=0
      fi
      ;;
    *.json)
      if has_top_level_sops_json "$file"; then
        has_sops=0
      fi
      ;;
  esac

  if [ "$has_sops" -ne 0 ]; then
    continue
  fi

  total=$((total + 1))
  printf '%s\n' "$file" >> "$out_file"

  if ! has_sops_backend_keys "$file"; then
    echo "error: sops metadata has no recipient backend key in $file"
    invalid=$((invalid + 1))
    continue
  fi

  if ! has_sops_recipients "$file"; then
    echo "error: sops metadata has no recipients in $file"
    invalid=$((invalid + 1))
    continue
  fi
done < "$tmp_file_list"

echo "sops-encrypted files discovered: $total"
echo "sops file list: $out_file"

if [ "$invalid" -ne 0 ]; then
  echo "invalid sops files: $invalid"
  exit 1
fi

echo "sops metadata verification passed"
