# native/ext — C++ GDExtension (traffic core)

가설: ✅ godot-cpp **10.0.0-stable**(버전 독립 릴리스, `api_version=4.7` JSON 내장)을 SHA로 고정하면
엔진 4.7.2와 API가 정확히 일치한다(엔진 덤프와 비교: 메서드 17821개, 누락 0, 해시 변경 0).
❓ iOS xcframework / Android .so 빌드는 Mac·NDK에서 아직 검증 전이다(아래 절차는 godot-cpp 공식 방식 그대로).

## Layout

| Path | What | Git |
|---|---|---|
| `CMakeLists.txt` | top-level build: godot-cpp + `traffic` target | tracked |
| `traffic/src/` | `Traffic` (RefCounted) + `register_types.cpp` (entry `traffic_library_init`) | tracked |
| `traffic/.gdignore` | keeps C++ sources out of Godot's importer | tracked |
| `traffic.gdextension` | manifest: per-platform library paths (`res://ext/bin/...`) | tracked |
| `godot-cpp/` | godot-cpp checkout at the pinned SHA (fetched by `tools/godot/build_ext.sh`) | ignored |
| `build/<platform>-<target>/` | CMake build trees | ignored |
| `bin/` | built libraries that the manifest points at | ignored |

## Pins

| Thing | Pin | Why |
|---|---|---|
| Engine | Godot **4.7.2-stable** (upstream commit `ed1daf0bf001b61586d9930840f2f1394092c079`) | NATIVE_PORT 1-2 |
| godot-cpp | tag `10.0.0-stable` = commit `507ed9d840c01a3c5b2a39af8bb4000bfac30bf5` | godot-cpp stopped making `godot-4.x-stable` tags after 4.5; v10 targets 4.3+ via `api_version` |
| API | `GODOTCPP_API_VERSION=4.7` (`gdextension/extension_api-4-7.json`) | `compatibility_minimum = "4.7"` in the manifest |
| C++ | C++17, `-static-libstdc++ -static-libgcc` on Linux | the container's Nix-built Godot has no libstdc++ on its search path |

`bash tools/godot/build_ext.sh --verify-api` dumps the running engine's `extension_api.json` and diffs every
class/builtin method hash against the pinned JSON (container result: 17821 methods, 0 missing, 0 changed).

### Why not a git submodule (NATIVE_PORT 3-1 says "서브모듈")
The pin is the same — one exact commit — but it lives in `tools/godot/build_ext.sh` (`GODOT_CPP_SHA`), and the
script clones/verifies it. Reasons: (1) the M1-0 workers may not touch the git index (a submodule add stages a
gitlink); (2) `git clone --recursive` is one more thing to forget on the Mac, while every build entry point
(`build_ext.sh`, later `tools/mac/ios_run.sh`) already runs the fetch; (3) the fetch refuses any other SHA.
Converting to a submodule later is a one-liner (`git submodule add -b 10.0.0-stable https://github.com/godotengine/godot-cpp native/ext/godot-cpp`)
— drop the `/ext/godot-cpp/` line from `native/.gitignore` when doing so.

## Build — Linux (container, verified)

```bash
bash tools/godot/install_godot_nix.sh          # godot47 = 4.7.2 (once)
bash tools/godot/build_ext.sh                   # template_debug -> native/ext/bin/libtraffic.linux.template_debug.x86_64.so
bash tools/godot/build_ext.sh --target=all      # + template_release (needed for --export-release Linux)
bash tools/native-check.sh                      # import + T0 (test_ext) + Xvfb Mobile smoke shot
```
First build ≈ 7 min on 4 cores (godot-cpp bindings: ~1090 objects); incremental ≈ 1 s.

Library names follow godot-cpp's suffix convention `lib<name>.<platform>.<target>.<arch>`; the manifest maps
`*.debug` feature tags (editor, debug exports) to `template_debug` and `*.release` to `template_release`.

## Build — macOS editor + iOS (Mac, not yet verified ❓)

Prereqs: Xcode ≥ 26, `brew install cmake ninja`, Python 3. The Mac must run the same Godot **4.7.2** (official
build) for the editor and export templates.

```bash
G=native/ext; B=$G/build
bash tools/godot/build_ext.sh --fetch-only   # clones godot-cpp, refuses any SHA but 507ed9d840c0…

# macOS editor (universal) -> bin/libtraffic.macos.template_debug.framework/libtraffic.macos.template_debug
cmake -S $G -B $B/macos-template_debug -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DGODOTCPP_TARGET=template_debug -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"
cmake --build $B/macos-template_debug --target traffic

# iOS device (arm64, static) — repeat with template_release for release exports
for T in template_debug template_release; do
  cmake -S $G -B $B/ios-$T -G Xcode -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DGODOTCPP_TARGET=$T
  cmake --build $B/ios-$T --target traffic --config Release
  # traffic (.a) and godot-cpp (.a) each become an xcframework; the manifest lists godot-cpp under [dependencies].
  xcodebuild -create-xcframework -library "$(find $G/bin $B/ios-$T -name "libtraffic.ios.$T.arm64.a" | head -1)" \
             -output $G/bin/libtraffic.ios.$T.xcframework
  xcodebuild -create-xcframework -library "$(find $B/ios-$T -name "libgodot-cpp.ios.$T.arm64.a" | head -1)" \
             -output $G/bin/libgodot-cpp.ios.$T.xcframework
done
```
Notes:
- iOS links extensions **statically** (CMake makes `traffic` a STATIC library when `CMAKE_SYSTEM_NAME=iOS`), so
  godot-cpp is shipped as its own xcframework — that is the `[dependencies]` block in `traffic.gdextension`
  (same scheme as godot-cpp's `test/generate_xcframework.sh`). Godot's iOS export copies both into the Xcode
  project. An iOS-simulator slice is not built: the simulator only runs the Compatibility renderer (4-3).
- The xcframework export path has had bugs ([godot#90168](https://github.com/godotengine/godot/issues/90168));
  if the exported Xcode project misses the libraries, check *Build Phases › Link Binary* first.
- **Headless first import on a fresh clone:** seed `native/.godot/extension_list.cfg` with
  `res://ext/traffic.gdextension` before `godot --headless --import/--export-*`. Without it, Godot 4.7.2
  discovers the extension mid-scan, regenerates docs on a worker thread and can crash on quit
  (`EditorHelp::_load_doc_thread` → `EditorLog::add_message`, SIGSEGV; 3/3 here). `tools/native-check.sh`
  does this seeding; the Mac one-command script must do the same.

## Build — Android (M2, not yet verified ❓)

With the NDK (r27+) and the SDK on a machine that can reach `dl.google.com`:
```bash
for T in template_debug template_release; do
  cmake -S native/ext -B native/ext/build/android-$T -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE=$ANDROID_NDK/build/cmake/android.toolchain.cmake \
        -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-24 -DGODOTCPP_TARGET=$T
  cmake --build native/ext/build/android-$T --target traffic
done   # -> bin/libtraffic.android.<T>.arm64.so
```

## Current API (M1-0 placeholder)

`Traffic` (RefCounted): `tick(dt: float)`, `count() -> int`, `get_tick_count() -> int`, `get_sim_time() -> float`,
static `build_info() -> String`. M1a replaces the body with Rng32, spawnJam, buckets, IDM, lane changes and the
NPC MultiMesh buffer writes (NATIVE_PORT 3-2, 3-7). GDScript should go through `sim/traffic_bridge.gd` and use
`ClassDB.class_exists(&"Traffic")` guards wherever a missing library must not break parsing (see `tests/test_ext.gd`).
