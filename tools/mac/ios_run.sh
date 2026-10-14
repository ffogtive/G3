#!/bin/bash
# ios_run.sh — ONE command on the Mac: native/ (Godot 4.7.2) -> Xcode project -> signed .app -> installed and
# launched on the paired iPhone. Mechanics follow the user's proven deploy guide (docs/IPHONE_DEPLOY.md, §5):
# xcodebuild Debug for generic/platform=iOS with automatic signing, codesign + bundle-id check, devicectl
# install + launch, one run directory per attempt, a mkdir lock, never uninstalling the existing app.
#
# 가설: ❓ (Mac 미검증) iPhone을 Mac에 꽂고 Xcode에 Apple ID로 한 번 로그인해 두면(무료 Personal Team 가능,
#       7일 프로비저닝) 이 명령 하나로 10분 안에 게임이 iPhone에서 뜬다. 첫 실행만 Godot 4.7.2와 export
#       템플릿(~1.3 GB)을 받는다.
#
# Usage: tools/mac/ios_run.sh [options]
#   --release          Godot release export + Xcode Release configuration (still development-signed)
#   --clean            fresh DerivedData, export and extension builds (never touches the app on the phone)
#   --device <id>      device UDID / CoreDevice identifier / name (default: the single paired iPhone)
#   --no-ext           skip native/ext (traffic) iOS build; a stub keeps the export working
#   --launch-only      only (re)launch the installed app (e.g. after the 'Untrusted Developer' trust step)
#   --check            preflight only: Xcode, Godot, templates, Team ID, device, Developer Mode; changes nothing
#   --yes              never prompt (CI/runner); ambiguous Team ID or device then fails with the list
#   -h, --help
# Overrides (never stored in the repo): env LANE1_TEAM_ID, LANE1_DEVICE_ID, GODOT, or the same KEY=VALUE lines in
# ~/.lane1/deploy.env (chmod 600). A Team ID chosen interactively is cached there.
# Outputs: <repo>/.local/ (gitignored): iphone-deploy/ (DerivedData), ios-export/, deploy-runs/<ts>-<pid>/
#          (build.log, install.json, launch.json, exit-code, receipt.txt, ...), iphone-deploy.lock (while running).
# Exit: 0 launched and still running after 8 s (or, if the process list can't be read, a fresh boot.txt from this launch)
#       | 2 usage | 3 environment | 4 build/export | 5 device | 6 install | 7 launch failed or not verifiable | 9 locked.
set -euo pipefail
# Not `umask 077` for the whole run (guide §5 does that): build outputs keep normal modes so the app bundle's
# files stay readable after install; the run logs live in a 700 directory and ~/.lane1/deploy.env is chmod 600.

LANE1_LOG_TAG=ios_run
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=tools/mac/lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

BUNDLE_ID=$LANE1_DEFAULT_BUNDLE_ID # == application/bundle_identifier in native/export_presets.cfg
SCHEME=lane1                       # export path basename -> lane1.xcodeproj, scheme lane1, PRODUCT_NAME lane1
PRODUCT=lane1.app
PRESET=iOS
XCODE_MIN=16.0         # devicectl JSON + iOS 18 SDK. Xcode 27.x is the expected version (see docs/IPHONE_DEPLOY.md).
IOS_DEVICE_MIN=17.0    # Xcode 27 "Device support: iOS 17 or later" (developer.apple.com/support/xcode)
PLISTBUDDY=${PLISTBUDDY:-/usr/libexec/PlistBuddy}

LOCAL_DIR="$LANE1_ROOT/.local"
DERIVED="$LOCAL_DIR/iphone-deploy"
EXPORT_ROOT="$LOCAL_DIR/ios-export"
LOCK="$LOCAL_DIR/iphone-deploy.lock"
ENV_FILE="$LANE1_HOME/deploy.env"
TPL_DIR="$HOME/Library/Application Support/Godot/export_templates/$LANE1_GODOT_VERSION_CONFIG"

RELEASE=0 CLEAN=0 NO_EXT=0 LAUNCH_ONLY=0 CHECK_ONLY=0 DEVICE_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --release) RELEASE=1 ;;
    --clean) CLEAN=1 ;;
    --device)
      [ $# -ge 2 ] || die 2 "--device needs a value (UDID, identifier or name; see: xcrun devicectl list devices)"
      DEVICE_ARG=$2
      shift
      ;;
    --device=*) DEVICE_ARG=${1#--device=} ;;
    --no-ext) NO_EXT=1 ;;
    --launch-only) LAUNCH_ONLY=1 ;;
    --check) CHECK_ONLY=1 ;;
    --yes) LANE1_YES=1 ;;
    -h | --help)
      sed -n '2,24p' "$0"
      exit 0
      ;;
    *) die 2 "unknown option: $1 (see --help)" ;;
  esac
  shift
done
export LANE1_YES=${LANE1_YES:-0}

if [ "$RELEASE" = 1 ]; then
  CONFIG=Release KIND=release
else
  CONFIG=Debug KIND=debug
fi

is_macos || die 3 "ios_run.sh runs on the Mac (needs Xcode). In the Linux container use:" \
  "bash tools/mac/build_ios_ext.sh --container-stubs && godot47 --headless --path native --export-debug iOS <dir>/lane1.xcodeproj" \
  "(docs/MOBILE_BUILD.md, '컨테이너에서 확인한 것')"

# ---------------------------------------------------------------------------------------------------------------
# Run directory + lock (guide §5). The lock is only ever removed by the run that created it.
RUN_DIR="$LOCAL_DIR/deploy-runs/$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$LOCAL_DIR" "$RUN_DIR"
chmod 700 "$LOCAL_DIR/deploy-runs" "$RUN_DIR"
if ! mkdir "$LOCK" 2>/dev/null; then
  printf '9\n' >"$RUN_DIR/exit-code"
  die 9 "another deploy holds $(rel "$LOCK") — check whether it is still running:" \
    "cat '$LOCK/owner'; ps -p <pid>" \
    "Only if that process is gone: rm -f '$LOCK/owner' && rmdir '$LOCK'   (this script never deletes it for you)"
