#!/usr/bin/env bash
# build_ios_ext.sh — builds the GDExtensions an iOS export needs (called by tools/mac/ios_run.sh).
#
# 가설: ❓ (Mac 미검증) haptics(C 인터페이스, 소스 3개)는 xcrun clang++ + libtool + create-xcframework로 수 초에
#       끝나고, traffic(godot-cpp)은 native/ext/README.md의 CMake(-G Xcode, CMAKE_SYSTEM_NAME=iOS) 절차로 빌드된다.
#       ✅ (컨테이너) 빌드가 실패한 라이브러리 자리에 stub 정적 라이브러리를 두면 Godot 4.7.2 export가 끝까지
#       간다(누락 파일이 있으면 _export_additional_assets가 그 뒤 라이브러리를 건너뜀).
#       ~~빈 stub + dummy.cpp의 -Wl,-U 약한 참조로 링크·실행 OK~~ → 기각(리뷰): dummy.cpp는 진입 심볼을 weak 없이
#       선언하고 &fn을 등록하므로, 심볼이 없으면 dyld가 실행 시 'symbol not found in flat namespace'로 죽는다.
#       ❓ (Mac 미검증) 그래서 [libraries] stub은 manifest의 entry_symbol을 정의하고 false를 돌려준다 → Godot는
#       "initialization function … returned an error"만 찍고 그 클래스 없이 뜬다(GDScript 폴백). 의존성 stub은 빈 것.
#
# Usage: tools/mac/build_ios_ext.sh [options]
#   --host                build only the host haptics library (Linux .so for container tests / macOS .dylib for
#                         the Mac editor). Default on Linux.
#   --target=T            template_debug (default) | template_release — which traffic/godot-cpp xcframework to build
#   --no-ext              skip native/ext (traffic + godot-cpp); a stub is written so the export still works
#   --no-haptics          skip the haptics module (stub)
#   --clean               delete iOS build trees and outputs first
#   --container-stubs     (Linux only, for export smoke tests) write placeholder xcframeworks for every missing
#                         iOS library so `godot --export-debug iOS` can be exercised without Xcode
#   --jobs=N              parallel jobs for the traffic build
#   -h, --help
# Env: GODOT (engine binary used to dump gdextension_interface.h; default godot47/godot), CMAKE_GENERATOR.
# Output: native/platform/ios/bin/*, native/ext/bin/*.ios.*.xcframework, and a summary in
#         native/build/ios/ext_status.txt (lines "name=ok|stub|skipped reason").
# Exit:   0 when every library referenced by the manifests exists (real or stub); 4 when even that failed.
set -euo pipefail

LANE1_LOG_TAG=build_ios_ext
# shellcheck source=tools/mac/lib/common.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

HAPTICS_DIR="$LANE1_NATIVE/platform/ios"
HAPTICS_SRC="$HAPTICS_DIR/src"
HAPTICS_BUILD="$HAPTICS_DIR/build"
HAPTICS_BIN="$HAPTICS_DIR/bin"
EXT_DIR="$LANE1_NATIVE/ext"
STATUS_DIR="$LANE1_NATIVE/build/ios"
STATUS_FILE="$STATUS_DIR/ext_status.txt"
IOS_MIN="15.0" # == application/min_ios_version in native/export_presets.cfg (Godot 4.7.2 default)

HOST_ONLY=0 TARGET=template_debug NO_EXT=0 NO_HAPTICS=0 CLEAN=0 CONTAINER_STUBS=0
JOBS=$( (sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4) | head -n 1 || true)
is_macos || HOST_ONLY=1
for a in "$@"; do
  case "$a" in
    --host) HOST_ONLY=1 ;;
    --target=template_debug | --target=template_release) TARGET=${a#--target=} ;;
    --no-ext) NO_EXT=1 ;;
    --no-haptics) NO_HAPTICS=1 ;;
    --clean) CLEAN=1 ;;
    --container-stubs) CONTAINER_STUBS=1 ;;
    --jobs=*) JOBS=${a#--jobs=} ;;
    -h | --help)
      sed -n '2,27p' "$0"
      exit 0
      ;;
    *) die 2 "unknown option: $a (see --help)" ;;
  esac
done

mkdir -p "$STATUS_DIR"
touch "$LANE1_NATIVE/build/.gdignore"
: >"$STATUS_FILE"
status() { printf '%s\n' "$*" >>"$STATUS_FILE"; }

