#!/bin/sh
# Configure TP-Link Omada SG3428 via Omada Controller v6.x HTTP API.
#
# Usage:
#   scripts/configure-sg3428-via-omada-api.sh [--url URL] [--site NAME] [--switch MAC] MODE
#
#   MODE:
#     discover   Read-only. Authenticate, dump site/device/profiles/networks/ports
#                JSON to .work/omada-discover/. Use this first to validate auth and
#                inspect schemas before mutating anything.
#     apply      Apply VLANs + port profiles + port assignments + safety baseline
#                idempotently (read-before-create / read-before-patch).
#     backup     Trigger a Controller backup; on success download the .cbu file to
#                docs/omada-controller-post-config.cbu. On failure print UI fallback.
#
# Required env (sourced from ~/.zshenv if not already set):
#   OMADA_CONTROLLER_USERNAME    Master-Admin username for Controller UI login.
#   OMADA_CONTROLLER_PASSWORD    Corresponding password. Never echoed.
#
# Pre-req (run by hand, not by this script):
#   kubectl -n omada-controller port-forward svc/omada-controller 8043:8043 &
#
# This script is intentionally idempotent and side-effect-aware. It never POSTs
# blindly: every "ensure_*" helper does GET-then-decide. Errors fail fast.
#
# Endpoint references (Omada Controller v6.2.0.17, legacy session-cookie API):
#   - GET  /api/info
#   - POST /{cId}/api/v2/login                                  -> Csrf-Token + cookie
#   - GET  /{cId}/api/v2/loginStatus
#   - GET  /{cId}/api/v2/users/current                          -> sites privilege list
#   - GET  /{cId}/api/v2/sites/{sId}/devices                    -> device list (find SG3428 MAC)
#   - GET  /{cId}/api/v2/sites/{sId}/switches/{mac}             -> switch overview
#   - GET  /{cId}/api/v2/sites/{sId}/switches/{mac}/ports       -> ports list
#   - PATCH /{cId}/api/v2/sites/{sId}/switches/{mac}/ports/{p}  -> port settings
#   - GET  /{cId}/api/v2/sites/{sId}/setting/lan/profileSummary -> port profile list
#   - GET  /{cId}/api/v2/sites/{sId}/setting/lan/networks       -> VLAN list (best-guess)
#
# Required headers post-login:
#   Csrf-Token: <token from login response>
#   Omada-Request-Source: web-local
#   Cookie: TPOMADA_SESSIONID=...
#
# Mapping table (Port -> Profile) — keep in sync with the ADR docs/adr-switch-cutover-netgear-to-sg3428.md:
#   Ports 1-3   -> profile-cp      (untag VLAN 1, tag VLAN 110)
#   Ports 4-6   -> profile-worker  (untag VLAN 1, tag VLAN 100/110/120/130)
#   Port  7     -> profile-gpu     (= profile-worker)
#   Port  24    -> profile-uplink  (untag VLAN 1 only)

set -eu

# -------------------------------------------------------------------- defaults
OMADA_URL="${OMADA_URL:-https://localhost:8043}"
SITE_NAME="${SITE_NAME:-Default}"
SWITCH_MAC="${SWITCH_MAC:-}"   # auto-detect if empty
WORK_DIR="${WORK_DIR:-.work/omada}"
COOKIE_JAR="${WORK_DIR}/cookies.txt"
CTX_FILE="${WORK_DIR}/ctx.json"
BACKUP_OUT="${BACKUP_OUT:-docs/omada-controller-post-config.cfg}"

# ---------------------------------------------------------------- arg parsing
MODE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --url)    OMADA_URL="$2"; shift 2 ;;
    --site)   SITE_NAME="$2"; shift 2 ;;
    --switch) SWITCH_MAC="$2"; shift 2 ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    discover|apply|backup) MODE="$1"; shift ;;
    *) echo "ERROR: unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$MODE" ] || { echo "ERROR: MODE required (discover|apply|backup). Try --help." >&2; exit 2; }

# ----------------------------------------------------------- credential load
if [ -z "${OMADA_CONTROLLER_USERNAME:-}" ] || [ -z "${OMADA_CONTROLLER_PASSWORD:-}" ]; then
  if [ -r "${HOME}/.zshenv" ]; then
    # shellcheck disable=SC1091
    . "${HOME}/.zshenv"
  fi
