# shellcheck shell=bash
# tools/mac/lib/common.sh — shared helpers for ios_run.sh and build_ios_ext.sh.
#
# Written for the bash that ships with macOS (3.2): no associative arrays, no mapfile, no ${x,,}, and every
# possibly-empty array is expanded as ${arr[@]+"${arr[@]}"} (bash < 4.4 treats "${arr[@]}" of an empty array
# as unbound under `set -u`). BSD userland: no `sed -i`, no `timeout`, no `readlink -f`, `shasum` not `sha512sum`.

# Pins (docs/NATIVE_PORT.md 1-2: container, Mac and CI run exactly this engine).
LANE1_GODOT_VERSION="4.7.2"
LANE1_GODOT_VERSION_CONFIG="4.7.2.stable"
LANE1_GODOT_RELEASE_URL="https://github.com/godotengine/godot/releases/download/4.7.2-stable"
LANE1_GODOT_MAC_ZIP="Godot_v4.7.2-stable_macos.universal.zip"
LANE1_GODOT_TPZ="Godot_v4.7.2-stable_export_templates.tpz"
# From ${LANE1_GODOT_RELEASE_URL}/SHA512-SUMS.txt (fetched 2026-10-13).
LANE1_GODOT_MAC_ZIP_SHA512="38aa16e5bba2083941fc5b3e54be0089bd4cc35e32415f5b9fd9a8a6a7b9818255d44532ea8ef94b5aef56c4b407c2d634fa4f657e4ebe681ebbf59b7bac69ca"
LANE1_GODOT_TPZ_SHA512="ca4d71c4d7b81dfc15d1a98baa07534aa95b03fdda78a0075b06672e1648d2e5f40980c9adc28d23e1b92e732ee7bf3461997aa804af74ec2fcd7a93ccb84079"
# Placeholder written into native/export_presets.cfg (Godot requires a non-empty Team ID to export); the real
# team is passed to xcodebuild as DEVELOPMENT_TEAM and patched into the generated project.
LANE1_TEAM_PLACEHOLDER="LANE1TEAM0"
LANE1_DEFAULT_BUNDLE_ID="com.ffogtive.lane1Chamgyoyuk"

LANE1_ROOT=${LANE1_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}
LANE1_NATIVE="$LANE1_ROOT/native"
LANE1_HOME=${LANE1_HOME:-"$HOME/.lane1"}

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  _C_RED=$'\033[31m' _C_YEL=$'\033[33m' _C_GRN=$'\033[32m' _C_BLD=$'\033[1m' _C_OFF=$'\033[0m'
else
  _C_RED='' _C_YEL='' _C_GRN='' _C_BLD='' _C_OFF=''
fi

log() { printf '%s[%s]%s %s\n' "$_C_BLD" "${LANE1_LOG_TAG:-lane1}" "$_C_OFF" "$*"; }
ok() { printf '%s[%s] ✅%s %s\n' "$_C_GRN" "${LANE1_LOG_TAG:-lane1}" "$_C_OFF" "$*"; }
warn() { printf '%s[%s] ⚠️  %s%s\n' "$_C_YEL" "${LANE1_LOG_TAG:-lane1}" "$*" "$_C_OFF" >&2; }
# die <exit-code> <message...>: one actionable message, then exit. Codes: 2 usage, 3 environment, 4 build, 5 device.
die() {
  local code=$1
  shift
  printf '%s[%s] ❌ %s%s\n' "$_C_RED" "${LANE1_LOG_TAG:-lane1}" "$*" "$_C_OFF" >&2
  exit "$code"
}
# hint <line...>: indented follow-up lines for warn/die (printed to stderr).
hint() {
  local line
  for line in "$@"; do printf '      %s\n' "$line" >&2; done
}

have() { command -v "$1" >/dev/null 2>&1; }
is_macos() { [ "$(uname -s)" = "Darwin" ]; }

# version_ge <a> <b>: true when dotted version a >= b (numeric, missing parts = 0).
version_ge() {
  local a=$1 b=$2 i x y
  local IFS=.
  # shellcheck disable=SC2206
  local -a av=($a) bv=($b)
  for i in 0 1 2 3; do
    x=${av[$i]:-0}
    y=${bv[$i]:-0}
    x=${x%%[!0-9]*}
    y=${y%%[!0-9]*}
    x=${x:-0}
    y=${y:-0}
    if [ "$x" -gt "$y" ]; then return 0; fi
    if [ "$x" -lt "$y" ]; then return 1; fi
  done
  return 0
}

# sha512_of <file>
sha512_of() {
  if have shasum; then
    shasum -a 512 "$1" | awk '{print $1}'
  elif have sha512sum; then
    sha512sum "$1" | awk '{print $1}'
  else
    die 3 "shasum/sha512sum not found (needed to verify downloads)"
  fi
}

# Stage timer: stage_begin <label>; ...; stage_end  -> records "label=Ns" into LANE1_STAGE_TIMES.
LANE1_STAGE_TIMES=""
_stage_label=""
_stage_t0=0
stage_begin() {
  _stage_label=$1
  _stage_t0=$SECONDS
  printf '\n%s== %s%s\n' "$_C_BLD" "$1" "$_C_OFF"
}
stage_end() {
  local dt=$((SECONDS - _stage_t0))
  LANE1_STAGE_TIMES="${LANE1_STAGE_TIMES}${_stage_label%% *}=${dt}s "
}

# ask <prompt> -> REPLY (empty when not interactive or LANE1_YES=1).
ask() {
  REPLY=""
  if [ "${LANE1_YES:-0}" = 1 ] || [ ! -t 0 ]; then
    return 1
  fi
  printf '%s[%s] ❓ %s%s ' "$_C_YEL" "${LANE1_LOG_TAG:-lane1}" "$1" "$_C_OFF"
  read -r REPLY || REPLY=""
  return 0
}

# Export the ${LANE1_ROOT}-relative path of $1 for messages.
rel() {
  case "$1" in
    "$LANE1_ROOT"/*) printf '%s' "${1#"$LANE1_ROOT"/}" ;;
    *) printf '%s' "$1" ;;
  esac
}