fi
printf 'pid=%s started=%s run=%s\n' "$$" "$(date '+%Y-%m-%d %H:%M:%S')" "$RUN_DIR" >"$LOCK/owner"

BUILD_RESULT="not run" INSTALL_RESULT="not run" LAUNCH_RESULT="not run" EXT_RESULT="not run"
finish_deploy() {
  local rc=$?
  printf '%s\n' "$rc" >"$RUN_DIR/exit-code"
  rm -f "$LOCK/owner"
  rmdir "$LOCK" 2>/dev/null || true
  {
    printf 'exit=%s\nconfig=%s\nbuild=%s\ninstall=%s\nlaunch=%s\nrunning=%s\nnative=%s\nextensions=%s\nstages=%s\n' \
      "$rc" "$CONFIG" "$BUILD_RESULT" "$INSTALL_RESULT" "$LAUNCH_RESULT" "${RUNNING:-not checked}" "${NATIVE:-?}" \
      "${EXT_RESULT:-not run}" "$LANE1_STAGE_TIMES"
    printf 'git=%s%s\nbundle=%s\n' "$(git -C "$LANE1_ROOT" rev-parse --short HEAD 2>/dev/null || echo '?')" \
      "$(git -C "$LANE1_ROOT" diff --quiet HEAD 2>/dev/null || echo '+dirty')" "$BUNDLE_ID"
  } >"$RUN_DIR/receipt.txt" 2>/dev/null || true
}
trap finish_deploy EXIT
log "run log dir: $(rel "$RUN_DIR")"
T_START=$SECONDS

# ---------------------------------------------------------------------------------------------------------------
# ~/.lane1/deploy.env: KEY=VALUE lines only (never sourced). The environment wins over the file.
env_file_get() { # <key> -> value or empty
  [ -f "$ENV_FILE" ] || return 0
  sed -n "s/^[[:space:]]*$1=//p" "$ENV_FILE" | tail -n 1 | sed -e 's/^["'\'']//' -e 's/["'\'']$//'
}
env_file_set() { # <key> <value>
  mkdir -p "$LANE1_HOME"
  chmod 700 "$LANE1_HOME" 2>/dev/null || true
  local tmp="$ENV_FILE.tmp.$$"
  : >"$tmp"
  if [ -f "$ENV_FILE" ]; then grep -v "^[[:space:]]*$1=" "$ENV_FILE" >"$tmp" || true; fi
  printf '%s=%s\n' "$1" "$2" >>"$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$ENV_FILE"
}
if [ -f "$ENV_FILE" ]; then
  if [ -z "$(find "$ENV_FILE" -maxdepth 0 -perm 600 2>/dev/null)" ]; then
    warn "$ENV_FILE is not chmod 600 — fixing"
    chmod 600 "$ENV_FILE"
  fi
  [ -n "${LANE1_TEAM_ID:-}" ] || LANE1_TEAM_ID=$(env_file_get LANE1_TEAM_ID)
  [ -n "${LANE1_DEVICE_ID:-}" ] || LANE1_DEVICE_ID=$(env_file_get LANE1_DEVICE_ID)
  [ -n "${GODOT:-}" ] || GODOT=$(env_file_get GODOT)
fi
[ -z "$DEVICE_ARG" ] || LANE1_DEVICE_ID=$DEVICE_ARG

is_number() { case "$1" in "" | *[!0-9]*) return 1 ;; *) return 0 ;; esac; }
mask() { # keeps identifiers out of pasted logs: AB******YZ
  local s=$1 n=${#1}
  if [ "$n" -le 4 ]; then printf '%s' "$s"; else printf '%s%s%s' "${s:0:2}" "******" "${s:n-2:2}"; fi
}

# tail_errors <log> [n]: the useful part of a failed tool log.
tail_errors() {
  local n=${2:-25}
  if grep -qE 'error:|ERROR|failed|FAILED|Error' "$1" 2>/dev/null; then
    grep -E 'error:|ERROR|failed|FAILED|Error' "$1" | tail -n "$n" >&2
  else
    tail -n "$n" "$1" >&2 || true
  fi
}

# ---------------------------------------------------------------------------------------------------------------
check_xcode() {
  if ! have xcodebuild || ! have xcrun; then
    die 3 "Xcode not found. Install Xcode 27.x from the App Store, open it once," \
      "then: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer && sudo xcodebuild -runFirstLaunch"
  fi
  local dev ver
  dev=$(xcode-select -p 2>/dev/null || true)
  case "$dev" in
    "" | *CommandLineTools*)
      die 3 "xcode-select points to '${dev:-nothing}' (Command Line Tools), not Xcode:" \
        "sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
      ;;
  esac
  # Read the whole output (no early `exit` in awk → no SIGPIPE) and never let a non-zero xcodebuild kill the
  # script silently under `set -euo pipefail` (seen on a real Mac: preflight ended with no message).
  local ver_out
  ver_out=$(xcodebuild -version 2>&1 || true)
  ver=$(printf '%s\n' "$ver_out" | awk '/^Xcode / && v == "" {v = $2} END {print v}' || true)
  [ -n "$ver" ] || die 3 "xcodebuild -version failed: $(printf '%s' "$ver_out" | head -n 2 | tr '\n' ' ' || true)" \
    "license not accepted? sudo xcodebuild -license accept   ·   first launch: sudo xcodebuild -runFirstLaunch"
  version_ge "$ver" "$XCODE_MIN" || die 3 "Xcode $ver is too old (need >= $XCODE_MIN; expected 27.x). Update Xcode from the App Store."
  if ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
    die 3 "Xcode first-launch setup is pending: sudo xcodebuild -runFirstLaunch   (and: sudo xcodebuild -license accept)"
  fi
  xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1 || die 3 "iOS platform support is not installed:" \
    "xcodebuild -downloadPlatform iOS   (or Xcode > Settings > Components > iOS > Get)"
  if ! xcrun --sdk iphoneos --find metal >/dev/null 2>&1; then
    warn "Metal toolchain missing (separate download since Xcode 26): shaders would compile on the iPhone at runtime."
    hint "xcodebuild -downloadComponent MetalToolchain   (then re-run; Godot's shader baker uses xcrun metal)"
  fi
  xcrun --find devicectl >/dev/null 2>&1 || die 3 "xcrun devicectl is unavailable (needs Xcode 15+; selected: $dev)"
  have python3 || die 3 "python3 not found (it ships with Xcode's command-line tools: xcode-select --install)"
  ok "Xcode $ver ($dev)"
  if version_ge "$ver" 27.0; then
    log "Xcode 27+: ld64/-ld_classic are gone; Godot 4.7.2's template only adds -ld_classic for Xcode 15.0-15.1 (❓ first build on 27.x)"
  fi
  if [ -n "${SSH_CONNECTION:-}" ]; then
    warn "running over SSH: codesign can fail with errSecInternalComponent (keychain locked to the GUI session)."
    hint "If it does, run this script from Terminal in the logged-in Mac session (docs/IPHONE_DEPLOY.md §6)."
  fi
}