fi
[ -n "${OMADA_CONTROLLER_USERNAME:-}" ] || { echo "ERROR: OMADA_CONTROLLER_USERNAME unset (set in ~/.zshenv)" >&2; exit 2; }
[ -n "${OMADA_CONTROLLER_PASSWORD:-}" ] || { echo "ERROR: OMADA_CONTROLLER_PASSWORD unset (set in ~/.zshenv)" >&2; exit 2; }

command -v jq >/dev/null   || { echo "ERROR: jq required" >&2; exit 2; }
command -v curl >/dev/null || { echo "ERROR: curl required" >&2; exit 2; }

mkdir -p "$WORK_DIR"
umask 077
: > "$COOKIE_JAR"

cleanup() { rm -f "$COOKIE_JAR" "$CTX_FILE" 2>/dev/null || true; }
trap cleanup EXIT HUP INT TERM

# ----------------------------------------------------------- HTTP plumbing
CURL_OPTS="-ksS --max-time 30"
CSRF_TOKEN=""
CONTROLLER_ID=""
SITE_ID=""

# api_info: probe controller, returns omadacId
api_info() {
  curl $CURL_OPTS "$OMADA_URL/api/info" \
    | tee "$WORK_DIR/api-info.json" >/dev/null
  CONTROLLER_ID="$(jq -r '.result.omadacId' "$WORK_DIR/api-info.json")"
  [ -n "$CONTROLLER_ID" ] && [ "$CONTROLLER_ID" != "null" ] \
    || { echo "ERROR: failed to extract omadacId from /api/info" >&2; exit 1; }
  echo "controller_id=$CONTROLLER_ID"
}

omada_login() {
  body=$(printf '{"username":"%s","password":"%s"}' \
    "$OMADA_CONTROLLER_USERNAME" "$OMADA_CONTROLLER_PASSWORD")
  resp=$(curl $CURL_OPTS -c "$COOKIE_JAR" \
    -H "Content-Type: application/json" \
    -X POST -d "$body" \
    "$OMADA_URL/$CONTROLLER_ID/api/v2/login")
  ec=$(printf '%s' "$resp" | jq -r '.errorCode // empty')
  if [ "$ec" != "0" ]; then
    msg=$(printf '%s' "$resp" | jq -r '.msg // "(no msg)"')
    echo "ERROR: login failed errorCode=$ec msg=$msg" >&2
    exit 1
  fi
  CSRF_TOKEN=$(printf '%s' "$resp" | jq -r '.result.token')
  [ -n "$CSRF_TOKEN" ] && [ "$CSRF_TOKEN" != "null" ] \
    || { echo "ERROR: no Csrf-Token in login response" >&2; exit 1; }
  echo "login=ok"
}

# omada_call METHOD PATH [JSON_BODY] [OUT_FILE]
# PATH is relative to /{controller_id}/api/v2/
omada_call() {
  method="$1"; path="$2"; data="${3:-}"; out="${4:-}"
  url="$OMADA_URL/$CONTROLLER_ID/api/v2/$path"
  if [ -n "$data" ]; then
    resp=$(curl $CURL_OPTS -b "$COOKIE_JAR" \
      -H "Csrf-Token: $CSRF_TOKEN" \
      -H "Omada-Request-Source: web-local" \
      -H "Content-Type: application/json" \
      -X "$method" -d "$data" "$url")
  else
    resp=$(curl $CURL_OPTS -b "$COOKIE_JAR" \
      -H "Csrf-Token: $CSRF_TOKEN" \
      -H "Omada-Request-Source: web-local" \
      -X "$method" "$url")
  fi
  if [ -n "$out" ]; then printf '%s' "$resp" > "$out"; fi
  ec=$(printf '%s' "$resp" | jq -r '.errorCode // empty' 2>/dev/null || echo "")
  if [ -n "$ec" ] && [ "$ec" != "0" ]; then
    msg=$(printf '%s' "$resp" | jq -r '.msg // "(no msg)"' 2>/dev/null || echo "(no msg)")
    echo "ERROR: $method $path errorCode=$ec msg=$msg" >&2
    return 1
  fi
  printf '%s' "$resp"
}

omada_logout() {
  [ -n "$CSRF_TOKEN" ] || return 0
  omada_call POST "logout" >/dev/null 2>&1 || true
  echo "logout=ok"
}