if [ "$CLEAN" = 1 ]; then
  log "clean: $(rel "$HAPTICS_BUILD") $(rel "$HAPTICS_BIN") native/ext/build/ios-* native/ext/bin/*.ios.*"
  rm -rf "$HAPTICS_BUILD" "$HAPTICS_BIN" "$EXT_DIR"/build/ios-*
  rm -rf "$EXT_DIR"/bin/*.ios.*.xcframework "$EXT_DIR"/bin/*.ios.*.a
fi
mkdir -p "$HAPTICS_BUILD" "$HAPTICS_BIN"
touch "$HAPTICS_BUILD/.gdignore"

# ---------------------------------------------------------------------------------------------------------------
# gdextension_interface.h from the pinned engine (exactly what that engine implements).
find_godot() {
  if [ -n "${GODOT:-}" ]; then
    printf '%s' "$GODOT"
  elif have godot47; then
    printf 'godot47'
  elif have godot; then
    printf 'godot'
  fi
}

ensure_interface_header() {
  local gen="$HAPTICS_BUILD/gen" godot version
  godot=$(find_godot)
  [ -n "$godot" ] || die 3 "no Godot binary to dump gdextension_interface.h (set GODOT=/path/to/Godot)"
  version=$("$godot" --headless --version 2>/dev/null | tail -n 1 || true)
  case "$version" in
    "$LANE1_GODOT_VERSION_CONFIG"*) ;;
    *) die 3 "GODOT=$godot reports '$version', need $LANE1_GODOT_VERSION_CONFIG.* (docs/NATIVE_PORT.md 1-2)" ;;
  esac
  mkdir -p "$gen"
  if [ -f "$gen/gdextension_interface.h" ] && [ "$(cat "$gen/version.txt" 2>/dev/null)" = "$version" ]; then
    return 0
  fi
  log "dump gdextension_interface.h from $version"
  (cd "$gen" && "$godot" --headless --dump-gdextension-interface >/dev/null 2>&1) || true
  [ -s "$gen/gdextension_interface.h" ] || die 3 "$godot --dump-gdextension-interface wrote nothing in $(rel "$gen")"
  printf '%s' "$version" >"$gen/version.txt"
}

HAPTICS_SOURCES_CPP="haptics_gdextension.cpp haptics_core.cpp"
HAPTICS_WARN_FLAGS="-Wall -Wextra -Wpedantic"

build_haptics_host_linux() {
  local out="$HAPTICS_BIN/liblane1_haptics.linux.x86_64.so" cxx=${CXX:-c++} srcs=() f
  for f in $HAPTICS_SOURCES_CPP haptics_backend_null.cpp; do srcs+=("$HAPTICS_SRC/$f"); done
  log "host (linux): $(rel "$out")"
  # -static-libstdc++: the container's Nix-built Godot has no libstdc++ on its search path (native/ext/README.md).
  # shellcheck disable=SC2086
  "$cxx" -std=c++17 -O2 -fPIC -shared -fvisibility=hidden $HAPTICS_WARN_FLAGS \
    -I"$HAPTICS_BUILD/gen" -I"$HAPTICS_SRC" "${srcs[@]}" -o "$out" \
    -static-libstdc++ -static-libgcc -Wl,--no-undefined
  if have nm; then
    nm -D --defined-only "$out" | grep -q ' lane1_haptics_init$' || die 4 "$out does not export lane1_haptics_init"
  fi
}

build_haptics_host_macos() {
  local out="$HAPTICS_BIN/liblane1_haptics.macos.dylib" srcs=() f
  for f in $HAPTICS_SOURCES_CPP haptics_backend_null.cpp; do srcs+=("$HAPTICS_SRC/$f"); done
  log "host (macos, universal): $(rel "$out")"
  # shellcheck disable=SC2086
  xcrun clang++ -std=c++17 -O2 -dynamiclib -fvisibility=hidden $HAPTICS_WARN_FLAGS \
    -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 \
    -install_name "@rpath/liblane1_haptics.macos.dylib" \
    -I"$HAPTICS_BUILD/gen" -I"$HAPTICS_SRC" "${srcs[@]}" -o "$out" || return 1
  codesign --force --sign - "$out" >/dev/null 2>&1 || warn "ad-hoc codesign of $(rel "$out") failed (editor may refuse to load it)"
}

build_haptics_ios() {
  local obj="$HAPTICS_BUILD/ios-arm64" sdk cxx xcf="$HAPTICS_BIN/liblane1_haptics.ios.xcframework" f
  sdk=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null) || {
    warn "iOS SDK missing (xcodebuild -downloadPlatform iOS)"
    return 1
  }
  cxx=$(xcrun --sdk iphoneos --find clang++)
  rm -rf "$obj"
  mkdir -p "$obj"
  local flags=(-arch arm64 -isysroot "$sdk" "-miphoneos-version-min=$IOS_MIN" -std=c++17 -O2 -DNDEBUG
    -fvisibility=hidden -I"$HAPTICS_BUILD/gen" -I"$HAPTICS_SRC" -Wall -Wextra)
  log "ios arm64 (SDK $(basename "$sdk")): compile"
  # Explicit `|| return 1`: this runs as `if build_haptics_ios`, where errexit is suspended.
  for f in $HAPTICS_SOURCES_CPP; do
    "$cxx" "${flags[@]}" -c "$HAPTICS_SRC/$f" -o "$obj/${f%.cpp}.o" || return 1
  done
  # CoreHaptics/UIKit/Foundation need no explicit -framework: libgodot.a autolinks all three (LC_LINKER_OPTION,
  # checked in the 4.7.2 template).
  "$cxx" "${flags[@]}" -x objective-c++ -fobjc-arc -c "$HAPTICS_SRC/haptics_backend_ios.mm" \
    -o "$obj/haptics_backend_ios.o" || return 1
  xcrun libtool -static -o "$obj/liblane1_haptics.a" "$obj"/*.o || return 1
  rm -rf "$xcf"
  xcodebuild -create-xcframework -library "$obj/liblane1_haptics.a" -output "$xcf" >/dev/null || return 1
  log "ios: $(rel "$xcf")"
}

# ---------------------------------------------------------------------------------------------------------------
# traffic (native/ext, godot-cpp) — native/ext/README.md "Build — macOS editor + iOS".
# pick_ios_archive <basename> <target> <dir>... → newest "<basename>*.a" whose name mentions ios and the target
# (falls back to any "<basename>*ios*.a"); prints nothing if none.
pick_ios_archive() {
  local base=$1 t=$2 f best="" best_m=0 m
  shift 2
  for pat in "$base.ios.$t*.a" "$base*ios*$t*.a" "$base*ios*.a"; do
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      m=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)
      if [ -z "$best" ] || [ "$m" -gt "$best_m" ]; then
        best=$f
        best_m=$m
      fi
    done < <(find "$@" -name "$pat" -type f 2>/dev/null || true)
    [ -z "$best" ] || break
  done
  printf '%s' "$best"
}

build_traffic_ios() {
  local t=$TARGET bdir="$EXT_DIR/build/ios-$TARGET" gen lib cpp
  have cmake || {
    warn "cmake not found (brew install cmake ninja)"
    return 1
  }
  [ -f "$EXT_DIR/CMakeLists.txt" ] || {
    warn "native/ext/CMakeLists.txt missing"
    return 1
  }
  bash "$LANE1_ROOT/tools/godot/build_ext.sh" --fetch-only || return 1
  gen=${CMAKE_GENERATOR:-Xcode}
  log "traffic ios $t (cmake -G $gen, -j$JOBS)"
  # Device run 2026-10-14: traffic=failed in ~7 s on Xcode 27 + CMake 4.3. With the Xcode generator and
  # CMAKE_SYSTEM_NAME=iOS, CMake's compiler checks build a signed test *app* and fail without a team. A static
  # library needs no signing: make try_compile build static libs and turn code signing off for these targets.
  cmake -S "$EXT_DIR" -B "$bdir" -G "$gen" -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN" -DGODOTCPP_TARGET="$t" \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED=NO \
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY="" >"$STATUS_DIR/traffic_cmake.log" 2>&1 || {
    warn "cmake configure failed (iOS traffic). Last lines of $(rel "$STATUS_DIR/traffic_cmake.log"):"
    grep -E -i 'error|fail|could not|not found' "$STATUS_DIR/traffic_cmake.log" | head -n 12 >&2 || true
    tail -n 12 "$STATUS_DIR/traffic_cmake.log" >&2
    return 1
  }
  cmake --build "$bdir" --target traffic --config Release -j "$JOBS" >"$STATUS_DIR/traffic_build.log" 2>&1 || {
    warn "cmake build failed (iOS traffic). Errors from $(rel "$STATUS_DIR/traffic_build.log"):"
    grep -E 'error:|Error|BUILD FAILED' "$STATUS_DIR/traffic_build.log" | head -n 20 >&2 || true
    return 1
  }
  # Device run 2026-10-14: the build succeeded but the exact names below were not found — the Xcode generator and
  # godot-cpp's suffix logic do not always produce "<name>.ios.<target>.arm64.a" in one fixed folder. Accept any
  # iOS static archive for this target (newest first), and print what exists if nothing matches.
  lib=$(pick_ios_archive "libtraffic" "$t" "$EXT_DIR/bin" "$bdir")
  cpp=$(pick_ios_archive "libgodot-cpp" "$t" "$bdir" "$EXT_DIR/bin")
  if [ -z "$lib" ] || [ -z "$cpp" ]; then
    warn "traffic build finished but libtraffic/libgodot-cpp .a not found under $(rel "$bdir") — archives present:"
    find "$bdir" "$EXT_DIR/bin" -name '*.a' 2>/dev/null | sed "s|$LANE1_ROOT/||" | head -n 20 >&2 || true
    return 1
  fi
  log "traffic archives: $(rel "$lib"), $(rel "$cpp")"
  rm -rf "$EXT_DIR/bin/libtraffic.ios.$t.xcframework" "$EXT_DIR/bin/libgodot-cpp.ios.$t.xcframework"
  xcodebuild -create-xcframework -library "$lib" -output "$EXT_DIR/bin/libtraffic.ios.$t.xcframework" >/dev/null
  xcodebuild -create-xcframework -library "$cpp" -output "$EXT_DIR/bin/libgodot-cpp.ios.$t.xcframework" >/dev/null
  log "traffic: $(rel "$EXT_DIR/bin/libtraffic.ios.$t.xcframework") + libgodot-cpp"
}

# ---------------------------------------------------------------------------------------------------------------
# Stubs: every iOS library a manifest names must exist, or Godot's export silently drops the libraries after it.
# manifest_ios_paths <manifest> <debug|release> -> "lib<TAB>res://..." / "dep<TAB>res://..." lines for that build type.
manifest_ios_paths() {
  awk -v want="$2" '
    function unq(s) { gsub(/^[ \t]*"|"[ \t]*$/, "", s); return s }
    /^\[/ { section = $0; indeps = 0; next }
    section == "[libraries]" && $0 ~ /^ios(\.debug|\.release)?[ \t]*=/ {
      key = $0; sub(/[ \t]*=.*/, "", key); val = $0; sub(/^[^=]*=/, "", val)
      if (key == "ios." want) exact = unq(val); else if (key == "ios") generic = unq(val)
      next
    }
    section == "[dependencies]" && $0 ~ /^ios(\.debug|\.release)?[ \t]*=[ \t]*\{/ {
      key = $0; sub(/[ \t]*=.*/, "", key); indeps = (key == "ios" || key == "ios." want); next
    }
    section == "[dependencies]" && indeps && /^\}/ { indeps = 0; next }
    section == "[dependencies]" && indeps && /"res:\/\// { v = $0; sub(/^[ \t]*"/, "", v); sub(/".*/, "", v); print "dep\t" v }
    END { if (exact != "") print "lib\t" exact; else if (generic != "") print "lib\t" generic }
  ' "$1"
}