# ---------------------------------------------------------------------------------------------------------------
godot_version_of() { "$1" --headless --version 2>/dev/null | tail -n 1 || true; }

fetch_verified() { # <url> <out> <sha512>
  local url=$1 out=$2 want=$3 got
  if [ -f "$out" ] && [ "$(sha512_of "$out")" = "$want" ]; then
    log "cached: $out"
    return 0
  fi
  mkdir -p "$(dirname "$out")"
  log "download: $url"
  curl -fL --progress-bar --retry 3 --connect-timeout 20 -o "$out.part" "$url" || die 3 "download failed: $url" \
    "(check network/proxy; or download it in a browser to $out and re-run)"
  got=$(sha512_of "$out.part")
  if [ "$got" != "$want" ]; then
    rm -f "$out.part"
    die 3 "SHA-512 mismatch for $(basename "$out") (got ${got:0:16}…, want ${want:0:16}…). Not using it." \
      "Compare with $LANE1_GODOT_RELEASE_URL/SHA512-SUMS.txt"
  fi
  mv "$out.part" "$out"
  ok "verified SHA-512: $(basename "$out")"
}

ensure_godot() {
  local c v
  for c in "${GODOT:-}" "$LANE1_HOME/godot/$LANE1_GODOT_VERSION/Godot.app/Contents/MacOS/Godot" \
    "/Applications/Godot.app/Contents/MacOS/Godot" "$(command -v godot47 2>/dev/null || true)" \
    "$(command -v godot 2>/dev/null || true)"; do
    if [ -z "$c" ] || [ ! -x "$c" ]; then continue; fi
    v=$(godot_version_of "$c")
    case "$v" in
      "$LANE1_GODOT_VERSION_CONFIG"*)
        GODOT_BIN=$c
        ok "Godot $v ($c)"
        return 0
        ;;
      *) [ -z "$v" ] || log "skip $c (reports $v, need $LANE1_GODOT_VERSION_CONFIG)" ;;
    esac
  done
  if [ "$CHECK_ONLY" = 1 ]; then
    warn "Godot $LANE1_GODOT_VERSION not found — a normal run downloads and verifies it into $LANE1_HOME/godot"
    return 0
  fi
  local zip="$LANE1_HOME/downloads/$LANE1_GODOT_MAC_ZIP" dest="$LANE1_HOME/godot/$LANE1_GODOT_VERSION" tmp
  fetch_verified "$LANE1_GODOT_RELEASE_URL/$LANE1_GODOT_MAC_ZIP" "$zip" "$LANE1_GODOT_MAC_ZIP_SHA512"
  tmp="$dest.tmp.$$"
  rm -rf "$tmp"
  mkdir -p "$tmp"
  ditto -x -k "$zip" "$tmp" || die 3 "could not unpack $zip"
  [ -d "$tmp/Godot.app" ] || die 3 "unexpected archive layout (no Godot.app) in $zip"
  rm -rf "$dest"
  mv "$tmp" "$dest"
  xattr -dr com.apple.quarantine "$dest/Godot.app" 2>/dev/null || true
  GODOT_BIN="$dest/Godot.app/Contents/MacOS/Godot"
  v=$(godot_version_of "$GODOT_BIN")
  case "$v" in
    "$LANE1_GODOT_VERSION_CONFIG"*) ok "installed Godot $v -> $dest" ;;
    *) die 3 "installed Godot reports '$v' — expected $LANE1_GODOT_VERSION_CONFIG.*" ;;
  esac
}

ensure_templates() {
  if [ -f "$TPL_DIR/ios.zip" ] && [ "$(cat "$TPL_DIR/version.txt" 2>/dev/null)" = "$LANE1_GODOT_VERSION_CONFIG" ]; then
    ok "export templates: $TPL_DIR"
    return 0
  fi
  if [ "$CHECK_ONLY" = 1 ]; then
    warn "export templates not installed — a normal run downloads (~1.3 GB) and verifies them into '$TPL_DIR'"
    return 0
  fi
  local tpz="$LANE1_HOME/downloads/$LANE1_GODOT_TPZ" tmp
  log "export templates missing — downloading (~1.3 GB, once)"
  fetch_verified "$LANE1_GODOT_RELEASE_URL/$LANE1_GODOT_TPZ" "$tpz" "$LANE1_GODOT_TPZ_SHA512"
  tmp=$(mktemp -d "$LANE1_HOME/templates.XXXXXX")
  # A .tpz is a zip whose top-level folder is templates/ (Editor > Manage Export Templates > Install from File).
  unzip -q "$tpz" -d "$tmp" || die 3 "could not unpack $tpz"
  [ "$(cat "$tmp/templates/version.txt" 2>/dev/null)" = "$LANE1_GODOT_VERSION_CONFIG" ] ||
    die 3 "$tpz does not contain templates/version.txt = $LANE1_GODOT_VERSION_CONFIG"
  mkdir -p "$TPL_DIR"
  cp -R "$tmp/templates/." "$TPL_DIR/"
  rm -rf "$tmp"
  [ -f "$TPL_DIR/ios.zip" ] || die 3 "templates installed but $TPL_DIR/ios.zip is missing"
  ok "installed export templates -> $TPL_DIR"
}