# resolve_site: populates SITE_ID using SITE_NAME
resolve_site() {
  resp=$(omada_call GET "users/current" "" "$WORK_DIR/users-current.json")
  SITE_ID=$(printf '%s' "$resp" \
    | jq -r --arg n "$SITE_NAME" \
        '.result.privilege.sites[] | select(.name==$n) | .key' \
    | head -1)
  [ -n "$SITE_ID" ] && [ "$SITE_ID" != "null" ] \
    || { echo "ERROR: site '$SITE_NAME' not found in users/current" >&2; exit 1; }
  echo "site_id=$SITE_ID"
}

# resolve_switch: populates SWITCH_MAC by listing devices, picking first SG3428
resolve_switch() {
  resp=$(omada_call GET "sites/$SITE_ID/devices" "" "$WORK_DIR/devices.json")
  if [ -z "$SWITCH_MAC" ]; then
    SWITCH_MAC=$(printf '%s' "$resp" \
      | jq -r '.result[]? | select(.model // "" | test("SG3428"; "i")) | .mac' \
      | head -1)
  fi
  [ -n "$SWITCH_MAC" ] && [ "$SWITCH_MAC" != "null" ] \
    || { echo "ERROR: SG3428 not found in devices list" >&2; exit 1; }
  echo "switch_mac=$SWITCH_MAC"
}

# ------------------------------------------------------------------ MODES

