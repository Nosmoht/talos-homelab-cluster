#!/bin/sh
set -eu

work_dir=${WORK_DIR:-.work}
out_file=${1:-"$work_dir/argocd-applications.txt"}

tmp_file=$(mktemp)
trap 'rm -f "$tmp_file"' EXIT HUP INT TERM

mkdir -p "$(dirname "$out_file")"

append_if_application_doc() {
  file=$1

  if awk '
    function reset_doc() { has_api=0; has_kind=0 }
    function flush_doc() {
      if (has_api && has_kind) {
        found=1
      }
    }
    BEGIN {
      found=0
      reset_doc()
    }
    {
      line=$0
      sub(/[[:space:]]+#.*/, "", line)

      if (line ~ /^[[:space:]]*---[[:space:]]*$/) {
        flush_doc()
        reset_doc()
        next
      }

      if (line ~ /^apiVersion:[[:space:]]*argoproj\.io\//) {
        has_api=1
      }
      if (line ~ /^kind:[[:space:]]*Application[[:space:]]*$/) {
        has_kind=1
      }
    }
    END {
      flush_doc()
      exit(found ? 0 : 1)
    }
  ' "$file"; then
    printf '%s\n' "$file" >> "$tmp_file"
  fi
}

for root in kubernetes/overlays kubernetes/bootstrap; do
  if [ ! -d "$root" ]; then
    echo "notice: root not found, skipping: $root"
    continue
  fi

  find "$root" -type f \( -name 'application.yaml' -o -name '*.application.yaml' \) | while IFS= read -r f; do
    printf '%s\n' "$f" >> "$tmp_file"
  done

  find "$root" -type f \( -name '*.yaml' -o -name '*.yml' \) | while IFS= read -r f; do
    append_if_application_doc "$f"
  done
done

if [ -s "$tmp_file" ]; then
  sort -u "$tmp_file" > "$out_file"
else
  : > "$out_file"
fi

count=$(wc -l < "$out_file" | tr -d ' ')
echo "discovered argocd application files: $count"
if [ "$count" -gt 0 ]; then
  echo "application list: $out_file"
fi
