# NATIVE_PORT — 네이티브 품질 이식 계획 (Godot 4 → iOS · Android)

가설:
- ✅ **Godot 4 프로젝트 1개에서 iOS(Metal)·Android(Vulkan) 네이티브 빌드 2개를 뽑는 것**이 사용자 결정 "C = 네이티브 품질"로 가는 최단 경로다. 복셀 화질에는 충분하고, 이 컨테이너에서 설치·헤드리스 테스트·Xvfb 스크린샷이 되는 엔진은 Godot뿐이다(M0 spike로 확인).
- ❓ **시뮬은 JS를 1:1로 옮긴다(같은 시드, 같은 RNG 순서). 데이터는 JS → JSON으로 export하고, 메시·소리·UI 그림은 다시 짜지 않고 bake한다.** ~~웹은 디자인 랩으로 계속 고친다~~ → 기각: 2026-10-13 피드백(N1~N5)부터는 웹을 고치지 않고 네이티브에 바로 반영한다. 웹은 동결된 동작 레퍼런스로 남는다.
- ❓ **컨테이너와 Mac 모두 4.7.2로 통일한다**(Nix 캐시 경로, 아직 미설치). ~~apt 4.6.3~~ → 기각: glibc 2.43이 필요해 24.04(2.39)에서 실행되지 않는다. 확인된 대체 버전은 4.4.1 ✅.

> 기준일 2026-10-13. ✅ 확인 · ❓ 미확인/실기기 미검증 · ❌ 기각. 근거 링크는 항목 옆에 단다.
> 관련 문서: `docs/V04_SPEC.md`(판 설계), `docs/ARCHITECTURE.md`(웹 모듈 계약), `docs/MOBILE_BUILD.md`(Flutter 기준이라 Godot용으로 다시 쓸 예정).

---

## 1. 결정

### 1-1 엔진: Godot 4.x · Mobile 렌더러 · typed GDScript

