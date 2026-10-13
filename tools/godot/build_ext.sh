#!/usr/bin/env bash
# build_ext.sh — reproducible Linux build of native/ext (C++ GDExtension "traffic").
#
# 가설: ✅ godot-cpp 10.0.0-stable(버전 독립, api_version=4.7 내장 JSON)을 SHA로 고정하고
#       libstdc++를 정적 링크하면, Ubuntu g++ 로 만든 .so 가 Nix Godot 4.7.2(glibc 2.42)에 그대로 로드된다.
#
# Usage: tools/godot/build_ext.sh [--target=template_debug|template_release|all] [--jobs=N] [--clean]
#                                 [--verify-api] [--offline]
#   default target: template_debug (editor, tests, debug exports). Release exports need --target=all.
#   --verify-api  dump the running engine's extension_api.json (godot47 --dump-extension-api) and diff
#                 its classes/method hashes against godot-cpp's bundled extension_api-4-7.json.
#   --offline     never touch the network (fail if godot-cpp is missing or at the wrong SHA).
# Env: GODOT (default godot47), GODOT_CPP_DIR (default native/ext/godot-cpp), CMAKE_GENERATOR.
#
# godot-cpp is fetched with plain `git clone` (works through this container's git proxy and on the Mac)
# into native/ext/godot-cpp (gitignored) and checked against the pinned commit — the pin is the SHA
# below, not a submodule gitlink (see native/ext/README.md "Why not a submodule").
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
EXT="$ROOT/native/ext"
GODOT=${GODOT:-godot47}
GODOT_CPP_DIR=${GODOT_CPP_DIR:-$EXT/godot-cpp}
GODOT_CPP_REPO=https://github.com/godotengine/godot-cpp
GODOT_CPP_REF=10.0.0-stable
GODOT_CPP_SHA=507ed9d840c01a3c5b2a39af8bb4000bfac30bf5
API_VERSION=4.7

TARGETS=(template_debug)
JOBS=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
CLEAN=0 VERIFY_API=0 OFFLINE=0
for a in "$@"; do
  case "$a" in
    --target=all) TARGETS=(template_debug template_release) ;;
    --target=template_debug|--target=template_release) TARGETS=("${a#--target=}") ;;
    --jobs=*) JOBS=${a#--jobs=} ;;
    --clean) CLEAN=1 ;;
    --verify-api) VERIFY_API=1 ;;
    --offline) OFFLINE=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

log() { printf '[build_ext] %s\n' "$*"; }
die() { printf '[build_ext] FAIL: %s\n' "$*" >&2; exit 1; }

# --- 1. godot-cpp at the pinned SHA ------------------------------------------------------------
if [ ! -d "$GODOT_CPP_DIR/.git" ] && [ ! -f "$GODOT_CPP_DIR/.git" ]; then
  [ "$OFFLINE" = 0 ] || die "godot-cpp missing at $GODOT_CPP_DIR (--offline)"
  log "fetch godot-cpp $GODOT_CPP_REF -> $GODOT_CPP_DIR"
  rm -rf "$GODOT_CPP_DIR"
  git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$GODOT_CPP_REF" "$GODOT_CPP_REPO" "$GODOT_CPP_DIR"
fi
have=$(git -C "$GODOT_CPP_DIR" rev-parse HEAD)
if [ "$have" != "$GODOT_CPP_SHA" ]; then
  [ "$OFFLINE" = 0 ] || die "godot-cpp at $have, want $GODOT_CPP_SHA (--offline)"
  log "godot-cpp at $have, moving to pinned $GODOT_CPP_SHA"
  git -C "$GODOT_CPP_DIR" fetch --quiet --depth 1 origin "$GODOT_CPP_SHA" \
    || git -C "$GODOT_CPP_DIR" fetch --quiet --depth 1 origin "refs/tags/$GODOT_CPP_REF:refs/tags/$GODOT_CPP_REF"
  git -C "$GODOT_CPP_DIR" -c advice.detachedHead=false checkout --quiet "$GODOT_CPP_SHA"
  have=$(git -C "$GODOT_CPP_DIR" rev-parse HEAD)
  [ "$have" = "$GODOT_CPP_SHA" ] || die "could not check out $GODOT_CPP_SHA"
