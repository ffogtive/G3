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

## Traffic core (M1a) — `traffic/src/`

가설: ✅ 줄 단위 포트(같은 추첨 순서·같은 부동소수 연산 순서·안정 버킷 정렬·`-ffp-contract=off`)가 웹 골든을
비트 단위로 재현한다 — spawn 1·5·6판(트레이스 1051/610/977회 태그+u32), 틱 골든 600 + 4800틱 + 이벤트 18개
(debug·release `.so` 모두). 90판(161대 + 반대편 26대) `update` p95 0.03~0.07 ms/tick (예산 0.5 ms).

| File | What |
|---|---|
| `rng32.h` | `Mulberry32` (uint32 mulberry32, = JS `mulberry32`) |
| `traffic_core.{h,cpp}` | engine-free port of `game/js/traffic.js` @ 753549a: spawnJam (+ shoulder.js obstacle RNG), buckets, leaderOf, IDM, lane changes, JamShaper waves/sources, stuck assist, cheater event, minis, honk/letIn (+ fatigue, real-gap check), rageHorn, miniHit, release, post-release lane changes, opposite carriageway |
| `traffic.{h,cpp}` | GDScript classes `Traffic` and `Rng32`; `configure()` reads every tunable from `config.json` (`traffic.*`, `tune.*`, `road.*`; 233 keys, defaults = the JS literals) |
| `json_exact.{h,cpp}` | `Traffic.parse_json(text)`: correctly rounded JSON. Godot 4.7.2's `JSON.parse`/`to_float` is 1 ulp off on 16-17 digit numbers (`stages.json` has 113), so `core/db.gd` uses this when the ext is loaded |

Rules that keep the replay bit-exact (each one was golden-visible in the JS):
- one `Mulberry32` per stage, draws in JS order; `set_trace(true)` records `(tag, u32)` per draw with the tag names of `tools/content/lib/rng-trace.mjs`;
- expressions keep JS evaluation order; `Math.max/min` go through `jmax/jmin` (signed zero, NaN); `pow(x,2)` is `x*x`;
- buckets are rebuilt at the top of `update()` from [cars, obstacles, player, alive villains, extras] and sorted by (s, insertion index) = JS stable sort; queries between updates use the previous tick's buckets; removed obstacles stay in buckets until the next rebuild (like the JS splice);
- `sin(t*0.42 + lane*1.9)` is the only libm call that feeds state; `set_sin_override()` injects the recorded value (glibc `sin` also matched all 5400 recorded ticks, phones untested);
- **compile flags:** `-ffp-contract=off -fno-fast-math` (arm64 clang would otherwise fuse `a*b+c` into FMA). Keep them in the iOS/Android builds.
- R2 fix (NATIVE_PORT M1b): stuck assist runs while `jamLike`; `set_web_parity(true)` restores the web's `phase=='jam'` gate (golden replays use it).

### API (`Traffic`, RefCounted; reach it through `sim/traffic_bridge.gd` / `ClassDB`, never by name)
- M1-0 (kept): `tick(dt)`, `count()` (NPC cars, 0 before spawn), `get_tick_count()`, `get_sim_time()`, static `build_info()`, static `parse_json(text)`.
- setup: `configure({config, vehicle_kinds, mini_types, approach})`, `get_missing_params()`, `spawn_jam(stage, villains[{s,x,w,len,baseS,v,vNominal}], {s,lane,len,w}, seed, night)`, `kind_names()`.
- per tick: `set_player(s, x, v, lane, mode_jam)`, `set_player_dims(len, w)`, `set_player_stats(tow)`, `set_villain_count(n)` + `set_villain(i, s, base_s, x, w, len, v, v_nominal, alive)`, `set_extra_count/ set_extra(...)`, `set_context(phase, allow_events, jam_like, focus_s|NAN)`, `set_sin_override(PackedFloat64Array[5])` (one-shot), `update(dt, time)`.
- between ticks (main.js call sites): `honk(siren, trot) -> {kind, id}`, `rage_horn(range)`, `mini_hit(id, dmg)`, `smash(id)`, `remove_obstacle(id)`, `set_obstacle_ids(ids)`, `jolt(id)`, `release(time, wave_speed|-1, open_lane)`, `drop_walls(lanes, m)`, `emit_brake_wave(lane, s, strength)`, `let_in_player(lane, force)`.
- queries: `leader_of_player()`, `can_merge_into(lane, margin)`, `lane_blocked(lane, s_min, s_max, exclude_id)`, `gap_ahead(lane, s)`, `mini_target()`, `cars_behind_front(n, range)`.
- output: `get_buffer(alpha, include_opp)` (stride 8 `[id, kind, lane, x, s, yaw, v, lamp_bits]`, interpolated prev→current), `get_transforms_for(ids, alpha)` (MultiMesh buffer layout, 12 floats each; verified by a `MultiMesh.buffer` round trip under Xvfb Mobile), `get_car_specs()`, `get_obstacles()`, `get_opp()`, `get_barrier()`, `get_info()`, `get_state()`, `hash_bytes()` (golden `h` preimage), `take_events()`, `set_trace/take_trace`, `get_rng_draws()`, `peek_rng()`.
- `Rng32` (RefCounted): `set_seed`, `next_u32`, `next_float`, `get_draws` (GDScript twin: `core/mulberry32.gd`, class `Mulberry32`).

### Tests / bench
```bash
godot47 --headless --path native -s res://tests/run_tests.gd -- --filter=test_    # test_rng, test_spawn, test_traffic_golden
godot47 --headless --path native -s res://tests/bench/run_bench.gd                # 90-stage p50/p95 -> native/build/perf.json
```
The editor/headless binary loads the **template_debug** library (feature `debug`). For the release-`.so` number,
copy the project and map `linux.debug.x86_64` to `libtraffic.linux.template_release.x86_64.so` in the copy's
manifest (that is how the M1a numbers were taken), or export a Linux release build.