manifest_entry_symbol() { # <manifest> -> entry_symbol value (empty if none)
  sed -n 's/^entry_symbol[[:space:]]*=[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$1" | head -n 1
}

make_stub_lib() { # <out.a> [entry_symbol] : one arm64 iphoneos static library (macOS only)
  # With an entry symbol the stub defines `GDExtensionBool <entry>(...)` returning false. Godot's generated dummy.cpp
  # takes the entry's address (non-weak) and the pbxproj adds -Wl,-U,_<entry>, so a stub WITHOUT the symbol links but
  # dies in dyld at launch ("symbol not found in flat namespace"). Returning false makes Godot log "initialization
  # function ... returned an error" and boot without that extension's classes (GDScript fallback / vibrate_handheld).
  local out=$1 entry=${2:-} d="$STATUS_DIR/stub" sdk base
  mkdir -p "$d"
  base="$d/$(basename "$out" .a)"
  sdk=$(xcrun --sdk iphoneos --show-sdk-path)
  if [ -n "$entry" ]; then
    case "$entry" in *[!A-Za-z0-9_]*) die 4 "bad entry_symbol '$entry'" ;; esac
    printf 'unsigned char %s(void *p, void *l, void *i) { (void)p; (void)l; (void)i; return 0; }\n' "$entry" >"$base.c"
  else
    printf 'static int lane1_stub_unused;\n' >"$base.c"
  fi
  xcrun --sdk iphoneos clang -arch arm64 -isysroot "$sdk" "-miphoneos-version-min=$IOS_MIN" -c "$base.c" -o "$base.o"
  rm -f "$out"
  xcrun libtool -static -o "$out" "$base.o"
}