# ---------------------------------------------------------------------------------------------------------------
# Team ID. The "(XXXXXXXXXX)" in an "Apple Development: name (XXXXXXXXXX)" identity is a per-person ID, NOT the
# Team ID; the team is the certificate subject's OU (Apple DTS, developer.apple.com/forums/thread/802517).
detect_teams() {
  local names name ou
  names=$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | sort -u || true)
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    ou=$(security find-certificate -c "$name" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null |
      sed -n 's/.*OU[[:space:]]*=[[:space:]]*\([A-Z0-9]\{10\}\).*/\1/p' | head -n 1 || true)
    [ -z "$ou" ] || printf '%s\n' "$ou"
  done <<EOF
$names
EOF
  # Teams of the Apple Accounts signed in to Xcode (key names differ between Xcode releases ❓).
  {
    defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null || true
    defaults read com.apple.dt.Xcode IDEProvisioningTeams 2>/dev/null || true
  } | sed -n 's/.*teamID = "\{0,1\}\([A-Z0-9]\{10\}\)"\{0,1\};.*/\1/p'
}

resolve_team() {
  if [ -n "${LANE1_TEAM_ID:-}" ]; then
    TEAM_ID=$LANE1_TEAM_ID
    log "Team ID from LANE1_TEAM_ID / deploy.env: $(mask "$TEAM_ID")"
  else
    local teams count
    teams=$(detect_teams | sort -u || true)
    count=$(printf '%s' "$teams" | grep -c . || true)
    if [ "$count" = 1 ]; then
      TEAM_ID=$teams
      ok "Team ID auto-detected: $(mask "$TEAM_ID")"
    elif [ "$count" -gt 1 ]; then
      log "several development teams found:"
      printf '%s\n' "$teams" | awk '{printf "      %d) %s\n", NR, $0}' >&2
      ask "which one? (number)" || die 3 "several teams; set LANE1_TEAM_ID (or ~/.lane1/deploy.env) and re-run"
      is_number "$REPLY" || die 2 "not a number: '$REPLY'"
      TEAM_ID=$(printf '%s\n' "$teams" | sed -n "${REPLY}p")
      [ -n "$TEAM_ID" ] || die 2 "no team #$REPLY"
      env_file_set LANE1_TEAM_ID "$TEAM_ID"
      ok "Team ID $(mask "$TEAM_ID") saved to $ENV_FILE (chmod 600)"
    else
      warn "no 'Apple Development' signing identity in the keychain yet."
      hint "Sign in once: Xcode > Settings > Apple Accounts > + (tools/mac/SIGNING.md 2단계)." \
        "Team ID (10 characters): Xcode > Settings > Apple Accounts > your team, or developer.apple.com/account > Membership."
      ask "Team ID (10 characters)?" || die 3 "no Team ID: set LANE1_TEAM_ID or sign in to Xcode (tools/mac/SIGNING.md)"
      TEAM_ID=$REPLY
      env_file_set LANE1_TEAM_ID "$TEAM_ID"
    fi
  fi
  case "$TEAM_ID" in
    [A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]) ;;
    *) die 3 "Team ID '$(mask "$TEAM_ID")' is not 10 upper-case letters/digits (fix LANE1_TEAM_ID / $ENV_FILE)" ;;
  esac
}

# ---------------------------------------------------------------------------------------------------------------
# Devices: xcrun devicectl list devices --json-output. Xcode 27 (JSON v5) moved fields into "properties" and
# deprecated hardwareProperties/deviceProperties/connectionProperties — read both layouts.
DEVICES_PY='
import json, sys
def find(o, key):
    if isinstance(o, dict):
        if key in o and not isinstance(o[key], (dict, list)):
            return o[key]
        for v in o.values():
            r = find(v, key)
            if r is not None:
                return r
    elif isinstance(o, list):
        for v in o:
            r = find(v, key)
            if r is not None:
                return r
    return None
def find_dict_with(o, keys):
    if isinstance(o, dict):
        if all(k in o for k in keys):
            return o
        for v in o.values():
            r = find_dict_with(v, keys)
            if r is not None:
                return r
    elif isinstance(o, list):
        for v in o:
            r = find_dict_with(v, keys)
            if r is not None:
                return r
    return None
def device_name(dev):
    n = (dev.get("deviceProperties") or {}).get("name")
    if n:
        return n
    for keys in (("name", "osVersionNumber"), ("name", "developerModeStatus"), ("deviceName",)):
        o = find_dict_with(dev.get("properties", dev), keys)
        if o is not None:
            return o.get("name", o.get("deviceName"))
    return "?"
def get(dev, path, key):
    o = dev
    for p in path:
        o = o.get(p) if isinstance(o, dict) else None
    if o is not None and not isinstance(o, (dict, list)):
        return o
    r = find(dev.get("properties", {}), key)
    return r if r is not None else find(dev, key)