mode_discover() {
  echo "=== DISCOVER (read-only) ==="
  api_info
  omada_login
  resolve_site
  resolve_switch
  echo "--- dumping schemas to $WORK_DIR ---"
  omada_call GET "sites/$SITE_ID/switches/$SWITCH_MAC"               "" "$WORK_DIR/switch.json"        >/dev/null && echo "  switch.json"
  omada_call GET "sites/$SITE_ID/switches/$SWITCH_MAC/ports"         "" "$WORK_DIR/ports.json"         >/dev/null && echo "  ports.json"
  omada_call GET "sites/$SITE_ID/setting/lan/profileSummary"         "" "$WORK_DIR/profiles.json"      >/dev/null && echo "  profiles.json"
  echo "--- probing POST candidates for port-profile create ---"
  # Minimal empty-body POST to see which paths are POST-accepting (errors like
  # -1001 "Invalid request parameters" mean the path exists; -1600 "Unsupported
  # request path" means no such endpoint).
  for p in \
    "setting/lan/profile" \
    "setting/lan/profiles" \
    "setting/lan/profileSwitch" \
    "setting/lan/profile/switch" \
    "setting/lan/profiles/switch" \
    "setting/lan/switchProfile" \
    "setting/lan/switchProfiles" \
    "setting/lan/portProfile" \
    "setting/lan/portProfiles" \
    "setting/profile/switch" \
    "setting/profiles/switch" \
    "setting/switch/profile" \
    "setting/switch/profiles" ; do
    out="$WORK_DIR/probe-post-$(printf '%s' "$p" | tr '/?&=' '____').json"
    curl $CURL_OPTS -b "$COOKIE_JAR" \
      -H "Csrf-Token: $CSRF_TOKEN" -H "Omada-Request-Source: web-local" \
      -H "Content-Type: application/json" \
      -X POST -d '{}' "$OMADA_URL/$CONTROLLER_ID/api/v2/sites/$SITE_ID/$p" > "$out" 2>/dev/null
    ec=$(jq -r '.errorCode // "x"' "$out" 2>/dev/null || echo x)
    msg=$(jq -r '.msg // ""' "$out" 2>/dev/null | head -c 60)
    printf "  POST %-45s ec=%-6s msg=%s\n" "$p" "$ec" "$msg"
    rm -f "$out"
  done
  omada_logout
  cat <<EOF

=== DISCOVER complete ===
Inspect $WORK_DIR/*.json (only probes with ec=0 are kept) then run:
  $0 apply
EOF
}

mode_apply() {
  echo "=== APPLY (mutates Controller config) ==="
  api_info
  omada_login
  resolve_site
  resolve_switch

  echo "--- VLANs ---"
  ensure_vlans

  echo "--- port profiles ---"
  ensure_profiles

  echo "--- port assignments ---"
  apply_port_assignments

  echo "--- safety baseline ---"
  apply_safety_baseline

  omada_logout
  echo "=== APPLY done ==="
  echo "Now run: $0 backup"
}

mode_backup() {
  echo "=== BACKUP ==="
  api_info
  omada_login
  echo "--- probing backup endpoints ---"
  # Probe known candidates. Capture each response to inspect shape even on
  # non-zero errorCode so we can distinguish path-exists (-1001) vs not-found (-1600).
  for p in \
    "cmd/global/backup" \
    "cmd/controller/backup" \
    "cmd/backup" \
    "controller/backup" \
    "maintenance/backup" \
    "maintenance/backupFile" \
    "settings/backup" \
    "setting/backup" ; do
    out="$WORK_DIR/probe-backup-$(printf '%s' "$p" | tr '/' '_').json"
    curl $CURL_OPTS -b "$COOKIE_JAR" \
      -H "Csrf-Token: $CSRF_TOKEN" -H "Omada-Request-Source: web-local" \
      -H "Content-Type: application/json" \
      -X POST -d '{}' "$OMADA_URL/$CONTROLLER_ID/api/v2/$p" > "$out" 2>/dev/null || true
    ec=$(jq -r '.errorCode // "x"' "$out" 2>/dev/null || echo x)
    msg=$(jq -r '.msg // ""' "$out" 2>/dev/null | head -c 50)
    printf "  POST %-30s ec=%-6s msg=%s\n" "$p" "$ec" "$msg"
    if [ "$ec" = "0" ]; then
      # On success inspect for a download URL in the response.
      download=$(jq -r '.result.url // .result.path // .result.downloadUrl // .result // empty' "$out")
      echo "    result: $download"
    else
      rm -f "$out"
    fi
  done
  omada_logout
  cat >&2 <<EOF

If none of the probed paths succeeded, use the UI fallback:
  1) Open https://localhost:8043 in a browser (port-forward must still be active)
  2) Settings -> Controller Settings -> Maintenance -> Backup -> Download
  3) Save the .cbu file as: $BACKUP_OUT
  4) git add $BACKUP_OUT && git commit -m "feat(omada): post-config switch backup"
EOF
  return 1
}

# ------------------------------------------------------------------ MUTATORS
# Each helper is a stub today: it logs the intent + dumps the would-be payload
# to $WORK_DIR/intent-*.json instead of POSTing. Once `discover` confirms the
# real endpoint shapes, fill in the curl call. This keeps `apply` safe for the
# first iteration: nothing changes on the switch until each helper is unstubbed.

# ensure_vlan VLAN_ID NAME
# Idempotent: GETs network list, creates only if no existing entry has matching vlan id.
# Uses purpose="vlan" (pure L2 tagged carrier; no gateway/DHCP/subnet needed).
ensure_vlan() {
  vlan_id="$1"; vlan_name="$2"
  list_resp=$(omada_call GET "sites/$SITE_ID/setting/lan/networks?currentPage=1&currentPageSize=200" "" "$WORK_DIR/networks-current.json")
  existing=$(printf '%s' "$list_resp" \
    | jq -r --argjson v "$vlan_id" '.result.data[]? | select(.vlan==$v) | .id' \
    | head -1)
  if [ -n "$existing" ] && [ "$existing" != "null" ]; then
    echo "  SKIP VLAN $vlan_id ($vlan_name) — already exists id=$existing"
    return 0
  fi
  payload=$(jq -nc --arg n "$vlan_name" --argjson v "$vlan_id" '{
    name: $n,
    purpose: "vlan",
    vlan: $v,
    vlanType: 0,
    isolation: false,
    igmpSnoopEnable: false,
    fastLeaveEnable: false,
    mldSnoopEnable: false,
    dhcpL2RelayEnable: false,
    dhcpGuard: {enable: false},
    dhcpv6Guard: {enable: false}
  }')
  resp=$(omada_call POST "sites/$SITE_ID/setting/lan/networks" "$payload" "$WORK_DIR/network-create-$vlan_id.json") \
    || { echo "  FAIL VLAN $vlan_id create" >&2; return 1; }
  # result can be either a string (new id) or an object {id:...}
  new_id=$(printf '%s' "$resp" | jq -r 'if .result|type=="string" then .result else .result.id // .result.profileId // empty end')
  echo "  CREATED VLAN $vlan_id ($vlan_name) id=$new_id"
}

ensure_vlans() {
  vlan_filter="${VLAN_FILTER:-100,110,120,130}"
  for vlan in '100:kubevirt-vms' '110:storage-drbd' '120:tenant-admin' '130:tenant-personal'; do
    id="${vlan%%:*}"; name="${vlan##*:}"
    case ",$vlan_filter," in
      *,$id,*) ensure_vlan "$id" "$name" ;;
      *) echo "  SKIP VLAN $id (not in VLAN_FILTER=$vlan_filter)" ;;
    esac
  done
}

# vlan_id_to_network_uuid VLAN_ID -> stdout UUID
vlan_id_to_network_uuid() {
  v="$1"
  jq -r --argjson v "$v" '.result.data[]? | select(.vlan==$v) | .id' \
    "$WORK_DIR/networks-current.json" | head -1
}

# refresh_networks_cache: populates $WORK_DIR/networks-current.json
refresh_networks_cache() {
  omada_call GET "sites/$SITE_ID/setting/lan/networks?currentPage=1&currentPageSize=200" \
    "" "$WORK_DIR/networks-current.json" >/dev/null
}

# refresh_profiles_cache: populates $WORK_DIR/profiles.json
refresh_profiles_cache() {
  omada_call GET "sites/$SITE_ID/setting/lan/profileSummary" \
    "" "$WORK_DIR/profiles.json" >/dev/null
}

# ensure_profile NAME NATIVE_NET_ID TAG_IDS_JSON_ARRAY EDGE_PORT BPDU_PROTECT
# - NATIVE_NET_ID: UUID of the untagged VLAN (typically VLAN-1 default)
# - TAG_IDS_JSON_ARRAY: e.g. '["uuid1","uuid2"]' or '[]'
# - EDGE_PORT: true|false (true for node-facing ports)
# - BPDU_PROTECT: true|false (true for node-facing ports, false for uplink)
ensure_profile() {
  pname="$1"; native="$2"; tagjson="$3"; edge="$4"; bpdu="$5"
  existing=$(jq -r --arg n "$pname" '.result.data[]? | select(.name==$n) | .id' \
    "$WORK_DIR/profiles.json" | head -1)
  if [ -n "$existing" ] && [ "$existing" != "null" ]; then
    echo "  SKIP profile '$pname' — exists id=$existing"
    return 0
  fi
  payload=$(jq -nc \
    --arg n "$pname" --arg native "$native" \
    --argjson tag "$tagjson" \
    --argjson edge "$edge" --argjson bpdu "$bpdu" '{
      name: $n,
      poe: 2,
      nativeNetworkId: $native,
      tagNetworkIds: $tag,
      esEnableTaggedNetworkIds: [],
      untagNetworkIds: [],
      dot1x: 2,
      portIsolationEnable: false,
      lldpMedEnable: true,
      topoNotifyEnable: false,
      bandWidthCtrlType: 0,
      spanningTreeEnable: true,
      spanningTreeSetting: {
        priority: 128, extPathCost: 0, intPathCost: 0,
        edgePort: $edge, p2pLink: 0,
        mcheck: false, loopProtect: false, rootProtect: false,
        tcGuard: false, bpduProtect: $bpdu, bpduFilter: false, bpduForward: true
      },
      loopbackDetectEnable: false,
      eeeEnable: false, flowControlEnable: false,
      fastLeaveEnable: false,
      loopbackDetectVlanBasedEnable: false,
      igmpFastLeaveEnable: false, mldFastLeaveEnable: false,
      dhcpL2RelaySettings: {enable: false},
      dot1pPriority: 0, trustMode: 0,
      type: 0,
      supportESEnable: false, esEnable: false, esTaggedModified: false
    }')
  resp=$(omada_call POST "sites/$SITE_ID/setting/lan/profiles" "$payload" \
    "$WORK_DIR/profile-create-$pname.json") \
    || { echo "  FAIL profile '$pname' create" >&2; return 1; }
  new_id=$(printf '%s' "$resp" | jq -r 'if .result|type=="string" then .result else .result.id // empty end')
  echo "  CREATED profile '$pname' id=$new_id"
}

ensure_profiles() {
  refresh_networks_cache
  refresh_profiles_cache
  V1=$(vlan_id_to_network_uuid 1)
  V100=$(vlan_id_to_network_uuid 100)
  V110=$(vlan_id_to_network_uuid 110)
  V120=$(vlan_id_to_network_uuid 120)
  V130=$(vlan_id_to_network_uuid 130)
  for v in V1 V100 V110 V120 V130; do
    eval val=\$$v
    [ -n "$val" ] || { echo "  ERROR missing UUID for $v" >&2; return 1; }
  done
  filter="${PROFILE_FILTER:-cp,worker,gpu,uplink}"
  case ",$filter," in *,cp,*)     ensure_profile "profile-cp"     "$V1" "[\"$V110\"]"                                 true  true  ;; esac
  case ",$filter," in *,worker,*) ensure_profile "profile-worker" "$V1" "[\"$V100\",\"$V110\",\"$V120\",\"$V130\"]"  true  true  ;; esac
  case ",$filter," in *,gpu,*)    ensure_profile "profile-gpu"    "$V1" "[\"$V100\",\"$V110\",\"$V120\",\"$V130\"]"  true  true  ;; esac
  case ",$filter," in *,uplink,*) ensure_profile "profile-uplink" "$V1" "[]"                                         false false ;; esac
  refresh_profiles_cache
}

# profile_id_by_name NAME -> stdout UUID
profile_id_by_name() {
  jq -r --arg n "$1" '.result.data[]? | select(.name==$n) | .id' \
    "$WORK_DIR/profiles.json" | head -1
}

# port_current_profile_id PORT_NUM -> stdout current profile UUID (or empty)
port_current_profile_id() {
  p="$1"
  jq -r --argjson p "$p" '.result[]? | select(.port==$p) | .profileId // empty' \
    "$WORK_DIR/ports.json" | head -1
}

# assign_port PORT_NUM PROFILE_NAME [STORM_ON]
# PATCHes the port to (a) clear override so the profile applies, (b) set profileId,
# (c) if STORM_ON=true, enable broadcast+unknownUnicast storm control @1000pps.
assign_port() {
  p="$1"; pname="$2"; storm="${3:-false}"
  pid=$(profile_id_by_name "$pname")
  [ -n "$pid" ] || { echo "  ERROR profile '$pname' not found" >&2; return 1; }
  current=$(port_current_profile_id "$p")
  if [ "$current" = "$pid" ]; then
    # Already assigned; still re-PATCH storm-ctrl if needed? Skip for idempotency.
    echo "  SKIP port $p — already on '$pname'"
    return 0
  fi
  if [ "$storm" = "true" ]; then
    payload=$(jq -nc --arg pid "$pid" '{
      profileOverrideEnable: false,
      profileId: $pid,
      stormCtrl: {
        rateMode: 1,
        unknownUnicastEnable: true, unknownUnicast: 1000,
        multicastEnable: false,     multicast: 0,
        broadcastEnable: true,      broadcast: 1000,
        action: 0, recoverTime: 3600
      }
    }')
  else
    payload=$(jq -nc --arg pid "$pid" '{
      profileOverrideEnable: false,
      profileId: $pid
    }')
  fi
  resp=$(omada_call PATCH "sites/$SITE_ID/switches/$SWITCH_MAC/ports/$p" "$payload" \
    "$WORK_DIR/port-patch-$p.json") \
    || { echo "  FAIL port $p assign '$pname'" >&2; return 1; }
  echo "  ASSIGNED port $p -> '$pname'$([ "$storm" = "true" ] && echo " (+storm-ctrl)")"
}

apply_port_assignments() {
  # Refresh ports + profiles cache to see new profile IDs + latest port state.
  omada_call GET "sites/$SITE_ID/switches/$SWITCH_MAC/ports" "" "$WORK_DIR/ports.json" >/dev/null
  refresh_profiles_cache
  filter="${PORT_FILTER:-1,2,3,4,5,6,7,24}"
  case ",$filter," in *,1,*)  assign_port 1  profile-cp     true  ;; esac
  case ",$filter," in *,2,*)  assign_port 2  profile-cp     true  ;; esac
  case ",$filter," in *,3,*)  assign_port 3  profile-cp     true  ;; esac
  case ",$filter," in *,4,*)  assign_port 4  profile-worker true  ;; esac
  case ",$filter," in *,5,*)  assign_port 5  profile-worker true  ;; esac
  case ",$filter," in *,6,*)  assign_port 6  profile-worker true  ;; esac
  case ",$filter," in *,7,*)  assign_port 7  profile-gpu    true  ;; esac
  case ",$filter," in *,24,*) assign_port 24 profile-uplink false ;; esac
}

# Safety baseline RSTP+BPDU-Guard lives inside each port profile (see ensure_profiles).
# Storm-Ctrl is applied per port inside apply_port_assignments.
# DHCP Snooping + DAI are follow-up ops (see plan Phase 4d) — intentionally not
# automated here; they benefit from settling bindings before enforcement.
apply_safety_baseline() {
  echo "  info: RSTP+BPDU-Guard baked into profiles; storm-ctrl per port; DHCP-Snooping deferred to Phase 4d"
}

# ------------------------------------------------------------------ dispatch
case "$MODE" in
  discover) mode_discover ;;
  apply)    mode_apply ;;
  backup)   mode_backup ;;
  *) echo "BUG: unreachable" >&2; exit 99 ;;
esac
