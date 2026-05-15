#!/usr/bin/env bash
# audit-namespace-dual-ownership.sh
#
# Compare every Namespace declared in
# kubernetes/overlays/homelab/infrastructure/namespaces-psa.yaml against
# the corresponding vendor/base/.../namespace.yaml shipped by the OCI base.
#
# For each NS, classify the conflict and print the label diff so a per-NS
# reconciliation decision can be made before Phase D cutover.
#
# Categories:
#   NO_VENDOR    — psa-only owns the NS (no conflict)
#   VENDOR_ONLY  — vendor-only (psa missing)
#   IDENTICAL    — same labels both sides
#   VENDOR_EX    — vendor adds keys absent in psa (typically provide.*)
#   PSA_EXTRA    — psa adds keys absent in vendor (typically consume.*, PSA labels)
#   BOTH_EXTRA   — both sides add disjoint keys
#   CONFLICT     — same key, different value (HARD — must resolve)
#
# Compatible with macOS bash 3.2 (no associative arrays).
#
# Usage: ./scripts/audit-namespace-dual-ownership.sh [--verbose]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PSA_FILE="${REPO_ROOT}/kubernetes/overlays/homelab/infrastructure/namespaces-psa.yaml"
VENDOR_DIR="${REPO_ROOT}/vendor/base/kubernetes/base/infrastructure"

VERBOSE=0
[ "${1:-}" = "--verbose" ] && VERBOSE=1

command -v yq >/dev/null || { echo "yq required" >&2; exit 1; }
yq --version 2>&1 | grep -q "mikefarah" || {
  echo "error: mikefarah/yq required (got: $(yq --version 2>&1))" >&2
  exit 1
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/psa" "$WORK/vendor"

# --- collect PSA labels: one file per NS named $WORK/psa/<ns>.lbl
psa_namespaces=$(yq eval-all '.metadata.name' "$PSA_FILE" | grep -v '^---$' | grep -v '^$')
for ns in $psa_namespaces; do
  yq eval-all "select(.metadata.name == \"$ns\") | .metadata.labels | to_entries | .[] | .key + \"=\" + (.value | tostring)" "$PSA_FILE" \
    | sort > "$WORK/psa/$ns.lbl"
done

# --- collect VENDOR labels + remember ALL component(s) shipping each ns
for f in "${VENDOR_DIR}"/*/namespace.yaml; do
  ns=$(yq eval '.metadata.name' "$f")
  comp=$(basename "$(dirname "$f")")
  # First component wins for label-content; track all comps for visibility.
  if [ ! -f "$WORK/vendor/$ns.lbl" ]; then
    yq eval '.metadata.labels | to_entries | .[] | .key + "=" + (.value | tostring)' "$f" \
      | sort > "$WORK/vendor/$ns.lbl"
  fi
  if [ -f "$WORK/vendor/$ns.comp" ]; then
    printf ',%s' "$comp" >> "$WORK/vendor/$ns.comp"
  else
    printf '%s' "$comp" > "$WORK/vendor/$ns.comp"
  fi
done

# --- enumerate union of ns names (files only, not dir headers)
all_ns=$( (cd "$WORK/psa" && ls -1 *.lbl 2>/dev/null; cd "$WORK/vendor" && ls -1 *.lbl 2>/dev/null) \
  | sed 's/\.lbl$//' | sort -u )

printf '%-28s %-12s %-22s %s\n' "NAMESPACE" "CATEGORY" "VENDOR_COMPONENT" "NOTES"
printf '%-28s %-12s %-22s %s\n' "---------" "--------" "----------------" "-----"

no_vendor=0; identical=0; vendor_ex=0; psa_extra=0; both_extra=0; conflict=0; vendor_only=0

for ns in $all_ns; do
  pf="$WORK/psa/$ns.lbl"
  vf="$WORK/vendor/$ns.lbl"
  cf="$WORK/vendor/$ns.comp"
  vcomp="—"; [ -f "$cf" ] && vcomp=$(cat "$cf")

  if [ ! -f "$vf" ]; then
    cat=NO_VENDOR; notes="psa-only"; no_vendor=$((no_vendor+1))
  elif [ ! -f "$pf" ]; then
    cat=VENDOR_ONLY; notes="psa missing"; vendor_only=$((vendor_only+1))
  elif diff -q "$pf" "$vf" >/dev/null 2>&1; then
    cat=IDENTICAL; notes="—"; identical=$((identical+1))
  else
    pkeys=$(cut -d= -f1 "$pf")
    vkeys=$(cut -d= -f1 "$vf")
    only_p=$(comm -23 <(echo "$pkeys") <(echo "$vkeys"))
    only_v=$(comm -13 <(echo "$pkeys") <(echo "$vkeys"))
    common=$(comm -12 <(echo "$pkeys") <(echo "$vkeys"))

    conflict_keys=""
    while IFS= read -r k; do
      [ -z "$k" ] && continue
      pv=$(grep "^${k}=" "$pf" | head -1 | cut -d= -f2-)
      vv=$(grep "^${k}=" "$vf" | head -1 | cut -d= -f2-)
      [ "$pv" != "$vv" ] && conflict_keys="${conflict_keys}${k}(psa=${pv}|vnd=${vv}) "
    done <<< "$common"

    np=$(echo -n "$only_p" | grep -c . || true)
    nv=$(echo -n "$only_v" | grep -c . || true)

    if [ -n "$conflict_keys" ]; then
      cat=CONFLICT; notes="$conflict_keys"; conflict=$((conflict+1))
    elif [ "$np" -gt 0 ] && [ "$nv" -gt 0 ]; then
      cat=BOTH_EXTRA; notes="psa+${np} vendor+${nv}"; both_extra=$((both_extra+1))
    elif [ "$nv" -gt 0 ]; then
      cat=VENDOR_EX; notes="vendor+${nv}"; vendor_ex=$((vendor_ex+1))
    else
      cat=PSA_EXTRA; notes="psa+${np}"; psa_extra=$((psa_extra+1))
    fi
  fi

  printf '%-28s %-12s %-22s %s\n' "$ns" "$cat" "$vcomp" "$notes"

  if [ $VERBOSE -eq 1 ] && [ "$cat" != "NO_VENDOR" ] && [ "$cat" != "IDENTICAL" ] && [ "$cat" != "VENDOR_ONLY" ]; then
    [ -n "$only_p" ] && echo "    psa-only:    $(echo "$only_p" | tr '\n' ',' | sed 's/,$//')"
    [ -n "$only_v" ] && echo "    vendor-only: $(echo "$only_v" | tr '\n' ',' | sed 's/,$//')"
  fi
done

echo ""
echo "=== SUMMARY ==="
printf "  %-12s %2d  %s\n" "NO_VENDOR"   "$no_vendor"   "psa-only — no migration impact"
printf "  %-12s %2d  %s\n" "VENDOR_ONLY" "$vendor_only" "vendor-only — psa would need to add"
printf "  %-12s %2d  %s\n" "IDENTICAL"   "$identical"   "no action"
printf "  %-12s %2d  %s\n" "VENDOR_EX"   "$vendor_ex"   "vendor adds (typically provide.*) → psa yields ownership OR mirrors"
printf "  %-12s %2d  %s\n" "PSA_EXTRA"   "$psa_extra"   "psa adds (PSA, consume.*) → either patch on top of vendor OR psa keeps ownership"
printf "  %-12s %2d  %s\n" "BOTH_EXTRA"  "$both_extra"  "both add disjoint → explicit merge strategy needed"
printf "  %-12s %2d  %s\n" "CONFLICT"    "$conflict"    "value conflict — HARD; must resolve before cutover"