data = json.load(open(sys.argv[1]))
for d in data.get("result", {}).get("devices", []):
    plat = str(get(d, ["hardwareProperties", "platform"], "platform") or "")
    if plat.lower() not in ("ios", "ipados"):
        continue
    if str(get(d, ["hardwareProperties", "reality"], "reality") or "physical") != "physical":
        continue
    udid = get(d, ["hardwareProperties", "udid"], "udid") or ""
    row = [
        str(udid or d.get("identifier", "")),
        str(device_name(d) or "?").replace("\t", " "),
        str(get(d, ["hardwareProperties", "marketingName"], "marketingName") or "?"),
        str(get(d, ["hardwareProperties", "deviceType"], "deviceType") or "?"),
        str(get(d, ["connectionProperties", "pairingState"], "pairingState") or "?"),
        str(get(d, ["deviceProperties", "developerModeStatus"], "developerModeStatus") or "?"),
        str(get(d, ["connectionProperties", "transportType"], "transportType") or "?"),
        str(get(d, ["connectionProperties", "tunnelState"], "tunnelState") or "?"),
        str(get(d, ["deviceProperties", "osVersionNumber"], "osVersionNumber") or "?"),
        str(d.get("identifier", "")),
    ]
    print("\t".join(row))
'

list_devices() { # -> $RUN_DIR/devices.tsv
  xcrun devicectl list devices --json-output "$RUN_DIR/devices.json" >"$RUN_DIR/devices.log" 2>&1 ||
    die 5 "xcrun devicectl list devices failed (see $(rel "$RUN_DIR/devices.log"))"
  python3 -I -c "$DEVICES_PY" "$RUN_DIR/devices.json" >"$RUN_DIR/devices.tsv" ||
    die 5 "could not parse devicectl JSON ($(rel "$RUN_DIR/devices.json")); pass --device <UDID>"
}

print_devices() {
  awk -F '\t' '{printf "      %d) %s  %s (%s)  pairing=%s devmode=%s link=%s/%s iOS %s\n", NR, $1, $2, $3, $5, $6, $7, $8, $9}' "$1" >&2
}

resolve_device() {
  list_devices
  local tsv="$RUN_DIR/devices.tsv" pick="$RUN_DIR/device.row" n
  if [ -n "${LANE1_DEVICE_ID:-}" ]; then
    awk -F '\t' -v id="$LANE1_DEVICE_ID" '$1 == id || $10 == id || $2 == id' "$tsv" | head -n 1 >"$pick" || true
    if [ ! -s "$pick" ]; then
      warn "device '$(mask "$LANE1_DEVICE_ID")' is not in devicectl's list; using it as given"
      print_devices "$tsv"
      DEVICE_ID=$LANE1_DEVICE_ID DEVICE_NAME="?" DEVICE_DEVMODE="?" DEVICE_OS="?" DEVICE_PAIRING="?"
      return 0
    fi
  else
    awk -F '\t' '$5 == "paired" && $4 == "iPhone"' "$tsv" >"$RUN_DIR/devices.cand"
    [ -s "$RUN_DIR/devices.cand" ] || awk -F '\t' '$5 == "paired"' "$tsv" >"$RUN_DIR/devices.cand"
    n=$(grep -c . "$RUN_DIR/devices.cand" || true)
    if [ "$n" = 0 ]; then
      [ ! -s "$tsv" ] || {
        log "devices that are not paired yet:"
        print_devices "$tsv"
      }
      die 5 "no paired iPhone found. Connect it with a cable, unlock it, tap 'Trust This Computer'," \
        "then pair it in Xcode > Open Developer Tool > Device Hub (tools/mac/SIGNING.md 3단계)."
    elif [ "$n" = 1 ]; then
      cp "$RUN_DIR/devices.cand" "$pick"
    else
      log "several paired devices:"
      print_devices "$RUN_DIR/devices.cand"
      ask "which one? (number)" || die 5 "several devices; pass --device <UDID> or set LANE1_DEVICE_ID"
      is_number "$REPLY" || die 2 "not a number: '$REPLY'"
      sed -n "${REPLY}p" "$RUN_DIR/devices.cand" >"$pick"
      [ -s "$pick" ] || die 2 "no device #$REPLY"
    fi
  fi
  local _model _type transport tunnel _cd
  IFS=$'\t' read -r DEVICE_ID DEVICE_NAME _model _type DEVICE_PAIRING DEVICE_DEVMODE transport tunnel DEVICE_OS _cd <"$pick"
  ok "device: $DEVICE_NAME ($(mask "$DEVICE_ID")), iOS $DEVICE_OS, pairing=$DEVICE_PAIRING, Developer Mode=$DEVICE_DEVMODE"
  case "$DEVICE_DEVMODE" in
    enabled) ;;
    disabled)
      die 5 "Developer Mode is OFF on $DEVICE_NAME. On the iPhone: Settings > Privacy & Security > Developer Mode" \
        "> On > Restart; after the reboot tap Enable and enter the passcode. Then re-run (tools/mac/SIGNING.md 4단계)."
      ;;
    *) warn "could not read Developer Mode status ('$DEVICE_DEVMODE'); if install fails, check Settings > Privacy & Security > Developer Mode" ;;
  esac
  [ "$tunnel" != "unavailable" ] || warn "devicectl reports $DEVICE_NAME as unavailable (link=$transport): plug in the cable / unlock it"
  if [ "$DEVICE_OS" != "?" ] && ! version_ge "$DEVICE_OS" "$IOS_DEVICE_MIN"; then
    warn "iOS $DEVICE_OS < $IOS_DEVICE_MIN: Xcode 27 supports development on iOS 17+ only — update the iPhone."
  fi
}

# ---------------------------------------------------------------------------------------------------------------
LAUNCH_EPOCH=0
launch_app() {
  LAUNCH_RESULT="failed"
  LAUNCH_EPOCH=$(date +%s)
  if xcrun devicectl device process launch --device "$DEVICE_ID" --terminate-existing "$BUNDLE_ID" \
    --json-output "$RUN_DIR/launch.json" >"$RUN_DIR/launch.log" 2>&1; then
    LAUNCH_RESULT="ok"
    ok "launch: $BUNDLE_ID on $DEVICE_NAME"
    return 0
  fi
  tail_errors "$RUN_DIR/launch.log" 12
  if grep -qiE 'trust|untrusted|not been explicitly trusted|invalid code signature|profile' "$RUN_DIR/launch.log"; then
    warn "the iPhone does not trust this developer yet (normal for the first install with a free Personal Team)."
    hint "iPhone: Settings > General > VPN & Device Management > DEVELOPER APP > 'Apple Development: <Apple ID>'" \
      "> Trust '<Apple ID>' > Trust. Then: tools/mac/ios_run.sh --launch-only   (or tap the app icon)"
  elif grep -qiE 'locked|passcode' "$RUN_DIR/launch.log"; then
    hint "unlock the iPhone, then: tools/mac/ios_run.sh --launch-only"
  else
    hint "details: $(rel "$RUN_DIR/launch.log"), $(rel "$RUN_DIR/launch.json")"
  fi
  return 1
}