| 기준 | Godot 4.7 | Unity 6.3 LTS | 플랫폼별 네이티브 (Swift+Metal / Kotlin+Filament) | Flutter + flutter_scene |
|---|---|---|---|---|
| 복셀 화질 상한 | 충분 (그림자·글로우·톤맵·포그·MSAA·디밴딩) | 툴링 최고. 복셀에서 눈에 띄는 차이는 작음 | 이론상 무제한. 눈에 띄는 차이 없음 | pre-1.0 |
| 120Hz / 햅틱 | iOS 기본 120, Core Haptics 사용 | 설정하면 가능, Apple 공식 플러그인 | 완전 제어 | ❓ |
| **이 컨테이너에서 테스트** | **가능 (M0 ✅)** | **불가** (다운로드 차단, Personal 라이선스는 CLI 활성화 불가) | **불가** (Xcode 없음, AGP가 dl.google.com 차단) | 낮음 |
| 이식 비용 | 1회 (GDScript, JS와 비슷함) | 1회 (C#, 무거운 에디터) | **2회** (16k LOC × 2) | 1회 (미성숙한 엔진) |
| 비용 | MIT, $0 | Personal은 매출 $200k까지 무료 | $0 | $0 |

근거:
- iOS는 MoltenVK 없이 **네이티브 Metal**로 돈다. `rendering_device/driver.ios` 기본값이 `metal`이다 ([ProjectSettings](https://docs.godotengine.org/en/stable/classes/class_projectsettings.html#class-projectsettings-property-rendering-rendering-device-driver-ios)).
- **120Hz ProMotion이 기본값이다.** `display/window/ios/allow_high_refresh_rate`가 true이고 CADisplayLink를 120으로 요청하며, Info.plist에 `CADisableMinimumFrameDurationOnPhone`가 들어간다 ([godot_view_ios.mm](https://github.com/godotengine/godot/blob/4.7.2-stable/platform/ios/godot_view_ios.mm)).
- `Input.vibrate_handheld(ms, amplitude)`는 iOS에서 CHHapticEngine(Core Haptics), Android에서 VibrationEffect(진폭 포함)로 동작한다 ([os_apple_embedded.mm](https://github.com/godotengine/godot/blob/4.7.2-stable/drivers/apple_embedded/os_apple_embedded.mm)).
- Mobile 렌더러 기능: 그림자, glow, tonemap, fog, MSAA/FXAA/SMAA, DOF, decal, LightmapGI. **SSAO·SSR·TAA·FSR은 없다** ([renderers](https://docs.godotengine.org/en/stable/tutorials/rendering/renderers.html)). 모바일 Forward+는 "poorly optimized"라서 쓰지 않는다. 그래서 복셀 AO는 정점에 bake한다. 참고로 Unity도 URP SSAO가 모바일에서 느리다고 스스로 밝힌다 ([Unity](https://docs.unity.com/en-us/engine/6000.3/manual/xr/graphics/untethered-device-optimization)).
- 4.5.2와 4.6에서 Mali/Adreno Vulkan 크래시가 약 4%에서 1% 미만으로 줄었다. 4.6은 Mobile 렌더러에 디밴딩과 HDR 정밀도를 추가했다 ([4.6](https://godotengine.org/releases/4.6/)). 그래서 출시 버전은 4.6 이상이어야 한다.
- 모바일 C#은 아직 experimental이다 ([C# platform support](https://docs.godotengine.org/en/stable/tutorials/scripting/c_sharp/index.html#c-platform-support)). 그래서 **typed GDScript**를 쓰고, 프로파일링 결과가 요구할 때만 GDExtension(C++)로 간다.
- Unity Personal은 Hub 로그인이 필요하다 ([Unity license](https://docs.unity.cn/6000.2/Documentation/Manual/ManagingYourUnityLicense.html)). flutter_scene은 "pre-1.0, minor releases can break" 상태다 ([pub.dev](https://pub.dev/packages/flutter_scene)). SceneKit은 soft-deprecated다 ([Apple](https://developer.apple.com/documentation/realitykit/bringing-your-scenekit-projects-to-realitykit)).

### 1-2 버전 고정
- 최신 stable은 **4.7.2**(2026-08-18)다 ([릴리스](https://godotengine.org/article/maintenance-release-godot-4-7-2/)). 컨테이너에서 검증된 버전은 **4.4.1**(Ubuntu pool repack)이다.
- **규칙: 컨테이너, Mac, (나중의) CI는 정확히 같은 버전을 쓴다.** 프로젝트 포맷은 한 방향으로만 업그레이드되기 때문이다.
- **M1-0 게이트(4시간 timebox):** cache.nixos.org에 있는 `godot-4.7.2-stable`과 `godot-export-templates-bin-4.7.2-stable`([narinfo](https://cache.nixos.org/8m369hjybagbixqhb5y7c35igmhrcxz6.narinfo))을 설치하고 M0 테스트를 다시 돌린다.
  - 통과하면 4.7.2로 고정한다. 공식 템플릿이 함께 오므로 컨테이너에서 APK를 빌드할 가능성도 생긴다 ❓.
  - 실패하면 M1을 4.4.1로 진행하고, **M4 전에** 4.6 이상으로 올린다(Nix를 다시 시도하거나, Ubuntu pool의 orig tarball + scons로 소스 빌드).

### 1-3 Flutter 셸(`app/`)의 역할 → 제외
- Godot가 Xcode 프로젝트와 AAB를 직접 만든다. Flutter 층은 120Hz·입력·햅틱 경로에 보태는 게 없고 지연만 늘린다.
- `app/`는 **M1 합격 때까지 그대로 둔다.** 웹 빌드를 폰에서 띄워 보는 비교용이자 비상 출시안이다. M1 합격 뒤 삭제하고, git 이력에는 남는다.
- 번들 ID는 그대로 쓴다: iOS `com.ffogtive.lane1Chamgyoyuk`, Android `com.ffogtive.lane1_chamgyoyuk`.

### 1-4 "iOS·AOS 따로"의 뜻
- **게임·렌더 코드는 100% 공유하는 Godot 프로젝트 1개**에 export preset 2개를 둔다. 따로 만드는 것은 **얇은 플랫폼 플러그인뿐이다.**
  - `native/platform/ios`(Swift): AHAP 햅틱, thermalState, Game Center, StoreKit 2.
  - `native/platform/android`(Kotlin): `Surface.setFrameRate`(120Hz), 발열 상태, Play Billing/Games.
- 빌드·화질 티어·QA도 플랫폼마다 따로 한다. iOS는 Mac의 Xcode, Android는 Gradle 빌드다.
- 앱 2개를 처음부터 따로 짜는 안은 ❌다. 재작성이 2배이고, 복셀에서는 화질 이득이 없으며, 컨테이너에서는 둘 다 빌드할 수 없다.

---

## 2. 품질 목표 (측정 가능한 기준)

기준기: **iPhone 13 Pro**(A15, 120Hz)와 **iPhone 13**(A15, 60Hz). 최저 사양은 A12(iPhone XS/XR, 4.5.2 이후 기본값, [4.5.2](https://godotengine.org/article/maintenance-release-godot-4-5-2/)). Android는 Vulkan을 지원하는 중급기 1대.

| 항목 | 목표 | 측정 |
|---|---|---|
| 프레임 | ProMotion 기기는 게임플레이 **120fps**(p95 ≤ 8.3ms, p99 ≤ 11ms). 60Hz 기기는 **60 고정**(p99 ≤ 16.7ms). 90처럼 중간에서 흔들리면 안 되며, 120을 못 지키면 60으로 고정한다. 메뉴는 60 | Godot Performance 오버레이(디버그) + Xcode Metal System Trace. 1-1 전체 3회 |
| 프레임 예산 (A15, 8.3ms) | sim 틱 ≤ 2.0ms (그중 traffic 160대 ≤ 1.5ms) · 뷰 동기화+UI ≤ 1.0ms · 렌더 CPU ≤ 2.0ms(보이는 draw call ≤ 400) · GPU ≤ 6.0ms(MSAA 4x, render scale 0.85~1.0) | `Performance.get_monitor`를 틱마다 로깅하고 JSON으로 덤프 |
| 입력 지연 | 입력은 다음 sim 틱에 소비한다(≤ 8.3ms). touch-to-photon은 120Hz ≤ 50ms, 60Hz ≤ 75ms | 240fps 슬로모 촬영, 탭 20회 평균 |
| 메모리 | 상주 ≤ 500MB (iPhone 13) | Xcode Memory gauge |
| 로딩 | 콜드 스타트 → 타이틀 ≤ 3s. 스테이지 로드 ≤ 1.5s(스테이지 카드 뒤에서) | 로그 타임스탬프 |
| 발열·배터리 | 1-1을 20분 반복(120Hz, 밝기 50%)해도 thermalState ≤ fair, 배터리 ≤ 10% ❓(기준치 측정 후 조정) | Xcode Energy gauge, 플러그인 로그 |
| 앱 크기 | 다운로드 ≤ 120MB(iOS thinned / AAB 기기별), 경고선 150MB. Godot Android 기본 크기 ≈ 19MB ❓([forum](https://forum.godotengine.org/t/game-size-too-big-compared-to-apk/39416)) | App Store Connect / Play Console 크기 리포트 |

**조명·그림자·AO·포스트** (Mobile 렌더러 기준. 7개 SKY 프리셋마다 웹 레퍼런스 샷과 나란히 비교):
- DirectionalLight3D PSSM 2 split, max distance 80m. 그림자 맵은 A14 이상에서 2048, 그 아래 1024. soft filter를 쓴다. 차는 cast+receive, 도로는 receive만 한다.
- AO: 기존 높이 AO(`0.7+0.3·smoothstep`)를 유지하고, **bake 단계에서 정점별 레이캐스트 AO를 추가 ❓**한다. 차 밑에는 접지 블롭 그림자를 둔다. SSAO는 쓰지 않는다.
- HDR 램프 + glow(브레이크등 '빨간 바다', 비상등, 상향등, 폭발). AgX 톤매핑은 웹 화면에 맞춰 보정한다. 포그는 depth fog(웹의 linear fog와 같은 형태). MSAA 4x(TBDR GPU에서 저렴)와 디밴딩을 켜고, 프리셋별 색보정을 한다.
- **"웹보다 나아야 할 5가지" 체크리스트:** 그림자 계단 없음, 램프 블룸, 하늘 밴딩 없음, 원거리 지글거림 없음, 차의 접지감.

**오디오:**
- iOS(CoreAudio, `output_latency` 15ms 적용)에서 SFX 트리거부터 출력까지 ≤ 30ms. Android는 OpenSL ES라 이 설정이 무시된다([docs](https://docs.godotengine.org/en/stable/classes/class_projectsettings.html#class-projectsettings-property-audio-driver-output-latency)). 측정한 뒤 Oboe 플러그인이 필요한지 판단한다 ❓.
- 동시 보이스 ≤ 40, 클리핑 0(리미터 −0.6dB). 음악은 마디 단위로 전환하고, 백그라운드로 가면 정지한다. 무음 스위치를 존중한다(iOS session category 설정 확인 ❓).

**햅틱 맵**
- 웹의 `fx.shake` 호출 지점을 그대로 매핑한다. 기본 구현은 `vibrate_handheld(ms, 진폭)`이고, M4에서 iOS AHAP으로 바꾼다.
- 히트스톱·슬로모와 무관하게 실시간으로 즉시 울린다. 이벤트별 최소 간격을 두고, 전체 상한은 초당 12회다. 설정에서 끌 수 있다.
- 무음 플레이에서는 소리 텔(V04_SPEC 열린 질문 7)을 햅틱 틱이 대신한다.

| 게임 이벤트 (웹 위치) | 패턴 | 기본 (ms, 진폭) |
|---|---|---|
| 차선 변경 · 경적 | selection tick | 10, 0.25 / 20, 0.35 |
| 압정 명중 `hit` (초당 4회 상한) | 아주 약한 tick, 간격 ≥ 120ms | 8, 0.2 |
| 크리티컬 `crit` · 갓길 장애물 박살 (main.js:790) | medium | 25, 0.6 |
| 원흉 타이어 펑크 (boss.js:253) | heavy transient | 40, 0.9 |
| 내가 맞음: 잔챙이 투척 (main.js:734) / 추돌 (main.js:803) / 보스 공격 (main.js:744) | medium / medium-heavy / heavy | 30, 0.5 / 35, 0.7 / 50, 0.8 |
| 잔챙이 검거 (main.js:233) | 성공 더블탭 | 15+15, 0.5 (간격 60ms) |
| 분노 MAX `rageFull` · 분노 발사 (main.js:246) · 분노 명중 (main.js:606) | 상승 3틱 / heavy long / heavy | 10×3 / 80, 1.0 / 60, 0.9 |
| 보스 페이즈 전환 (main.js:261) | heavy | 60, 0.9 |
| **원흉 처치** (main.js:496) | 큰 충격 + 0.6s 감쇠 럼블 (AHAP) | 120, 1.0 |
| **해방 파도** (main.js:523) | 뒤로 퍼지는 펄스 4~6개, 파도 박자에 맞춤 | 20 × 5, 0.6→0.2 |
| 견인 `wreck` (main.js:481) | heavy + 긴 저강도 | 80, 1.0 → 300, 0.2 |
| 결과 화면 별·도장 · 1-5 깜빡이 딸깍 · N3 '단속 가능' 링 | light tick | 10, 0.3 |

---

## 3. 아키텍처

### 3-1 프로젝트 레이아웃
```
native/
  project.godot           # Mobile 렌더러, physics_ticks_per_second=120, autoload 순서: DB SaveGame InputBuffer Audio Haptics Fx UI
  export_presets.cfg      # iOS / Android / Linux(테스트용)
  data/                   # 생성물, 손으로 편집 금지 (3-6 참고)
  assets/{vehicles,props,road,projectiles,fxprops}/  # bake된 ArrayMesh .res + VehicleTemplate .tres
  assets/{audio,fonts,ui,textures}/
  core/     cfg.gd  rng32.gd  lane_entity.gd  db.gd  save_game.gd
  sim/      game_sim.gd traffic.gd npc_car.gd player.gd boss_manager.gd villain.gd weapons.gd
            shoulder_obstacle.gd autopilot.gd rewards.gd   behaviors/{sig_behavior,occupy,blinker_liar,tailgater,…}.gd
  view/     game.tscn game.gd(합성 루트·상태 머신) world.gd vehicle_factory.gd vehicle_view.gd camera_rig.gd release_wave.gd
  fx/ audio/ input/ ui/{hud,screens,theme}/ shaders/
  tests/    run_tests.gd  test_*.gd  golden/*.json  shots/baseline/*.png
  tools/    import_meshes.gd   # 헤드리스 EditorScript
  platform/{ios,android}/      # 얇은 네이티브 플러그인 (M4)
tools/ (레포 루트, Node)
  export-content.mjs  bake-meshes.mjs  bake-audio.mjs  bake-ui.mjs  parity.mjs  shot-diff.mjs  godot/install_godot.sh
```

### 3-2 시뮬과 렌더의 분리, 고정 틱
- **`sim/`은 RefCounted로만 짠다.** Node, 씬, 렌더 API를 쓰지 않는다. `GameSim.step(dt)`를 **SIM_HZ = 120**으로 고정해서 돌린다. 120Hz 화면은 프레임당 1틱, 60Hz는 2틱이다. `max_physics_steps_per_frame=4`로 두고, 90Hz처럼 어중간한 주사율은 physics interpolation으로 보간한다.
- 시간 배율(히트스톱 0, 슬로모 0.28/0.3, 일시정지 0)은 `sim dt = TICK × timeScale`로 직접 적용한다. **`Engine.time_scale`은 쓰지 않는다.** 카메라 스무딩, 플래시, 흔들림, UI는 실시간으로 돈다. 시계는 웹처럼 `time`(배율 적용)과 `real_time` 두 개를 유지한다.
- `step()`은 이벤트 배열(`[{type:"tirePop", …}]`)을 돌려준다. `game.gd` 한 곳에서 이것을 view, Fx, Audio, Haptics, UI로 나눠 보낸다. sim은 fx나 audio를 직접 부르지 않는다.
- **웹의 숨은 결합 3가지를 이식하면서 끊는다:**
  1. 차 치수를 메시가 아니라 `vehicle_kinds.json`에서 읽는다.
  2. buildVehicle의 seed 추첨과 갓길 장애물의 RNG 소비를 sim에서 똑같이 재현하고, 뷰는 spec만 받아 메시를 만든다.
  3. 보스 사망·피니시와 압정 판정이 sim의 pos/vel을 쓰게 한다(웹은 `-mesh.position.z`를 쓴다).
- 버킷 갱신 시점을 웹과 똑같이 둔다(player.update, requestLane, honk는 이전 프레임의 버킷을 쓴다). 핫패스 처리:
  - `leaderOf`는 이진 탐색으로 바꾼다.
  - 버킷은 삽입 정렬로 유지한다.
  - `includes` 대신 `is_npc` 플래그를 쓴다.
  - 기기에서 traffic이 1.5ms를 넘으면 Traffic/NpcCar를 GDExtension으로 옮긴다.

### 3-3 결정적 RNG (JS 시드와 일치)
- `rng32.gd`: mulberry32를 uint32 마스킹(`& 0xFFFFFFFF`)과 16비트 분할 imul로 구현한다. GDScript int가 64비트 signed이기 때문이다.
- 시드:
  - traffic: `mulberry32(id·1000+7)`
  - 월드 소품: `mulberry32(id·7919+13)`
  - 차 변형: `seed=floor(rng·1e6)`, `variant=canon(seed % variants)`
- **spawnJam의 추첨 순서를 그대로 지킨다:** 벽 차로 → 차로 0~3 {pickWeighted, _makeCar 5회, gapOf} → 갓길 셔플 → 아이템(장애물별 소비: 고장차 3, 콘 0, 낙하물 2+3nb) → 잔챙이 {type, cool} → 반대편 26대 × 6.
- 골든 데이터는 spawn 레이아웃만 비교한다(런타임 추첨은 dt에 따라 달라진다). 1-1 기준값: 126대, 첫 차는 1차로 버스 s=200.4453, 고장차 109.681(len 7), 콘 147.518, 잔챙이 131.90/66.63, 다음 추첨값 0.3714370721.
- 웹의 `Math.random` 부분(보스 공격 선택, 도발, fx 등)은 `RandomNumberGenerator(--seed)`로 바꾼다. 네이티브 헤드리스 실행은 **seed로 완전히 재현된다.**

### 3-4 좌표계 (웹과 같은 오른손 좌표계, Y-up, −Z가 전방이라 1:1로 복사)
- `s` = 도로 진행 거리, `z = −s`, x는 좌우(−X가 왼쪽, 1차로 쪽), 노면 y=0. 단위는 m와 m/s.
- `laneX(i)=(i−1.5)·3.6`: 0차로 −5.4 … 3차로 +5.4, 갓길(4)은 9.0. 중앙분리대 −8.25. 반대편은 `−11.1−3.6j`(rotation.y=π).
- 엔티티 s는 차 중심이고 범퍼는 ±len/2. 점유 판정은 `|x−laneX| < w/2+1.2`.
- 함정:
  - 웹의 Euler 순서는 XYZ이고 Godot 기본은 YXZ다. 여러 축을 함께 쓰는 노드(보스 피니시, 잔해)에는 `rotation_order=EULER_ORDER_XYZ`를 준다.
  - 앞면 판정이 Three는 CCW, Godot ArrayMesh는 CW다. 임포터에서 b와 c를 바꾼다.
  - 미사일 모델은 +Z를 향한다. `look_at(…, use_model_front=true)`를 쓴다.
  - 정점 색은 linear다(`vertex_color_is_srgb=false`).
  - PlaneMesh는 +Y, QuadMesh는 +Z를 향한다.
  - JSON 숫자는 전부 float이고, frontRow 키는 문자열이다.
  - JS의 `%`는 음수에서 결과가 다르므로 `fposmod`를 쓴다.
  - 스와이프 기준은 px가 아니라 pt로 환산한다.

### 3-5 모듈 매핑 (JS → Godot)
| JS (LOC) | Godot | 방식 |
|---|---|---|
| config.js (304) | `core/cfg.gd` + `data/config.json` | 상수는 이식, 표는 export |
| villain_catalog.json + stagegen.js (318) | `data/stages.json` 외 | **export만 한다** (lookbehind 정규식 등 때문에 이식하지 않음) |
| traffic.js (772) | `sim/traffic.gd`, `npc_car.gd`, `lane_entity.gd` + `view/vehicle_view.gd` | 이식 (85%가 sim) |
| player.js (234) · weapons.js (177) · rewards.js (61) | `sim/player.gd` · `sim/weapons.gd` · `sim/rewards.gd` | 이식 |
| boss.js (859) · behaviors/index.js (325) | `sim/boss_manager.gd`, `villain.gd`, `sim/behaviors/*.gd` | 이식 (sim이 pos 소유) |
| shoulder.js (85) | `sim/shoulder_obstacle.gd`(spec+RNG) + bake 메시 | RNG는 이식, 메시는 bake |
| main.js (1366) | `view/game.gd`(상태 머신), `camera_rig.gd`, `sim/autopilot.gd`, SaveGame | 로직 45%는 이식, 연출은 재구성 |
| input.js (78) | `input/input_buffer.gd` + InputMap | 이식 |
| world.js (231) | `view/world.gd` (Environment, 소품 RNG 루프 동일) | 이식 |
| vehicles.js (4072) · scenery.js (2299) | `assets/**/*.res` + `vehicle_factory.gd` + 셰이더 | **bake** |
| fx.js (1187) | `fx/fx.gd` (GPUParticles3D 레시피) | 재작성 (레시피 수치는 그대로) |
| audio.js (1167) | bake한 OGG/WAV + `audio/audio.gd` | **bake** |
| ui.js (2697) + style.css (2270) | `ui/*.tscn` + `ui_theme.tres` + SVG 래스터 | 재작성 (가장 큰 항목) |

### 3-6 데이터 흐름과 콘텐츠 파이프라인
```
game/js/{config.js, data/villain_catalog.json, stagegen.js} ─ tools/export-content.mjs ─▶ native/data/*.json ─▶ DB ─▶ GameSim
game/js/{vehicles.js, scenery.js} ─ tools/bake-meshes.mjs (Node+canvas stub) ─▶ build/bake/*.json+bin
                                   ─ godot --headless -s res://tools/import_meshes.gd ─▶ native/assets/**/*.res
game/js/audio.js ─ tools/bake-audio.mjs (Chromium OfflineAudioContext) ─▶ native/assets/audio + data/sfx.json, music.json
game/js/ui.js + css ─ tools/bake-ui.mjs (Chromium @3x) ─▶ native/assets/ui/*.png (9-slice), ui/svg/*.svg
런타임: 터치 → InputBuffer → GameSim.step(1/120) → events → game.gd → view 동기화 / Fx / Audio / Haptics / UI(값이 바뀔 때만)
```
- **진실 원천:** M2까지는 `game/js`의 데이터 표가 원천이다. `native/data/*.json`은 생성물이지만 커밋한다. `node tools/export-content.mjs --check`는 차이가 있으면 실패한다. M2 이후 원천을 `native/data/src`로 옮길지는 열린 질문 3에서 정한다.
- export 대상 표(스크래치 검증 스크립트 `stages.mjs`, `dims.mjs`, `golden.mjs`를 재사용):
  - `stages.json`: 100판. `schema_version`을 붙이고, frontRow는 배열로, zigCenter는 null로 정규화한다.
  - `chapters.json`, `album.json`, `cards.json`(처분 카드 표, ui.js에서 수동 추출).
  - `config.json`:
    - tune
    - npc: kinds의 가중치, 색 순서(RNG에 영향)
    - sky: 7개 + STAGE_SKY
    - shop, shop_default
    - lines: `*_LINES`, MINI_TYPES. main.js 인라인 대사는 수동으로 추출한다.
    - approach / jamShape / sig 원표
  - `vehicle_kinds.json`: variants, canon, 변형별 [L,W,H], 바퀴, 피벗. **dev stub의 치수는 틀리므로 쓰지 않는다.**
  - `rewards.json`, `text_content.json`(배너, 광고, 지명 EN).
  - 테스트 골든: `tests/golden/spawn_{1,5,6}.json`, `rng_1007.json`(처음 1000개 추첨값).
- 세이브: `lane1.progress.v1`(ver 3)과 같은 구조를 `user://progress.json`에 쓴다. 블박 사진은 `user://album/<id>.jpg`.

### 3-7 복셀 메시 파이프라인 (다시 만들지 않고 bake)
- `bake-meshes.mjs`는 수정하지 않은 vehicles.js/scenery.js를 Node에서 호출해 다음 조합을 순회한다:
  - KINDS × variant × detailed, PROJ 16종, FX_PROPS
  - 히어로 차량의 파손 L1~4 × focus, 오토바이 라이더 포즈 12종
  - 소품 kind × variant × 낮/밤, 도로 세그먼트 변형
- 덤프 내용: 파트별 삼각형(pos, normal, linear color, 도색 마스크), 피벗(바퀴, 운전자, cannon, muzzle 등), userData.
- `import_meshes.gd`(헤드리스) 처리:
  - 평면 단위로 정점을 용접해 indexed로 만든다(용량 약 −33%).
  - 와인딩을 뒤집는다.
  - 오프라인 정점 AO를 굽는다 ❓.
  - 결과로 ArrayMesh `.res`와 `VehicleTemplate.tres`(파트 메시, 피벗, 치수)를 만든다.
- **NPC 도색은 런타임 tint로 한다**(instance uniform). 색마다 bake하지 않는다. 검증: 15색 × 8종에서 bake 결과와 tint 결과를 비교하고, 어긋나면 색별 bake로 물러난다 ❓.
- 램프는 별도 surface에 lamp 셰이더(instance uniform on/keepOn, HDR emission)를 쓴다. 깜빡이 후광은 빌보드 쿼드다.
- 드로우 경로:
  - M1: NPC마다 MeshInstance3D 1개(surface ≤ 3).
  - draw call이 400을 넘거나 렌더 CPU가 2ms를 넘으면 (kind, variant)별 MultiMesh로 바꾸고 INSTANCE_CUSTOM에 도색과 램프 비트를 넣는다.
  - 소품은 200m 청크마다 MultiMesh + visibility_range.
- 검증: 삼각형 수(sedan 1188 / detailed 1520), 치수, 차량 갤러리 스크린샷(`game/dev/vehicles.html`과 같은 각도).

### 3-8 UI · 오디오 · 입력
- **UI:**
  - ui.js의 API 표면을 그대로 둔다(`show_stage_card` → await, `show_fail` → `"retry"|"menu"`, `set_hud`…). 화면은 Control 씬으로 만든다.
  - 폰트: Black Han Sans/Jua(npm @fontsource, fontTools로 서브셋 병합) + Noto Sans KR 폴백. 외곽선은 LabelSettings 프리셋 O2/O3/O4/O6.
  - 광택 버튼과 표지판 판은 CSS를 Chromium에서 @3x 9-slice PNG로 굽는다. 아이콘 43종은 `Image.load_svg_from_string`으로 런타임에 래스터한다.
  - 애니메이션은 Tween/AnimationPlayer로 옮기되, M1 화면에 쓰는 것만 한다. 말풍선은 `Camera3D.unproject_position`으로 위치를 잡는다. safe area는 `DisplayServer.get_display_safe_area()`로 처리한다.
- **오디오:**
  - bake 대상: SFX 31종 × 테이크 3~5개, 노래 4곡(루프 포인트 포함), 응원 경적, 앰비언스, 엔진 RPM 루프 약 6개.
  - 버스 구성은 SFX/Ambience/Music→Duck→Master이고, Master에 Compressor(−10dB, 6:1, 3/220ms)와 HardLimiter를 건다.
  - `sfx.json`의 max/gap/pri로 보이스를 받아들일지 정하고, 전체 상한은 40이다. 해방 BGM은 응원 박자 그리드(130BPM)에 맞춰 들어간다.
- **입력:**
  - `InputBuffer`는 웹의 consume/peek/endFrame/tap/isDown 의미를 그대로 따른다. 엣지는 **sim 틱이 소비할 때까지 래치**한다.
  - 스와이프: 34pt(|dx| > 1.2|dy|)면 차선 이동, 위로 60pt(|dy| > 1.5|dx|)면 분노.
  - TouchScreenButton으로 멀티터치를 처리한다(발사를 누른 채 스와이프). 포커스를 잃으면 모든 입력을 해제한다. 테스트용 `InputBuffer.inject()`를 둔다.

---

## 4. 테스트 루프

### 4-1 컨테이너 설치
```bash
bash tools/godot/install_godot.sh   # M0에서 검증: Ubuntu pool의 4.4.1 + 부족한 soname 10개, 28초, 멱등. M1-0에서 scratchpad → repo로 옮긴다
godot --version                     # 4.4.1.stable.debian4.4.1+ds-1  (/opt/godot/godot → /usr/local/bin/godot)
bash tools/godot/install_godot_nix.sh   # M1-0 게이트: 4.7.2 + 공식 템플릿 ❓ (실패하면 4.4.1 유지)
```

### 4-2 테스트 단계 (모두 exit 0이면 통과)
| 단계 | 명령 | 내용 | 시간 |
|---|---|---|---|
| T0 unit | `godot --headless --path native -s res://tests/run_tests.gd -- --suite=unit` | rng32가 JS 스트림과 일치, laneX, stages.json 로드, **spawn 골든 일치**, IDM 한 스텝, 이벤트 계약 | < 10s |
| T1 autoplay | `godot --headless --path native -s res://tests/run_tests.gd -- --suite=autoplay --stages=1 --seeds=20 --report=build/native.jsonl` | 오토파일럿으로 result까지 진행, 스크립트 에러 0. playtest.mjs와 같은 JSON 줄 출력: `{stage, phases, bumps, supers, playerHp, fails, done, errors}` | 약 1분 |
| T2 화면 | `xvfb-run -a -s "-screen 0 1280x1024x24" godot --path native --rendering-method mobile --audio-driver Dummy -- --shots=m1 --out=build/shots` 후 `node tools/shot-diff.mjs build/shots native/tests/shots/baseline` | 출시용 Mobile 렌더러(lavapipe)로 고정 틱·고정 카메라 샷을 찍는다. 빈 화면 가드(lum sd ≤ 0.05면 실패). 베이스라인과 diff 비교, 바뀌면 사람이 눈으로 확인 | 샷당 약 0.2~0.3s |
| T3 export | `godot --headless --path native --export-release Linux build/linux/lane1.x86_64` | export 파이프라인 스모크 (Linux 템플릿은 apt에서 받음) | < 1분 |
| T4 웹 대비 | `npx http-server . -p 8090 -c-1 -s &` → `node tools/playtest.mjs --stages 1 --ff 6 > build/web.jsonl` → `node tools/parity.mjs build/web.jsonl build/native.jsonl` | 페이즈 시간(sim 시간 기준) 중앙값 ±15%, 완주율 100%. 1:1이 아닌 부분은 웹의 Math.random 탓이라 통계로만 비교한다 | 약 5분 |
- 프레임 시퀀스: `--write-movie build/mov/frame.png --fixed-fps 30 --quit-after N` (M0에서 동작 ✅).
- lavapipe는 170~300ms/frame이라 **성능 수치로는 의미가 없다.** 화면 회귀와 셰이더 컴파일 확인용이다.

### 4-3 Mac/폰에서만 되는 것
- iOS export·서명·Xcode 빌드. Android APK/AAB도 해당한다(컨테이너에서는 템플릿과 SDK가 차단됨. Nix 템플릿 + apt apksigner 경로는 ❓).
- Metal과 Adreno/Mali 실제 셰이딩, 120Hz와 프레임 시간, touch-to-photon, 햅틱 체감, 오디오 지연, 발열·배터리, 메모리, 노치·다이내믹 아일랜드의 safe area, 실제 앱 크기.
- iOS 시뮬레이터는 Compatibility 렌더러만 돈다([iOS export](https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_ios.html)). 그래서 **화질 확인은 실기기에서만 한다.**

---

## 5. 마일스톤

### M0 spike — ✅ 완료 (근거)
- 설치 ✅: 4.4.1을 Ubuntu pool에서 받아 soname 10개를 옆에 두고 LD_LIBRARY_PATH로 띄운다. 28초, 멱등. 4.6.3은 glibc 2.43이 필요해 ❌.
- 헤드리스 ✅: `-s res://tests/test_sim.gd`로 9 PASS, 약 1.5s. 실패하면 exit 3이 그대로 전달된다. 더미 렌더러에서 6.9ms/frame.
- 렌더 ✅: Xvfb에서 Compatibility(llvmpipe, 178ms), **Mobile(lavapipe Vulkan, 170~207ms)**, Forward+(290ms, SSAO 확인) 모두 PNG 저장. 복셀 차 20대, 그림자, 포그를 눈으로 확인했다.
- export: 템플릿이 없으면 ❌. apt의 Linux 템플릿으로는 ✅(81MB 바이너리, Mobile 렌더 확인). **iOS/Android 템플릿은 컨테이너에서 받을 수 없다.**
- 산출물은 현재 세션 scratchpad의 `godot-spike/`에 있다. M1-0에서 `native/`와 `tools/godot/`로 옮긴다.

### M1 — 수직 슬라이스: 1-1 완전 플레이 + 품질 패스
**범위**
0. 레포 골격(`native/`, 설치 스크립트, run_tests 러너, CI 스크립트 `tools/native-check.sh`)과 버전 게이트(1-2).
1. `export-content.mjs`로 데이터와 골든 생성. `core/`(cfg, rng32, lane_entity, DB).
2. sim:
   - traffic: spawnJam(장애물 RNG 포함), 버킷, IDM, 차선 변경, stuck assist, honk/letIn/cheater, release, rageHorn
   - player: jam/boss/cruise, 추돌, 박살, 점프
   - boss: occupy 모듈, highbeam/컵 투척/경적파/lunge, 타이어 펑크, 로켓 피니시
   - weapons: 압정, 미사일
   - 잔챙이 2명
   - game 상태 머신: intro → jam → boss → kill → release → cruise → result, 견인·재도전
   - HP, 분노, 점수, 미션 3개, 보상, 세이브
   - autopilot
3. 1-1에 필요한 bake 자산:
   - 차량: player, villainSedan, NPC 8종, 고장차
   - 투사체·마커: 콘, 압정, 미사일, 컵, 경고 마커
   - 배경: 도로(day), 소품, 갠트리, VMS(LED 셰이더), CCTV, 배너
   - `vehicle_view` 램프 API
4. world(day 프리셋)와 camera_rig(모든 페이즈, real dt 스무딩, FOV 이징, 흔들림).
5. FX: 폭발, 스파크, 연기, 잔해, 컨페티, 충격파, 스피드라인, 해방 파도 셰이더. 시계 두 개.
6. 오디오 bake(1-1에 쓰는 SFX, 노래 4곡, 앰비언스, 엔진)와 햅틱 맵(2절) 기본 구현.
7. UI 1차:
   - HUD: 범퍼 HP, 분노, 속도계, 진행바, 거리, 보스바+타이어, 배너, 말풍선, 팝, 토스트
   - 터치 컨트롤, 스테이지 카드, 결과(간소화), 실패 카드
   - 1-1만 있는 타이틀
8. **웹 피드백 규칙을 적용한다(웹은 고치지 않음):**
   - N1: 진행바와 거리 숫자는 같은 값 하나에서 나온다(`(p.s−startS)/(villain.s_live−startS)`). 빌런 아이콘은 실시간으로 움직인다.
   - N2: R은 항상 현재 목표를 조준하고 록온 레티클을 보여 준다. 갓길 청소는 별도 행동으로 뺀다.
   - N4: 모든 공격은 록온 기반이다.
   - N5: 깜빡이, 브레이크등, 상향등은 발광 + 블룸으로 키운다.
9. 품질 패스: 2절의 조명, 포스트, 120Hz, 입력, 햅틱, 오디오, 발열을 기기에서 튜닝한다.

**합격 기준**
- T0: spawn_1/5/6 골든과 rng 1000개가 완전히 일치한다.
- T1: 1-1을 20 seed로 돌려 완주율 100%, 에러 0.
- T4: 웹 대비 페이즈 시간 ±15%. 단, N2 때문에 바뀐 R 관련 지표는 제외한다.
- T2: 페이즈 6개 × 샷 베이스라인을 승인받는다. 웹 대비 비교 샷도 함께 본다.
- 기기(iPhone 13 Pro): 2절 표의 프레임·입력·발열·메모리 목표 충족. 60Hz 기기는 60 고정. Android 중급기는 60 안정.
- **사용자 판정: "웹보다 확실히 낫다"** (그림자, 블룸, 손맛, 햅틱). 결과는 FEEDBACK_LOG에 기록한다.

**리스크:** GDScript traffic 성능(미측정, GDExtension 폴백), bake 충실도(와인딩, 색, tint), 버전 고정, UI 이식 분량, lavapipe와 실기기의 차이.

### M2 — 1챕터 동등성 (1-1 ~ 1-10, 시그니처 모듈)
- **범위:**
  - 웹에 이미 있는 blinker_liar(1-5)와 tailgater(1-6, sig body를 트래픽 버킷에 넣음)를 이식한다.
  - 웹에 없는 **7개는 V04_SPEC을 기준으로 네이티브에서 새로 구현한다**: cutin_snap, duo_link, straddle_mirror, speed_kangaroo, merge_reflex, phone_drift, landlord(1-10 보스, 페이즈 포함).
  - 접근 규칙(갓길 open/crowded/blocked/closed/dark/watched/merge/debris/occupied × 경적 모드)과 JamShaper 프리셋.
  - SKY 프리셋 night/rain/fog와 날씨 GPU 파티클.
  - **N3 '단속' 시스템**: 잔챙이와 숨은 위반차를 하나로 묶은 시스템. 위반별 아이콘, 처음 보일 때 1회 설명, 근접하면 링 + 햅틱. 범위는 V04_SPEC 부록 A.
  - UI 2차: 타이틀·챕터, 도감, 차고/상점, 결과 보상 타임라인과 블박 사진, 일시정지.
- **합격 기준:**
  - 10판 × 20 seed autoplay 완주율 100%.
  - 판별 텔 샷이 베이스라인으로 승인된다.
  - 10판 모두 기기 성능 목표를 충족한다.
  - 보스 첫 시도 실패율 약 30%(봇에 노이즈를 넣어 측정, V04_SPEC 열린 질문 9).
  - 사용자 재플레이: "3초 안에 판이 구분되고 원인이 읽히는가", "해법이 판마다 다른가".
- **리스크:** 새 모듈 7개는 웹이라는 오라클이 없어서 설계 검증을 네이티브에서 처음 하게 된다. UI 분량.

### M3 — 100판 + 패밀리 모듈
- **범위:**
  - V04_SPEC '100판 일반화'의 패밀리 모듈과 카탈로그 스키마(family, sig{module, params}, approach, fight, payoff).
  - 터널(조명 셰이더), 합류 테이퍼, 단속 갠트리, 데칼.
  - 피니시 balloon/heli/ufo, 드론, 상점 차량 3종, 1-EX 퍼레이드.
  - 나머지 SKY 프리셋, 소품, 그리고 100판 전체에서 차종이 다 해석되는지 확인.
- **합격 기준:** 100판 × 5 seed 완주율 100%, 에러 0. 최저 사양(A12)에서 60 고정. 앱 크기 ≤ 120MB.
- **리스크:** 160대 이상인 판의 sim 비용(GDExtension 전환 시점), 자산 수가 늘면서 커지는 앱 크기.

### M4 — 플랫폼 기능
- **범위:**
  - Game Center(godot-ios-plugins, Mac에서 scons로 빌드, [repo](https://github.com/godotengine/godot-ios-plugins)), Play Games 3.4.
  - StoreKit 2(API가 아직 불안정 ❓, [repo](https://github.com/godot-sdk-integrations/godot-storekit2)), Play Billing v9.1([repo](https://github.com/godot-sdk-integrations/godot-google-play-billing)).
  - iOS AHAP 햅틱 플러그인, Android `setFrameRate` 플러그인(Godot는 이 호출을 하지 않는다 ❓, [android java](https://github.com/godotengine/godot/tree/4.7.2-stable/platform/android/java)), 발열 플러그인.
  - 광고(Poing AdMob, [repo](https://github.com/poing-studios/godot-admob-plugin))는 열린 질문 4의 결정에 따른다.
- **합격 기준:** 샌드박스에서 구매·복원, 리더보드 제출, 햅틱 체감 QA, Android 120Hz 기기에서 120 확인.
- **리스크:** 플러그인 성숙도, iOS 플러그인은 Mac에서만 빌드.

### M5 — TestFlight / Play 내부 테스트 → 출시
- **범위:** Apple Developer Program, Play Console, 개인정보 매니페스트와 연령 등급, 크래시 리포트(Play 네이티브 심볼 업로드), 스토어 자산.
- **합격 기준:** TestFlight와 Play 내부 테스트를 2주 진행. 크래시 없는 세션 ≥ 99.5%. Android vitals 크래시와 ANR이 Play 경고선 아래.
- **리스크:** 4.6 미만으로 출시할 때의 GPU 크래시(1-2 참고). 심사 4.2(Minimum Functionality)는 네이티브 앱이라 위험이 낮다.

---

## 6. Mac / Xcode / Android 빌드 경로 (요약; `docs/MOBILE_BUILD.md`는 M1에서 Godot용으로 다시 씀)
1. Mac에 **컨테이너와 같은 버전의** Godot 공식 빌드와 export 템플릿(Editor › Manage Export Templates)을 설치한다. Xcode는 26 이상(App Store 업로드 요건, MOBILE_BUILD.md 참고).
2. **iOS:** `native/` 열기 → Project › Export › iOS(Team ID, 번들 ID) → Xcode 프로젝트로 export → Xcode에서 실기기로 Run. 플러그인은 `.gdip` + xcframework 형태다. Linux에서 Xcode 프로젝트만 export할 수 있는지는 ❓.
3. **Android:** OpenJDK 17과 Android SDK(platform-tools, build-tools 35.0.1, platform 35, Gradle 빌드용 NDK). 플러그인이 있으므로 Gradle 빌드로 AAB를 만들고, 디버그 APK는 `adb install`로 올린다 ([Android export](https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_android.html)). VIBRATE 권한이 필요하다.
4. 나중에 선택: macOS CI 러너에서 두 플랫폼을 자동 빌드한다.

---

## 7. 열린 질문 (사용자 결정 필요, 괄호 안이 제안 기본값)
1. **기기 범위와 테스트 장비**: 지금 가진 기기는 무엇인가? (기본값: iOS A12 이상, Android는 Vulkan 기기 + GLES3 자동 폴백. 측정 기준기는 iPhone 13 Pro + 60Hz 아이폰 1대 + Android 중급기 1대, Apple silicon Mac.)
2. **120Hz 정책** (기본값: 게임플레이 120, 메뉴 60. 발열이 'serious'이거나 저전력 모드면 자동으로 60. 설정에 '배터리 절약(60)' 토글.)
3. **웹과 데이터 원천** (기본값: 웹 코드는 지금 동결하고 동작 레퍼런스로만 쓴다. 튜닝과 카탈로그는 M2까지 `game/js`에서 고친 뒤 export하고, M2 이후 원천을 `native/data/src`로 옮긴다. `app/`(Flutter)는 M1 합격 뒤 삭제.)
4. **수익 모델** (M4 범위를 정함) (기본값: 무료 + 선택형 보상 광고(결과 화면 포상금 2배) + 광고 제거·외형 IAP. 강제 전면 광고는 없음.)
5. **고사양 렌더 티어** (기본값: 모든 기기에 Mobile 렌더러 + bake AO. Forward+ '고화질' 티어(SSAO, 빗길 SSR)는 M3에서 성능 여유가 확인되면 최신 Pro 기기 한정으로 실험한다.)
