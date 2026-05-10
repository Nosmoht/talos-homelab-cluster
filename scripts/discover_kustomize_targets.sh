#!/bin/sh
set -eu

work_dir=${WORK_DIR:-.work}
out_file=${1:-"$work_dir/kustomize-targets.txt"}

tmp_file=$(mktemp)
trap 'rm -f "$tmp_file"' EXIT HUP INT TERM

mkdir -p "$(dirname "$out_file")"

append_targets_from_root() {
  root=$1

  if [ ! -d "$root" ]; then
    echo "notice: root not found, skipping: $root"
    return
  fi

  find "$root" -type f \( -iname 'kustomization.yaml' -o -iname 'kustomization' \) | while IFS= read -r kfile; do
    dir=$(dirname "$kfile")

    case "$dir" in
      kubernetes/base/*|*/.git/*|docs/*|*/docs/*|talos/generated/*|*/talos/generated/*|vendor/*|*/vendor/*|third_party/*|*/third_party/*)
        continue
        ;;
    esac

    case "/$dir/" in
      */resources/*)
        continue
        ;;
    esac

    printf '%s\n' "$dir" >> "$tmp_file"
  done
}

append_targets_from_root "kubernetes/overlays"
append_targets_from_root "kubernetes/bootstrap"

if [ -s "$tmp_file" ]; then
  sort -u "$tmp_file" > "$out_file"
else
  : > "$out_file"
fi

count=$(wc -l < "$out_file" | tr -d ' ')
echo "discovered kustomize targets: $count"
if [ "$count" -gt 0 ]; then
  echo "target list: $out_file"
fi