# After `devicectl … launch` returns 0 the process was only spawned: a dyld error, a crash in the first frames or a
# black screen from a GDScript parse error still exit 0 (review). Wait, then check the process list, and pull the
# boot line the game writes to user://boot.txt (Documents/ on iOS) for native=true|false. Both are best-effort.
LAUNCH_WAIT=${LANE1_LAUNCH_WAIT:-8}
RUNNING="not checked" NATIVE="?" BOOT_FRESH=0
verify_running() {
  log "waiting ${LAUNCH_WAIT}s, then checking that $PRODUCT is still running…"
  sleep "$LAUNCH_WAIT"
  if xcrun devicectl device info processes --device "$DEVICE_ID" --json-output "$RUN_DIR/procs.json" \
    >"$RUN_DIR/procs.log" 2>&1; then
    if grep -q "/$PRODUCT/$SCHEME" "$RUN_DIR/procs.json" 2>/dev/null; then
      RUNNING=yes
    else
      RUNNING=no
    fi
  else
    RUNNING="unknown (devicectl device info processes failed: $(rel "$RUN_DIR/procs.log"))"
  fi
  rm -f "$RUN_DIR/boot.txt"
  if xcrun devicectl device copy from --device "$DEVICE_ID" --domain-type appDataContainer \
    --domain-identifier "$BUNDLE_ID" --source Documents/boot.txt --destination "$RUN_DIR/boot.txt" \
    >"$RUN_DIR/copy-boot.log" 2>&1 && [ -s "$RUN_DIR/boot.txt" ]; then
    local boot_t
    boot_t=$(sed -n 's/.*boot_unix=\([0-9]*\).*/\1/p' "$RUN_DIR/boot.txt" | head -n 1 || true)
    if is_number "$boot_t" && [ "$boot_t" -ge $((LAUNCH_EPOCH - 60)) ]; then
      BOOT_FRESH=1
      NATIVE=$(sed -n 's/.*native=\([a-z]*\).*/\1/p' "$RUN_DIR/boot.txt" | head -n 1 || true)
      [ -n "$NATIVE" ] || NATIVE="?"
      log "boot: $(head -n 1 "$RUN_DIR/boot.txt")"
    else
      NATIVE="? (boot.txt is from an earlier launch)"
    fi
  fi
  case "$RUNNING" in
    yes)
      LAUNCH_RESULT="ok (running after ${LAUNCH_WAIT}s)"
      ok "running after ${LAUNCH_WAIT}s (native traffic: $NATIVE)"
      [ "$NATIVE" != false ] || warn "the game runs with the GDScript traffic fallback (C++ extension stubbed or failed to load)"
      ;;
    no)
      LAUNCH_RESULT="failed (exited within ${LAUNCH_WAIT}s)"
      warn "$PRODUCT is not running ${LAUNCH_WAIT}s after launch: it crashed or quit at startup."
      hint "Crash log: Xcode > Window > Devices and Simulators > $DEVICE_NAME > View Device Logs (lane1)," \
        "or open $(rel "$EXPORT_ROOT")/<debug|release>/$SCHEME.xcodeproj and Run (⌘R) to see the console." \
        "If build_ios_ext stubbed an extension, see $(rel "$LANE1_NATIVE/build/ios/ext_status.txt")."
      return 1
      ;;
    *)
      # Codex review: an unreadable process list must not become a success receipt. Accept only independent
      # evidence that this launch booted the game (boot.txt written after LAUNCH_EPOCH); otherwise fail (exit 7).
      if [ "$BOOT_FRESH" = 1 ]; then
        LAUNCH_RESULT="ok (process list unavailable; boot.txt from this launch, native traffic: $NATIVE)"
        warn "could not read the device process list; the game wrote boot.txt for this launch — check the iPhone screen"
      else
        LAUNCH_RESULT="unverified (process list unavailable and no boot.txt from this launch)"
        warn "could not verify that $PRODUCT is running: devicectl process list failed and no fresh boot.txt."
        hint "details: $(rel "$RUN_DIR/procs.log"), $(rel "$RUN_DIR/copy-boot.log")." \
          "Check the cable / unlock the iPhone, then: bash tools/mac/ios_run.sh --launch-only"
        return 1
      fi
      ;;
  esac
  return 0
}

summary() {
  local total=$((SECONDS - T_START))
  printf '\n%s== 결과%s (%s)\n' "$_C_BLD" "$_C_OFF" "$CONFIG"
  printf '  build   : %s\n  install : %s\n  launch  : %s\n  running : %s   native traffic: %s\n' "$BUILD_RESULT" \
    "$INSTALL_RESULT" "$LAUNCH_RESULT" "$RUNNING" "$NATIVE"
  printf '  기능 확인: ❓ 사용자 확인 필요 (화면이 뜨는지, 햅틱, 120Hz — docs/IPHONE_DEPLOY.md 7절)\n'
  printf '  elapsed : %ss (목표 <= 600s)  stages: %s\n' "$total" "$LANE1_STAGE_TIMES"
  printf '  logs    : %s\n' "$(rel "$RUN_DIR")"
}