fi
[ -f "$GODOT_CPP_DIR/gdextension/extension_api-${API_VERSION/./-}.json" ] \
  || die "godot-cpp has no extension_api-${API_VERSION/./-}.json"
# Keep Godot's importer out of the checkout (it is inside res://ext/).
touch "$GODOT_CPP_DIR/.gdignore"
log "godot-cpp $GODOT_CPP_REF @ $have"

# --- 2. configure + build ------------------------------------------------------------------------
gen=()
if [ -n "${CMAKE_GENERATOR:-}" ]; then gen=(-G "$CMAKE_GENERATOR"); elif command -v ninja >/dev/null; then gen=(-G Ninja); fi
mkdir -p "$EXT/build"
touch "$EXT/build/.gdignore"
for t in "${TARGETS[@]}"; do
  bdir="$EXT/build/linux-$t"
  [ "$CLEAN" = 1 ] && rm -rf "$bdir"
  log "configure $t -> $bdir"
  cmake -S "$EXT" -B "$bdir" "${gen[@]}" -DCMAKE_BUILD_TYPE=Release \
        -DGODOTCPP_TARGET="$t" -DLANE1_GODOT_API_VERSION="$API_VERSION" \
        -DLANE1_GODOT_CPP_REF="$GODOT_CPP_REF" -DGODOT_CPP_DIR="$GODOT_CPP_DIR" >/dev/null
  log "build $t (-j$JOBS)"
  start=$(date +%s)
  cmake --build "$bdir" --target traffic -j "$JOBS" | tail -n 3
  so="$EXT/bin/libtraffic.linux.$t.x86_64.so"
  [ -f "$so" ] || die "expected output $so"
  # --- 3. sanity: entry symbol exported, no dynamic libstdc++ (Nix Godot cannot resolve it) -------
  nm -D --defined-only "$so" | grep -q ' traffic_library_init$' || die "$so does not export traffic_library_init"
  if readelf -d "$so" | grep -E 'NEEDED.*(libstdc\+\+|libgcc_s)'; then die "$so links libstdc++/libgcc_s dynamically"; fi
  log "ok $so ($(du -h "$so" | cut -f1), $(( $(date +%s) - start ))s; NEEDED: $(readelf -d "$so" | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p' | tr '\n' ' '))"
done

# --- 4. optional: engine API vs pinned godot-cpp API json ---------------------------------------
if [ "$VERIFY_API" = 1 ]; then
  command -v "$GODOT" >/dev/null || die "--verify-api needs $GODOT"
  vdir="$EXT/build/api-dump"
  rm -rf "$vdir"; mkdir -p "$vdir"
  (cd "$vdir" && "$GODOT" --headless --dump-extension-api >/dev/null 2>&1) || true
  [ -f "$vdir/extension_api.json" ] || die "engine did not write extension_api.json"
  python3 -I - "$vdir/extension_api.json" "$GODOT_CPP_DIR/gdextension/extension_api-${API_VERSION/./-}.json" <<'PY'
import json, sys
eng, pin = (json.load(open(p)) for p in sys.argv[1:3])
def sig(d):
    out = {}
    for c in d["classes"]:
        for m in c.get("methods", []):
            out[f'{c["name"]}.{m["name"]}'] = m.get("hash")
    for c in d["builtin_classes"]:
        for m in c.get("methods", []):
            out[f'{c["name"]}::{m["name"]}'] = m.get("hash")
    return out
e, p = sig(eng), sig(pin)
missing = sorted(k for k in p if k not in e)            # pinned API the engine lacks -> would break
changed = sorted(k for k in p if k in e and e[k] != p[k])
extra = len([k for k in e if k not in p])
h = eng["header"]
print(f'[build_ext] engine API {h["version_full_name"]}: {len(e)} methods; pinned {pin["header"]["version_full_name"]}: {len(p)}; '
      f'missing={len(missing)} hash_changed={len(changed)} engine_extra={extra}')
for k in (missing + changed)[:20]:
    print("[build_ext]   diff:", k)
sys.exit(1 if missing or changed else 0)
PY
fi
log "done"
