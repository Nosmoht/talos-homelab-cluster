#!/usr/bin/env bash
# Mechanically enforce parity between the kernel-param-auditor baseline (Layer 1+2+3
# fenced YAML blocks in references/role-baselines.md) and talos/patches/common.yaml.
#
# Inputs (from the workflow's previous step):
#   /tmp/layer1.yaml  /tmp/layer2.yaml  /tmp/layer3.yaml  /tmp/common.yaml
# Each is a yq-extracted map of `<sysctl>: { expected: "<value>", advisory?: bool }`.
#
# Fail conditions (4):
#   (a) sysctl in common.yaml, missing from L1 ∪ L2 ∪ L3 union → "uncovered"
#   (b) sysctl in L3 non-advisory, expected != common.yaml expected → "L3 stale"
#   (c) sysctl in L1 OR L2 AND in common.yaml, expected != common.yaml → "L{1,2} stale vs repo override"
#   (d) sysctl in L3 non-advisory, missing from common.yaml → "L3 declares value with no enforcer"
#
# Whitespace-collapsed tuples already normalized upstream.
set -euo pipefail

L1=/tmp/layer1.yaml
L2=/tmp/layer2.yaml
L3=/tmp/layer3.yaml
COMMON=/tmp/common.yaml

for f in "$L1" "$L2" "$L3" "$COMMON"; do
  [ -s "$f" ] || { echo "::error::missing or empty input: $f"; exit 2; }
done

fail=0
note() { echo "::error::$1"; fail=1; }

# Sets of keys per source.
keys_l1=$(yq e 'keys | .[]' "$L1" | sort -u)
keys_l2=$(yq e 'keys | .[]' "$L2" | sort -u)
keys_l3=$(yq e 'keys | .[]' "$L3" | sort -u)
keys_l3_advisory=$(yq e 'with_entries(select(.value.advisory == true)) | keys | .[]' "$L3" | sort -u)
keys_common=$(yq e 'keys | .[]' "$COMMON" | sort -u)

# (a) common.yaml ∖ (L1 ∪ L2 ∪ L3) — uncovered
union=$(printf '%s\n%s\n%s\n' "$keys_l1" "$keys_l2" "$keys_l3" | sort -u)
uncovered=$(comm -23 <(echo "$keys_common") <(echo "$union") || true)
if [ -n "$uncovered" ]; then
  while IFS= read -r k; do
    [ -n "$k" ] && note "(a) sysctl '$k' in common.yaml is missing from L1∪L2∪L3 baseline (uncovered)"
  done <<< "$uncovered"
fi

# (d) L3 non-advisory ∖ common.yaml — declares value with no enforcer
keys_l3_nonadvisory=$(comm -23 <(echo "$keys_l3") <(echo "$keys_l3_advisory") || true)
orphan_l3=$(comm -23 <(echo "$keys_l3_nonadvisory") <(echo "$keys_common") || true)
if [ -n "$orphan_l3" ]; then
  while IFS= read -r k; do
    [ -n "$k" ] && note "(d) sysctl '$k' is non-advisory in L3 but missing from common.yaml (declared with no enforcer)"
  done <<< "$orphan_l3"
fi

# Helper: compare expected values (whitespace-already-normalized upstream).
compare_value() {
  local layer_label="$1" key="$2" baseline_file="$3" condition_label="$4"
  local exp_baseline exp_common
  exp_baseline=$(yq e ".\"$key\".expected" "$baseline_file")
  exp_common=$(yq e ".\"$key\".expected" "$COMMON")
  if [ "$exp_baseline" != "$exp_common" ]; then
    note "$condition_label sysctl '$key' ($layer_label) baseline expects '$exp_baseline' but common.yaml has '$exp_common'"
  fi
}

# (b) L3 non-advisory ∩ common.yaml — value parity check
while IFS= read -r k; do
  [ -z "$k" ] && continue
  if echo "$keys_common" | grep -qFx -- "$k"; then
    compare_value "L3 cluster-tuning" "$k" "$L3" "(b)"
  fi
done <<< "$keys_l3_nonadvisory"

# (c) L1 ∩ common.yaml — value parity check
while IFS= read -r k; do
  [ -z "$k" ] && continue
  if echo "$keys_common" | grep -qFx -- "$k"; then
    compare_value "L1 universal" "$k" "$L1" "(c)"
  fi
done <<< "$keys_l1"

# (c) L2 ∩ common.yaml — value parity check
while IFS= read -r k; do
  [ -z "$k" ] && continue
  if echo "$keys_common" | grep -qFx -- "$k"; then
    compare_value "L2 talos-kspp" "$k" "$L2" "(c)"
  fi
done <<< "$keys_l2"

if [ "$fail" -eq 0 ]; then
  printf 'sysctl parity OK: L1=%d L2=%d L3=%d (advisory=%d), common.yaml=%d\n' \
    "$(echo "$keys_l1" | grep -c .)" \
    "$(echo "$keys_l2" | grep -c .)" \
    "$(echo "$keys_l3" | grep -c .)" \
    "$(echo "$keys_l3_advisory" | grep -c .)" \
    "$(echo "$keys_common" | grep -c .)"
fi

exit "$fail"