# Device feedback 2026-10-14: without cmake the C++ traffic core was stubbed and the GDScript fallback ran (cars and
# shoulder obstacles felt "passable"). Provision cmake + ninja ourselves: Homebrew if it is there, else a private
# Python venv (PyPI ships universal2 cmake/ninja wheels) under ~/.lane1/venv — no admin rights, nothing global.
ensure_cmake() {
  if have cmake; then
    ok "cmake $(cmake --version 2>/dev/null | awk 'NR == 1 {print $3}' || true)"
    return 0
  fi
  local venv="$HOME/.lane1/venv"
  if [ -x "$venv/bin/cmake" ]; then
    PATH="$venv/bin:$PATH"
    export PATH
    ok "cmake from $venv"
    return 0
  fi
  log "cmake not found — installing a private copy (C++ traffic core needs it; once, ~30 s)"
  if have brew && brew install cmake ninja >"$RUN_DIR/cmake-install.log" 2>&1; then
    ok "cmake installed with Homebrew"
    return 0
  fi
  if python3 -m venv "$venv" >>"$RUN_DIR/cmake-install.log" 2>&1 &&
    "$venv/bin/python3" -m pip install --quiet --upgrade pip cmake ninja >>"$RUN_DIR/cmake-install.log" 2>&1 &&
    [ -x "$venv/bin/cmake" ]; then
    PATH="$venv/bin:$PATH"
    export PATH
    ok "cmake installed in $venv"
    return 0
  fi
  warn "could not install cmake (log: $(rel "$RUN_DIR/cmake-install.log")): the C++ traffic core becomes a stub and the" \
    "game uses the slower GDScript fallback. Fix: brew install cmake ninja, then re-run."
}

# ===============================================================================================================
stage_begin "preflight"
check_xcode
resolve_device
if [ "$LAUNCH_ONLY" = 1 ]; then
  stage_end
  stage_begin "launch"
  if ! launch_app || ! verify_running; then
    summary
    exit 7
  fi
  stage_end
  summary
  exit 0
fi
resolve_team
ensure_godot
ensure_templates
ensure_cmake
grep -q '^run/main_scene=' "$LANE1_NATIVE/project.godot" ||
  warn "native/project.godot has no run/main_scene yet — the app will start to an empty screen/quit (gate owner)"
stage_end
if [ "$CHECK_ONLY" = 1 ]; then
  ok "preflight passed (--check): nothing was built or installed"
  exit 0
fi

EXPORT_DIR="$EXPORT_ROOT/$KIND"
if [ "$CLEAN" = 1 ]; then
  log "clean: $(rel "$DERIVED") $(rel "$EXPORT_ROOT")"
  rm -rf "$DERIVED" "$EXPORT_ROOT"
fi

stage_begin "extensions (haptics + traffic for iOS)"
EXT_ARGS=("--target=template_$KIND")
[ "$NO_EXT" = 0 ] || EXT_ARGS+=(--no-ext)
[ "$CLEAN" = 0 ] || EXT_ARGS+=(--clean)
if GODOT="$GODOT_BIN" bash "$SCRIPT_DIR/build_ios_ext.sh" "${EXT_ARGS[@]}" >"$RUN_DIR/ext.log" 2>&1; then
  EXT_RESULT=$(tr '\n' ' ' <"$LANE1_NATIVE/build/ios/ext_status.txt" 2>/dev/null || echo '?')
  if grep -qE '^stub:|=failed|=skipped' "$LANE1_NATIVE/build/ios/ext_status.txt" 2>/dev/null; then
    warn "extensions: $EXT_RESULT"
    hint "stub = that extension is left out on the iPhone (traffic -> GDScript fallback, haptics -> vibrate_handheld)." \
      "log: $(rel "$RUN_DIR/ext.log")"
    # Show why, right here (device run 2026-10-14 only said traffic=failed): the build log's error lines.
    if grep -q '^traffic=failed' "$LANE1_NATIVE/build/ios/ext_status.txt" 2>/dev/null; then
      printf '      ── traffic build errors (send these lines if this keeps failing) ──\n' >&2
      grep -E -i 'error|fail|could not|not found' "$RUN_DIR/ext.log" | grep -v -i 'continuing' | head -n 15 >&2 || true
    fi
  else
    ok "extensions: $EXT_RESULT"
  fi
else
  EXT_RESULT="failed (stubs)"
  tail -n 15 "$RUN_DIR/ext.log" >&2 || true
  warn "extension build failed — continuing so the game still launches (no Core Haptics / traffic classes)."
  hint "log: $(rel "$RUN_DIR/ext.log")"
  # Make sure every library the manifests name exists (stubs), or the export silently drops extensions.
  GODOT="$GODOT_BIN" bash "$SCRIPT_DIR/build_ios_ext.sh" "--target=template_$KIND" --no-ext --no-haptics \
    >>"$RUN_DIR/ext.log" 2>&1 || warn "could not write stub libraries either; the export may miss extensions"
fi
stage_end

stage_begin "godot import + export ($PRESET, $KIND)"
"$GODOT_BIN" --headless --path "$LANE1_NATIVE" --import >"$RUN_DIR/import.log" 2>&1 || {
  tail_errors "$RUN_DIR/import.log"
  die 4 "godot --import failed (log: $(rel "$RUN_DIR/import.log"))"
}
rm -rf "$EXPORT_DIR"
mkdir -p "$EXPORT_DIR"
"$GODOT_BIN" --headless --path "$LANE1_NATIVE" "--export-$KIND" "$PRESET" "$EXPORT_DIR/$SCHEME.xcodeproj" \
  >"$RUN_DIR/export.log" 2>&1 || {
  tail_errors "$RUN_DIR/export.log"
  die 4 "godot export failed (log: $(rel "$RUN_DIR/export.log")); templates: $TPL_DIR"
}
if grep -q 'Metal shader baking limited' "$RUN_DIR/export.log"; then
  warn "Godot could not pre-bake Metal shaders (Metal toolchain?): first frames on the iPhone may hitch."
  hint "xcodebuild -downloadComponent MetalToolchain, then tools/mac/ios_run.sh --clean"
