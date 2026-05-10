#!/bin/sh
set -eu

work_dir=${WORK_DIR:-.work}
policy_dir=${POLICY_DIR:-policies/conftest}
rendered_list=${1:-"$work_dir/kustomize-rendered-files.txt"}
apps_list=${2:-"$work_dir/argocd-applications.txt"}
rendered_report="$work_dir/conftest-rendered.txt"
apps_report="$work_dir/conftest-applications.txt"

if [ ! -d "$policy_dir" ]; then
  echo "error: policy directory not found: $policy_dir"
  exit 1
fi

mkdir -p "$work_dir"
rm -f "$rendered_report" "$apps_report"

status=0

run_conftest_for_list() {
  label=$1
  list_file=$2
  report_file=$3

  if [ ! -f "$list_file" ]; then
    echo "notice: $label list not found, skipping: $list_file"
    : > "$report_file"
    return
  fi

  set --
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    set -- "$@" "$f"
  done < "$list_file"

  if [ "$#" -eq 0 ]; then
    echo "notice: no $label files to test"
    : > "$report_file"
    return
  fi

  echo "conftest: testing $label files ($#)"
  if conftest test --all-namespaces --policy "$policy_dir" "$@" > "$report_file" 2>&1; then
    cat "$report_file"
  else
    cat "$report_file"
    status=1
  fi
}

run_conftest_for_list "rendered" "$rendered_list" "$rendered_report"
run_conftest_for_list "argocd application" "$apps_list" "$apps_report"

if [ "$status" -ne 0 ]; then
  echo "conftest policy checks failed"
  exit 1
fi

echo "conftest policy checks passed"
