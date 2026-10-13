#!/usr/bin/env bash
# build_ios_ext.sh — builds the GDExtensions an iOS export needs (called by tools/mac/ios_run.sh).
#
# 가설: ❓ (Mac 미검증) haptics(C 인터페이스, 소스 3개)는 xcrun clang++ + libtool + create-xcframework로 수 초에
#       끝나고, traffic(godot-cpp)은 native/ext/README.md의 CMake(-G Xcode, CMAKE_SYSTEM_NAME=iOS) 절차로 빌드된다.
#       ✅ (컨테이너) 빌드가 실패한 라이브러리 자리에 빈 정적 라이브러리(stub)를 두면 Godot 4.7.2 export가 끝까지
#       가고(누락 파일이 있으면 _export_additional_assets가 그 뒤 라이브러리를 건너뜀), 생성된 dummy.cpp가
#       진입 심볼을 약하게 참조(-Wl,-U)하므로 링크도 된다 → 게임은 그 클래스 없이 뜬다.
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
JOBS=$( (sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4) | head -n 1)
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
    -I"$HAPTICS_BUILD/gen" -I"$HAPTICS_SRC" "${srcs[@]}" -o "$out"
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
  for f in $HAPTICS_SOURCES_CPP; do
    "$cxx" "${flags[@]}" -c "$HAPTICS_SRC/$f" -o "$obj/${f%.cpp}.o"
  done
  # CoreHaptics/UIKit/Foundation need no explicit -framework: libgodot.a autolinks all three (LC_LINKER_OPTION,
  # checked in the 4.7.2 template).
  "$cxx" "${flags[@]}" -x objective-c++ -fobjc-arc -c "$HAPTICS_SRC/haptics_backend_ios.mm" -o "$obj/haptics_backend_ios.o"
  xcrun libtool -static -o "$obj/liblane1_haptics.a" "$obj"/*.o
  rm -rf "$xcf"
  xcodebuild -create-xcframework -library "$obj/liblane1_haptics.a" -output "$xcf" >/dev/null
  log "ios: $(rel "$xcf")"
}

# ---------------------------------------------------------------------------------------------------------------
# traffic (native/ext, godot-cpp) — native/ext/README.md "Build — macOS editor + iOS".
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
  cmake -S "$EXT_DIR" -B "$bdir" -G "$gen" -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DGODOTCPP_TARGET="$t" >"$STATUS_DIR/traffic_cmake.log" 2>&1 || {
    tail -n 20 "$STATUS_DIR/traffic_cmake.log" >&2
    return 1
  }
  cmake --build "$bdir" --target traffic --config Release -j "$JOBS" >"$STATUS_DIR/traffic_build.log" 2>&1 || {
    grep -E 'error:|Error' "$STATUS_DIR/traffic_build.log" | head -n 20 >&2 || true
    return 1
  }
  lib=$(find "$EXT_DIR/bin" "$bdir" -name "libtraffic.ios.$t.arm64.a" 2>/dev/null | head -n 1)
  cpp=$(find "$bdir" -name "libgodot-cpp.ios.$t.arm64.a" 2>/dev/null | head -n 1)
  [ -n "$lib" ] && [ -n "$cpp" ] || {
    warn "traffic build finished but libtraffic/libgodot-cpp .a not found under $(rel "$bdir")"
    return 1
  }
  rm -rf "$EXT_DIR/bin/libtraffic.ios.$t.xcframework" "$EXT_DIR/bin/libgodot-cpp.ios.$t.xcframework"
  xcodebuild -create-xcframework -library "$lib" -output "$EXT_DIR/bin/libtraffic.ios.$t.xcframework" >/dev/null
  xcodebuild -create-xcframework -library "$cpp" -output "$EXT_DIR/bin/libgodot-cpp.ios.$t.xcframework" >/dev/null
  log "traffic: $(rel "$EXT_DIR/bin/libtraffic.ios.$t.xcframework") + libgodot-cpp"
}

# ---------------------------------------------------------------------------------------------------------------
# Stubs: every iOS library a manifest names must exist, or Godot's export silently drops the libraries after it.
# manifest_ios_paths <manifest> <debug|release> -> res:// paths (libraries + dependencies) for that build type.
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
    section == "[dependencies]" && indeps && /"res:\/\// { v = $0; sub(/^[ \t]*"/, "", v); sub(/".*/, "", v); print v }
    END { if (exact != "") print exact; else if (generic != "") print generic }
  ' "$1"
}

STUB_LIB=""
make_stub_lib() { # builds one empty arm64 static library (macOS only) into $STUB_LIB
  [ -n "$STUB_LIB" ] && [ -f "$STUB_LIB" ] && return 0
  local d="$STATUS_DIR/stub" sdk
  mkdir -p "$d"
  sdk=$(xcrun --sdk iphoneos --show-sdk-path)
  printf 'static int lane1_stub_unused;\n' >"$d/stub.c"
  xcrun --sdk iphoneos clang -arch arm64 -isysroot "$sdk" "-miphoneos-version-min=$IOS_MIN" -c "$d/stub.c" -o "$d/stub.o"
  xcrun libtool -static -o "$d/libstub.a" "$d/stub.o"
  STUB_LIB="$d/libstub.a"
}

write_stub_xcframework() { # <path.xcframework>
  local xcf=$1 name lib_name
  name=$(basename "$xcf" .xcframework)
  lib_name="$name.a"
  rm -rf "$xcf"
  mkdir -p "$(dirname "$xcf")"
  if is_macos; then
    make_stub_lib
    cp "$STUB_LIB" "$STATUS_DIR/stub/$lib_name"
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
  local kind manifest res path missing=0 stubbed=0
  kind=${TARGET#template_}
  while IFS= read -r manifest; do
    while IFS= read -r res; do
      [ -n "$res" ] || continue
      path="$LANE1_NATIVE/${res#res://}"
      if [ ! -e "$path" ]; then
        missing=$((missing + 1))
        if is_macos || [ "${1:-}" = "--allow-fake" ]; then
          write_stub_xcframework "$path"
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