fi
PBX="$EXPORT_DIR/$SCHEME.xcodeproj/project.pbxproj"
[ -f "$PBX" ] || die 4 "export produced no $(rel "$PBX") (log: $(rel "$RUN_DIR/export.log"))"
# Team placeholder from export_presets.cfg -> real team, only in the generated (gitignored) project.
grep -q "$LANE1_TEAM_PLACEHOLDER" "$PBX" || warn "team placeholder $LANE1_TEAM_PLACEHOLDER not found in project.pbxproj"
sed "s/$LANE1_TEAM_PLACEHOLDER/$TEAM_ID/g" "$PBX" >"$PBX.tmp"
mv "$PBX.tmp" "$PBX"
ok "Xcode project: $(rel "$EXPORT_DIR/$SCHEME.xcodeproj")"
stage_end

# ---------------------------------------------------------------------------------------------------------------
stage_begin "xcodebuild ($CONFIG, generic/platform=iOS, automatic signing)"
log "macOS may ask for your login keychain password for 'codesign' — enter it and choose 'Always Allow'."
xcode_build() { # [extra xcodebuild args...]
  local extra=()
  [ "$RELEASE" = 0 ] || extra+=("CODE_SIGN_IDENTITY=Apple Development")
  xcodebuild -project "$EXPORT_DIR/$SCHEME.xcodeproj" -scheme "$SCHEME" -configuration "$CONFIG" \
    "$@" -derivedDataPath "$DERIVED" \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
    DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic \
    CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES ${extra[@]+"${extra[@]}"} \
    build >"$RUN_DIR/build.log" 2>&1
}
if ! xcode_build -destination 'generic/platform=iOS'; then
  BUILD_RESULT="failed"
  if grep -qiE "doesn.t include the currently selected device|no devices|not registered|No profiles for" "$RUN_DIR/build.log" &&
    [ "$DEVICE_ID" != "?" ]; then
    warn "provisioning profile lacks this iPhone — retrying once with -destination id=<device> to register it"
    cp "$RUN_DIR/build.log" "$RUN_DIR/build.generic.log"
    xcode_build -destination "id=$DEVICE_ID" && BUILD_RESULT="ok (device destination)"
  fi
fi
if [ "$BUILD_RESULT" = failed ]; then
  tail_errors "$RUN_DIR/build.log"
  if grep -q errSecInternalComponent "$RUN_DIR/build.log"; then
    die 4 "codesign failed with errSecInternalComponent: the keychain is not usable from this session." \
      "Run tools/mac/ios_run.sh from Terminal in the logged-in Mac GUI session (not SSH), approve the keychain" \
      "prompt with your login password ('Always Allow'). Never put the password on the command line (docs/IPHONE_DEPLOY.md §6)."
  elif grep -qiE "No Account|requires a development team|No signing certificate|sign in" "$RUN_DIR/build.log"; then
    die 4 "signing is not set up: Xcode > Settings > Apple Accounts > + (sign in), then re-run (tools/mac/SIGNING.md 2단계)."
  elif grep -qiE "maximum App ID limit|App ID limit" "$RUN_DIR/build.log"; then
    die 4 "free Personal Team limit hit (10 App IDs / 7 days). Keep the bundle id $BUNDLE_ID; wait or remove old dev apps."
  else
    die 4 "xcodebuild failed (log: $(rel "$RUN_DIR/build.log"))." \
      "Fallback: open $(rel "$EXPORT_DIR/$SCHEME.xcodeproj") in Xcode, choose your iPhone, press Run (⌘R) once, then re-run this script."
  fi
fi
[ "$BUILD_RESULT" != "not run" ] || BUILD_RESULT="ok"
APP="$DERIVED/Build/Products/$CONFIG-iphoneos/$PRODUCT"
test -d "$APP" || die 4 "built app not found at $(rel "$APP")"
codesign --verify --deep --strict "$APP" >"$RUN_DIR/codesign.log" 2>&1 || {
  BUILD_RESULT="failed (codesign verify)"
  cat "$RUN_DIR/codesign.log" >&2
  die 4 "codesign --verify --deep --strict failed for $(rel "$APP")"
}
ACTUAL_ID=$("$PLISTBUDDY" -c 'Print :CFBundleIdentifier' "$APP/Info.plist" 2>/dev/null || true)
if [ "$ACTUAL_ID" != "$BUNDLE_ID" ]; then
  BUILD_RESULT="failed (bundle id '$ACTUAL_ID')"
  die 4 "app bundle id is '$ACTUAL_ID', expected '$BUNDLE_ID' — not installing (would overwrite another app)."
fi
ok "build: $(rel "$APP") (signed, $BUNDLE_ID)"
stage_end

# ---------------------------------------------------------------------------------------------------------------
stage_begin "install (devicectl; the existing app and its data are kept)"
if xcrun devicectl device install app --device "$DEVICE_ID" "$APP" \
  --json-output "$RUN_DIR/install.json" >"$RUN_DIR/install.log" 2>&1; then
  INSTALL_RESULT="ok"
  ok "install: $DEVICE_NAME"
else
  INSTALL_RESULT="failed"
  tail_errors "$RUN_DIR/install.log" 12
  if grep -qiE 'developer mode' "$RUN_DIR/install.log"; then
    hint "turn on Developer Mode: Settings > Privacy & Security > Developer Mode (tools/mac/SIGNING.md 4단계)"
  elif grep -qiE 'locked|passcode' "$RUN_DIR/install.log"; then
    hint "unlock the iPhone and re-run"
  elif grep -qiE 'provisioning profile|0xe8008015|0xe800801c' "$RUN_DIR/install.log"; then
    hint "the profile does not include this iPhone: open the exported project in Xcode, pick the iPhone, Run once."
  fi
  summary
  exit 6
fi
stage_end

stage_begin "launch"
if ! launch_app || ! verify_running; then
  stage_end
  summary
  exit 7
fi
stage_end
summary