write_stub_xcframework() { # <path.xcframework> [entry_symbol]
  local xcf=$1 entry=${2:-} name lib_name
  name=$(basename "$xcf" .xcframework)
  lib_name="$name.a"
  rm -rf "$xcf"
  mkdir -p "$(dirname "$xcf")"
  if is_macos; then
    make_stub_lib "$STATUS_DIR/stub/$lib_name" "$entry"
    xcodebuild -create-xcframework -library "$STATUS_DIR/stub/$lib_name" -output "$xcf" >/dev/null
  else
    # Container only (export smoke tests): a structurally valid xcframework around an empty ar archive.
    mkdir -p "$xcf/ios-arm64"
    printf '!<arch>\n' >"$xcf/ios-arm64/$lib_name"
    cat >"$xcf/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>AvailableLibraries</key><array><dict>
<key>LibraryIdentifier</key><string>ios-arm64</string><key>LibraryPath</key><string>$lib_name</string>
<key>SupportedArchitectures</key><array><string>arm64</string></array><key>SupportedPlatform</key><string>ios</string>
</dict></array><key>CFBundlePackageType</key><string>XFWK</string><key>XCFrameworkFormatVersion</key><string>1.0</string></dict></plist>
EOF
  fi
}

ensure_manifest_libraries() { # [--allow-fake] : stub every missing iOS library for $TARGET
  local kind manifest role res path entry missing=0 stubbed=0
  kind=${TARGET#template_}
  while IFS= read -r manifest; do
    entry=$(manifest_entry_symbol "$manifest")
    while IFS=$'\t' read -r role res; do
      [ -n "$res" ] || continue
      path="$LANE1_NATIVE/${res#res://}"
      if [ ! -e "$path" ]; then
        missing=$((missing + 1))
        if is_macos || [ "${1:-}" = "--allow-fake" ]; then
          if [ "$role" = lib ]; then write_stub_xcframework "$path" "$entry"; else write_stub_xcframework "$path"; fi
          stubbed=$((stubbed + 1))
          warn "stub: $(rel "$path") (from $(rel "$manifest")) — that extension's classes will be missing on device"
          status "stub:$(rel "$path")"
        fi
      fi
    done < <(manifest_ios_paths "$manifest" "$kind")
  done < <(find "$LANE1_NATIVE" -name '*.gdextension' -not -path '*/.godot/*' -not -path '*/godot-cpp/*' \
    -not -path '*/build/*' | sort)
  [ "$missing" = "$stubbed" ] || return 1
}

# ---------------------------------------------------------------------------------------------------------------
t0=$SECONDS
FAILED=0
if [ "$NO_HAPTICS" = 1 ]; then
  # Codex review: drop a cached real build so the export really uses the stub (ensure_manifest_libraries only
  # stubs missing files).
  rm -rf "$HAPTICS_BIN/liblane1_haptics.ios.xcframework"
  status "haptics=skipped --no-haptics"
else
  ensure_interface_header
  if is_macos; then
    if build_haptics_host_macos; then status "haptics_host=ok"; else
      status "haptics_host=failed"
      warn "macOS host haptics build failed (editor logs a load error; export continues)"
    fi
  else
    build_haptics_host_linux
    status "haptics_host=ok"
  fi
  if [ "$HOST_ONLY" = 0 ]; then
    if build_haptics_ios; then status "haptics=ok"; else
      status "haptics=failed"
      warn "iOS haptics build failed — the app runs with Input.vibrate_handheld fallback"
      rm -rf "$HAPTICS_BIN/liblane1_haptics.ios.xcframework"
    fi
  fi
fi

if [ "$HOST_ONLY" = 0 ]; then
  if [ "$NO_EXT" = 1 ]; then
    rm -rf "$EXT_DIR/bin/libtraffic.ios.$TARGET.xcframework"   # same as --no-haptics: force the stub
    status "traffic=skipped --no-ext"
  elif build_traffic_ios; then
    status "traffic=ok"
  else
    status "traffic=failed"
    warn "native/ext (traffic) iOS build failed — continuing with a stub; logs in $(rel "$STATUS_DIR")"
    rm -rf "$EXT_DIR/bin/libtraffic.ios.$TARGET.xcframework"
  fi
  ensure_manifest_libraries || {
    FAILED=1
    warn "could not create stub libraries; the export would drop extensions"
  }
fi

if [ "$CONTAINER_STUBS" = 1 ]; then
  is_macos && die 2 "--container-stubs is for the Linux container only"
  ensure_manifest_libraries --allow-fake || FAILED=1
fi

log "done in $((SECONDS - t0))s: $(tr '\n' ' ' <"$STATUS_FILE")"
[ "$FAILED" = 0 ] || exit 4
