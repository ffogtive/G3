# NATIVE_PORT — 네이티브 품질 이식 계획 (Godot 4 → iOS · Android)

가설:
- ✅ **Godot 4 프로젝트 1개에서 iOS(Metal)·Android(Vulkan) 네이티브 빌드 2개를 뽑는 것**이 사용자 결정 "C = 네이티브 품질"로 가는 최단 경로다(M0 spike: 이 컨테이너에서 설치·헤드리스 테스트·Xvfb 샷이 되는 엔진은 Godot뿐). ~~게임 코드는 전부 typed GDScript, 기기에서 느리면 그때 GDExtension~~ → ❌ 기각: 같은 traffic 핫루프가 GDScript에서 JS보다 32~41배 느리다(컨테이너 실측, 1-1 추정 11~16ms/tick, 예산 1.5ms). **traffic 코어는 처음부터 C++ GDExtension**으로 짜고, 나머지는 GDScript다(C++로 예산 충족은 ❓, M1-0 perf 스위트로 확인).
- ❓ **시뮬은 JS를 1:1로 옮긴다(같은 시드, 같은 RNG 순서). 데이터는 M1-0에 한 번 export하고, 그 뒤로는 `native/data/src`가 원천이다. 정점색 지오메트리와 소리는 bake하고, 텍스트 판·셰이더·UI는 Godot에서 만든다.** ~~메시·소리·UI 그림은 다시 짜지 않고 bake~~ → 부분 기각: 런타임 텍스트(Canvas2D 16곳)와 ShaderMaterial·onBeforeCompile은 bake할 수 없다. ~~웹은 디자인 랩으로 계속 고친다~~ → 기각: N1~N5부터 웹은 고치지 않는다. 웹은 `web-frozen` 태그로 고정된 T4 오라클이다.
- ❓ **"웹보다 확실히 낫다"는 조명·120Hz·햅틱에서 나온다.** 그래서 4.7.2 고정과 iOS 햅틱 모듈을 먼저 하고, **M1a(3~5일)에 사용자 iPhone에서 웹과 나란히 놓고 먼저 판정한다.** ~~게이트 실패 시 M1은 4.4.1로 진행, M4 전에 업그레이드~~ → ❌ 기각: 4.6 전 Mobile 렌더러는 RGB10A2 밴딩이 있고 glow 합성 순서가 달라서, 그 위에서 한 화질 튜닝과 판정이 무효가 된다. ~~apt 4.6.3~~ → ❌ 기각: glibc 2.43 필요. 4.4.1 ✅은 sim·T0·T1 전용이다.

> 기준일 2026-10-13. ✅ 확인 · ❓ 미확인/실기기 미검증 · ❌ 기각. 근거 링크는 항목 옆에 단다.
> 관련 문서: `docs/V04_SPEC.md`(판 설계), `docs/ARCHITECTURE.md`(웹 모듈 계약), `docs/MOBILE_BUILD.md`(Flutter 기준이라 Godot용으로 다시 쓸 예정).
> 2026-10-13 리뷰(blocker 1, major 10, minor 8)를 반영했다. 정정하거나 받아들이지 않은 부분은 8절에 한 줄씩 남긴다.

---

## 1. 결정

### 1-1 엔진: Godot 4.7.2 · Mobile 렌더러 · typed GDScript + C++ GDExtension(traffic 코어)

| 기준 | Godot 4.7 | Unity 6.3 LTS | 플랫폼별 네이티브 (Swift+Metal / Kotlin+Filament) | Flutter + flutter_scene |
|---|---|---|---|---|
| 복셀 화질 상한 | 충분 (그림자·글로우·톤맵·포그·MSAA·디밴딩) | 툴링 최고. 복셀에서 눈에 띄는 차이는 작음 | 이론상 무제한. 눈에 띄는 차이 없음 | pre-1.0 |
| 120Hz / 햅틱 | iOS 기본 120. 햅틱은 기본 API가 약해서(continuous + intensity뿐) **얇은 iOS 모듈이 필요** | 설정하면 가능, Apple 공식 플러그인 | 완전 제어 | ❓ |
| **이 컨테이너에서 테스트** | **가능 (M0 ✅)** | **불가** (다운로드 차단, Personal 라이선스는 CLI 활성화 불가) | **불가** (Xcode 없음, AGP가 dl.google.com 차단) | 낮음 |
| 이식 비용 | 1회 (GDScript, traffic 코어만 C++) | 1회 (C#, 무거운 에디터) | **2회** (16k LOC × 2) | 1회 (미성숙한 엔진) |
| 비용 | MIT, $0 | Personal은 매출 $200k까지 무료 | $0 | $0 |

근거:
- iOS는 MoltenVK 없이 **네이티브 Metal**로 돈다. `rendering_device/driver.ios` 기본값이 `metal`이다 ([ProjectSettings](https://docs.godotengine.org/en/stable/classes/class_projectsettings.html#class-projectsettings-property-rendering-rendering-device-driver-ios)).
- **120Hz ProMotion이 기본값이다.** `display/window/ios/allow_high_refresh_rate`가 true이고 CADisplayLink를 120으로 요청하며, Info.plist에 `CADisableMinimumFrameDurationOnPhone`가 들어간다 ([godot_view_ios.mm](https://github.com/godotengine/godot/blob/4.7.2-stable/platform/ios/godot_view_ios.mm)).
- **`Input.vibrate_handheld(ms, amplitude)`는 우리 햅틱 맵을 표현하지 못한다.** iOS 구현은 CHHapticEngine을 쓰지만, 호출마다 패턴과 플레이어를 새로 만들고 이벤트는 `CHHapticEventTypeHapticContinuous` 하나, 파라미터는 `HapticIntensity` 하나뿐이다. Sharpness와 transient가 없고 `setAutoShutdownEnabled:true`라 쉬다가 첫 호출이 늦다. 4.4와 4.7.2가 같다 ✅([4.7.2 apple_embedded.mm](https://github.com/godotengine/godot/blob/4.7.2-stable/drivers/apple_embedded/apple_embedded.mm), [4.4 ios.mm](https://github.com/godotengine/godot/blob/4.4-stable/platform/ios/ios.mm)). 그래서 iOS 햅틱은 M1a의 자체 모듈로 하고(2절), `vibrate_handheld`는 Android 임시 폴백으로만 쓴다.
- Mobile 렌더러 기능: 그림자, glow, tonemap, fog, MSAA/FXAA/SMAA, DOF, decal, LightmapGI. **SSAO·SSR·TAA·FSR은 없다** ([renderers](https://docs.godotengine.org/en/stable/tutorials/rendering/renderers.html)). 모바일 Forward+는 "poorly optimized"라서 쓰지 않는다. 그래서 복셀 AO는 정점에 bake한다. 참고로 Unity도 URP SSAO가 모바일에서 느리다고 스스로 밝힌다 ([Unity](https://docs.unity.com/en-us/engine/6000.3/manual/xr/graphics/untethered-device-optimization)).
- **화질 작업은 4.6 이상에서만 의미가 있다.**
  - 4.6 전 Mobile 렌더러는 RGB10A2로 그려 어두운 영역에 밴딩이 생긴다([de-banding 셰이더 사례](https://godotshaders.com/shader/mobile-vulkan-de-banding-post-process/)). 4.6이 Mobile에 디밴딩과 HDR 정밀도를 추가했다([4.6](https://godotengine.org/releases/4.6/)).
  - 4.6에서 Mobile·Forward+의 glow가 톤매핑 전에 합성되도록 바뀌었다([4.6 dev 2](https://godotengine.org/article/dev-snapshot-godot-4-6-dev-2/)). 4.4.1에서 맞춘 glow와 램프 값은 업그레이드하면 다시 맞춰야 한다.
  - 셰이더 베이커(export 때 사전 컴파일, Metal 첫 사용 스터터 감소)는 4.5부터다([pipeline compilations 4.5](https://docs.godotengine.org/en/4.5/tutorials/performance/pipeline_compilations.html)).
  - 4.5.2와 4.6에서 Mali/Adreno Vulkan 크래시가 약 4%에서 1% 미만으로 줄었다([4.6](https://godotengine.org/releases/4.6/)).
- 모바일 C#은 아직 experimental이다 ([C# platform support](https://docs.godotengine.org/en/stable/tutorials/scripting/c_sharp/index.html#c-platform-support)). 그래서 **typed GDScript**가 기본이다. 단, **traffic 코어는 처음부터 C++ GDExtension**이다(3-2의 실측).
- Unity Personal은 Hub 로그인이 필요하다 ([Unity license](https://docs.unity.cn/6000.2/Documentation/Manual/ManagingYourUnityLicense.html)). flutter_scene은 "pre-1.0, minor releases can break" 상태다 ([pub.dev](https://pub.dev/packages/flutter_scene)). SceneKit은 soft-deprecated다 ([Apple](https://developer.apple.com/documentation/realitykit/bringing-your-scenekit-projects-to-realitykit)).

### 1-2 버전 고정
- 최신 stable은 **4.7.2**(2026-08-18)다 ([릴리스](https://godotengine.org/article/maintenance-release-godot-4-7-2/)). 컨테이너에서 검증된 버전은 아직 **4.4.1**(Ubuntu pool repack)뿐이다.
- **규칙: 컨테이너, Mac, (나중의) CI는 정확히 같은 버전을 쓴다.** 프로젝트 포맷은 한 방향으로만 업그레이드되기 때문이다. godot-cpp도 엔진 버전에 맞는 태그로 고정한다(서브모듈, `git ls-remote`로 태그 접근 확인 ✅).
- **M1-0 게이트 = 하드 게이트: 4.7.2가 통과하기 전에는 조명·포스트·T2 베이스라인 작업을 시작하지 않는다.** 경로는 순서대로 시도한다.
  - **(a) Nix (timebox 4시간):** cache.nixos.org의 에디터 `godot-4.7.2-stable`(store path `2snzvv05…`/`iqjxzh1y…`)과 `godot-export-templates-bin-4.7.2-stable`(1.27GB, [narinfo](https://cache.nixos.org/8m369hjybagbixqhb5y7c35igmhrcxz6.narinfo)) 존재 확인 ✅. Nix godot은 Nix glibc 클로저로 링크되므로 시스템 lavapipe(시스템 libLLVM·libstdc++)를 섞지 않고 **Nix mesa(lavapipe)와 Nix vulkan-loader를 같은 클로저로 받는다.**
    - 합격 조건: M0 테스트 재실행 + **Xvfb에서 `--rendering-method mobile` 샷 PNG가 나오고 빈 화면 가드를 통과** + 템플릿 디렉터리 이름(`4.7.2.stable`)이 에디터의 `VERSION_FULL_CONFIG`와 일치(install 스크립트가 검사).
    - 통과하면 공식 템플릿이 함께 오므로 컨테이너에서 APK를 빌드할 가능성도 생긴다 ❓.
  - **(b) 소스 빌드:** (a)가 실패하면 `git clone --depth 1 -b 4.7.2-stable https://github.com/godotengine/godot`(태그 접근 확인 ✅)을 scons로 Linux 에디터만 빌드한다(4코어 약 60~90분 ❓). 템플릿은 (a)의 Nix `-bin`을 쓴다.
  - **(c) 4.4.1은 sim·T0·T1 개발에만 허용한다.** 4.4.1에서 만든 `.tscn`/`.tres`는 4.7.2 에디터에서 `--headless --import` 후 재저장해 올리고, 그 절차를 `tools/godot/UPGRADE.md`에 적는다. 조명·glow·톤맵 값과 T2 베이스라인은 4.4.1에서 만들지 않는다.

### 1-3 Flutter 셸(`app/`)의 역할 → 제외
- Godot가 Xcode 프로젝트와 AAB를 직접 만든다. Flutter 층은 120Hz·입력·햅틱 경로에 보태는 게 없고 지연만 늘린다.
- `app/`는 **M1c 합격 때까지 그대로 둔다.** 웹 빌드를 폰에서 띄워 보는 비교용(M1a 나란히 판정에 씀)이자 비상 출시안이다. M1c 합격 뒤 삭제하고, git 이력에는 남는다. Flutter 셸의 진행도는 옮기지 않는다(미출시, 3-6).
- 번들 ID는 그대로 쓴다: iOS `com.ffogtive.lane1Chamgyoyuk`, Android `com.ffogtive.lane1_chamgyoyuk`.

### 1-4 "iOS·AOS 따로"의 뜻
- **게임·렌더 코드는 100% 공유하는 Godot 프로젝트 1개**에 export preset 2개를 둔다. C++ traffic 코어(`native/ext/traffic`)도 공유하고 플랫폼마다 빌드만 따로 한다(Linux .so, iOS xcframework, Android .so). 따로 만드는 것은 **얇은 플랫폼 모듈뿐이다.**
  - `native/platform/ios`(Objective-C++ GDExtension, godot-cpp 공용, ext와 같은 빌드 경로):
    - **M1a:** Core Haptics 햅틱(2절), `ProcessInfo.thermalState`·`isLowPowerModeEnabled` 로그.
    - M4: Game Center, StoreKit 2(기존 `.gdip` 플러그인 사용).
  - `native/platform/android`(Kotlin, Godot Android 플러그인 v2):
    - **M2:** `VibrationEffect.Composition` primitive 햅틱, 발열 상태.
    - M4: `Surface.setFrameRate`(120Hz), Play Billing/Games.
- 빌드·화질 티어·QA도 플랫폼마다 따로 한다. iOS는 Mac의 Xcode(`tools/mac/ios_run.sh`), Android는 Gradle 빌드다.
- 앱 2개를 처음부터 따로 짜는 안은 ❌다. 재작성이 2배이고, 복셀에서는 화질 이득이 없으며, 컨테이너에서는 둘 다 빌드할 수 없다.

---

## 2. 품질 목표 (측정 가능한 기준)

기준기: **iPhone 13 Pro**(A15, 120Hz)와 **iPhone 13**(A15, 60Hz). 최저 사양은 A12(iPhone XS/XR, 4.5.2 이후 기본값, [4.5.2](https://godotengine.org/article/maintenance-release-godot-4-5-2/)). Android는 Vulkan을 지원하는 중급기 1대(M2부터). **사용자가 실제로 가진 기기는 열린 질문 1이며, M1-0 전에 반드시 답을 받는다.** 기준기가 없으면 사용자 기기를 기준기로 바꾸고 목표는 그대로 둔다.

| 항목 | 목표 | 측정 |
|---|---|---|
| 프레임 | ProMotion 기기는 게임플레이 **120fps**(p95 ≤ 8.3ms, p99 ≤ 11ms). 60Hz 기기는 **60 고정**(p99 ≤ 16.7ms). 90처럼 중간에서 흔들리면 안 되며, 120을 못 지키면 60으로 고정한다. 메뉴는 60 | Godot Performance 오버레이(디버그) + Xcode Metal System Trace. 1-1 전체 3회 |
| 프레임 예산 (A15, 8.3ms) | sim 틱 ≤ 2.0ms (그중 traffic 160대 ≤ 1.5ms, C++) · 뷰 동기화+UI ≤ 1.0ms · 렌더 CPU ≤ 2.0ms(**보이는 draw ≤ 250, 그림자 패스 포함 ≤ 400**) · GPU ≤ 6.0ms(MSAA 4x, render scale 0.85~1.0) | 컨테이너: T0 `--suite=perf`(traffic p95 ≤ 0.5ms, GameSim ≤ 2ms), T2 draw call 덤프. 기기: `Performance.get_monitor`를 틱마다 로깅하고 JSON으로 덤프 |
| 히치 | **첫 kill 구간(원흉 처치 → 해방 파도) 최대 프레임 ≤ 16.7ms.** 블박 캡처 순간 포함 | 기기 프레임 로그(위와 같음) |
| 입력 지연 | 입력은 다음 sim 틱에 소비한다(≤ 8.3ms). touch-to-photon은 120Hz ≤ 50ms, 60Hz ≤ 75ms | 240fps 슬로모 촬영, 탭 20회 평균 |
| 메모리 | 상주 ≤ 500MB (iPhone 13) | Xcode Memory gauge |
| 로딩 | 콜드 스타트 → 타이틀 ≤ 3s. 스테이지 로드 ≤ 1.5s(스테이지 카드 뒤에서, 텍스트 판 생성과 FX 예열 포함) | 로그 타임스탬프 |
| 발열·배터리 | 1-1을 20분 반복(120Hz, 밝기 50%)해도 thermalState ≤ fair, 배터리 ≤ 10% ❓(기준치 측정 후 조정) | **M1a iOS 모듈의 thermalState·저전력 모드 로그(10초 간격)** + Instruments Thermal State 트랙 + Xcode Energy gauge |
| 앱 크기 | 다운로드 ≤ 120MB(iOS thinned / AAB 기기별), 경고선 150MB. Godot Android 기본 크기 ≈ 19MB ❓([forum](https://forum.godotengine.org/t/game-size-too-big-compared-to-apk/39416)) | App Store Connect / Play Console 크기 리포트 |

**조명·그림자·AO·포스트** (Mobile 렌더러, 4.7.2 기준. 7개 SKY 프리셋마다 웹 레퍼런스 샷과 나란히 비교):
- **출발점은 웹의 조명 조건을 그대로 재현하는 것이다.** 사용자가 확정한 복셀 팔레트는 웹의 조건에서 나온다: 톤매핑 없음(`main.js:57-61`에서 설정하지 않으므로 Three 기본값 NoToneMapping, 선형·클램프), HemisphereLight(하늘 `0xbfe4ff`, 땅 `0x8a9a6a`, 1.2, `world.js:16`), Directional 2.5(`world.js:18`), MeshLambert flatShading(Three r170) ✅.
  - **톤매퍼 기본값은 Linear(exposure 1.0)다.** HDR 램프는 `glow_hdr_threshold`로 블룸만 받게 한다. AgX·Filmic은 디버그 패널의 사용자 A/B 옵션으로만 둔다(열린 질문 6). Linear에서는 `tonemap_white`가 쓰이지 않는다(8절).
  - **반구광:** Godot에는 HemisphereLight가 없다. `ambient_light_source=SKY`로 두고, ambient 전용 2색 sky 셰이더(top=`0xbfe4ff`, bottom=`0x8a9a6a`)를 `Environment.sky`에 건다. 배경은 웹처럼 별도 sky 돔 메시(이식한 `scenery.sky` 셰이더)로 그려 ambient와 분리한다(`background_mode=COLOR`). ΔE가 합격선을 넘으면 차·소품 셰이더의 ambient에 hemi 항(`mix(ground, sky, n.y·0.5+0.5)`)을 직접 넣는 쪽으로 바꾼다.
  - **환산표:** Three r170 Lambert(직접광에 1/π)와 Godot 광원 에너지 사이의 환산값을 SKY 프리셋 7개마다 샷 비교로 정해 `data/src/sky.json`에 넣는다.
  - **T2 웹 동일 카메라 샷 쌍:** `tools/shot.mjs`(Playwright, 기존 ✅)로 웹 샷을, Godot으로 같은 포즈의 샷을 찍어 평균 색차 ΔE를 리포트한다(합격선은 M1a에서 첫 측정 후 정함 ❓).
- DirectionalLight3D PSSM 2 split, max distance 80m. 그림자 맵은 A14 이상에서 2048, 그 아래 1024. soft filter를 쓴다. 차는 cast+receive, 도로는 receive만 한다.
- AO: 기존 높이 AO(`0.7+0.3·smoothstep`)를 유지하고, **bake 단계에서 정점별 레이캐스트 AO를 추가 ❓**한다. 차 밑에는 접지 블롭 그림자를 둔다. SSAO는 쓰지 않는다.
- HDR 램프 + glow(브레이크등 '빨간 바다', 비상등, 상향등, 폭발). 포그는 depth fog(웹의 linear fog와 같은 형태). MSAA 4x(TBDR GPU에서 저렴)와 디밴딩(4.6+)을 켜고, 프리셋별 색보정을 한다.
- **"웹보다 나아야 할 5가지" 체크리스트:** 그림자 계단 없음, 램프 블룸, 하늘 밴딩 없음, 원거리 지글거림 없음, 차의 접지감. 웹과 같은 팔레트·명암 대비를 유지한 채로 이 5가지만 나아져야 한다("웹과 다르다"가 아니라 "웹보다 낫다").

**히치 방지** (셰이더 컴파일·GPU readback):
- export preset에서 **셰이더 베이커(4.5+)를 켠다.** 로드 시점 사전 컴파일은 그때 씬에 있는 메시·셰이더 조합에만 적용되고, 런타임에 처음 쓰는 조합은 그때 컴파일되기 때문이다([pipeline compilations](https://docs.godotengine.org/en/stable/tutorials/performance/pipeline_compilations.html)).
- **예열:** 스테이지 카드가 떠 있는 동안 모든 FX 재질과 파티클(폭발, 스파크, 컨페티, 충격파, 해방 파도 등)을 카메라 밖에서 1프레임씩 인스턴스화한다.
- **블박 사진:** 웹은 kill 직후 0.45초에 캡처한다(`main.js:502`). 메인 뷰포트 `get_image()`(동기 readback) 대신 256×144 SubViewport에 따로 그리고 `RenderingDevice.texture_get_data_async`로 비동기로 읽는다.

**오디오:**
- iOS(CoreAudio, `output_latency` 15ms 적용)에서 SFX 트리거부터 출력까지 ≤ 30ms. Android는 OpenSL ES라 이 설정이 무시된다([docs](https://docs.godotengine.org/en/stable/classes/class_projectsettings.html#class-projectsettings-property-audio-driver-output-latency)). 측정한 뒤 Oboe 플러그인이 필요한지 판단한다 ❓.
- 동시 보이스 ≤ 40, 클리핑 0(리미터 −0.6dB). 음악은 마디 단위로 전환하고, 백그라운드로 가면 정지한다. 무음 스위치를 존중한다(iOS session category 설정 확인 ❓).

**햅틱 맵**
- **기본 구현은 M1a의 iOS 모듈이다**(`native/platform/ios/haptics`):
  - CHHapticEngine 1개를 상주시키고(auto-shutdown 끔), 이벤트별 CHHapticPattern과 player를 미리 만들어 둔다. transient(intensity + sharpness)와 짧은 continuous를 조합한다.
  - 차선 변경·light tick은 `UISelectionFeedbackGenerator`/`UIImpactFeedbackGenerator`를 쓰고 매 페이즈 시작에 `prepare()`한다.
  - 앱 활성·비활성과 엔진 `resetHandler`/`stoppedHandler`에서 엔진을 재시작한다.
  - 같은 모듈이 thermalState·저전력 모드를 로그로 남긴다(2절 발열 행).
- Android는 M2에서 `VibrationEffect.Composition` primitive(CLICK, TICK, THUD, LOW_TICK)로 옮긴다. 그 전까지는 `vibrate_handheld(ms, 진폭)` 폴백을 쓴다.
- 패턴 수치는 `data/src/haptics.json`에서 런타임에 읽는다. 개발 빌드의 디버그 패널에서 다시 빌드하지 않고 조정한다(4-3).
- 웹의 `fx.shake` 호출 지점을 그대로 매핑하되, 키는 줄번호가 아니라 **sim 이벤트 이름**이다. T0 이벤트 계약 테스트가 매핑 누락을 잡는다(웹의 `fx.shake` 13곳 ✅).
- 히트스톱·슬로모와 무관하게 실시간으로 즉시 울린다. 이벤트별 최소 간격을 두고, 전체 상한은 초당 12회다. 설정에서 끌 수 있다.
- 무음 플레이에서는 소리 텔(V04_SPEC 열린 질문 7)을 햅틱 틱이 대신한다.

| 게임 이벤트 (웹 위치) | iOS 패턴 (intensity, sharpness) ❓기기 튜닝 | Android 폴백 (ms, 진폭) |
|---|---|---|
| 차선 변경 · 경적 | selection 생성기 / transient 0.35, 0.3 | 10, 0.25 / 20, 0.35 |
| 압정 명중 `hit` (초당 4회 상한, 간격 ≥ 120ms) | transient 0.2, 0.8 | 8, 0.2 |
| 크리티컬 `crit` · 갓길 장애물 박살 (main.js:790) | transient 0.6, 0.6 | 25, 0.6 |
| 원흉 타이어 펑크 (boss.js:253) | transient 0.9, 0.9 | 40, 0.9 |
| 내가 맞음: 잔챙이 투척 (main.js:734) / 추돌 (main.js:803) / 보스 공격 (main.js:744) | transient 0.5, 0.3 / 0.7, 0.3 / 0.8, 0.2 + continuous 80ms 0.4 | 30, 0.5 / 35, 0.7 / 50, 0.8 |
| 잔챙이 검거 (main.js:233) | 성공 더블탭: transient 0.5, 0.7 × 2 (간격 60ms) | 15+15, 0.5 (간격 60ms) |
| 분노 MAX `rageFull` · 분노 발사 (main.js:246) · 분노 명중 (main.js:606) | 상승 3틱 transient 0.3→0.6→0.9, 0.8 / continuous 80ms 1.0, 0.4 / transient 0.9, 0.5 | 10×3 / 80, 1.0 / 60, 0.9 |
| 보스 페이즈 전환 (main.js:261) | transient 0.9, 0.6 | 60, 0.9 |
| 원흉 1대 처치(여럿 중 마지막 아님, '1대 참교육!') (main.js:630) | transient 0.8, 0.5 | 50, 0.8 |
| **원흉 처치** (main.js:496) | transient 1.0, 0.7 + continuous 0.6s 감쇠 0.6→0, 0.2 | 120, 1.0 |
| **해방 파도** (main.js:523) | 파도 박자에 맞춘 transient × 5, 0.6→0.2, 0.4 | 20 × 5, 0.6→0.2 |
| 견인 `wreck` (main.js:481) | transient 1.0, 0.3 + continuous 300ms 0.2, 0.1 | 80, 1.0 → 300, 0.2 |
| 결과 화면 별·도장 · 1-5 깜빡이 딸깍 · N3 '단속 가능' 링 | light impact 생성기 또는 transient 0.3, 0.8 | 10, 0.3 |

---

## 3. 아키텍처

### 3-1 프로젝트 레이아웃
```
native/
  project.godot           # Mobile 렌더러, physics_ticks_per_second=120, physics interpolation 항상 켬
                          # autoload 순서: DB SaveGame InputBuffer Audio Haptics Fx UI
  export_presets.cfg      # iOS / Android / Linux(테스트용). 모바일 preset은 셰이더 베이커 켬
  data/src/*.json         # 원천(M1-0 이후 사람이 고치는 곳): config, sky, haptics, villain_catalog, cards, lines …
  data/*.json             # 생성물(tools/content/build.mjs), 손으로 편집 금지, 커밋함
  ext/traffic/            # C++ GDExtension: Rng32, LaneEntity, NpcCar, Traffic, NPC MultiMesh 버퍼 쓰기
  ext/godot-cpp/          # 서브모듈, 엔진 태그에 고정
  assets/{vehicles,props,road,projectiles,fxprops}/  # bake된 ArrayMesh .res + VehicleTemplate .tres (정점색 지오메트리만)
  assets/{audio,fonts,ui,textures}/                  # fonts/OFL.txt 포함
  core/     cfg.gd  db.gd  save_game.gd
  sim/      game_sim.gd traffic_bridge.gd player.gd boss_manager.gd villain.gd weapons.gd
            shoulder_obstacle.gd autopilot.gd rewards.gd   behaviors/{sig_behavior,occupy,blinker_liar,tailgater,…}.gd
  view/     game.tscn game.gd(합성 루트·상태 머신) world.gd vehicle_factory.gd npc_multimesh.gd hero_vehicle_view.gd
            text_panel.gd camera_rig.gd release_wave.gd debug_panel.gd(개발 빌드 전용)
  fx/ audio/ input/ ui/{hud,screens,theme}/
  shaders/  sky hemi_sky tunnel_ctl zipper vms_led self_lit release_wave lamp npc_tint (.gdshader)
  tests/    run_tests.gd  test_*.gd  bench/  golden/*.json  saves/v{1,2,3}.json  shots/baseline/*.png
  tools/    import_meshes.gd   # 헤드리스 EditorScript
  platform/ios/haptics/        # ObjC++ GDExtension (M1a)
  platform/android/            # Kotlin 플러그인 (M2·M4)
tools/ (레포 루트)
  content/  stagegen.js(game/js에서 복사, 이후 여기서만 고침)  build.mjs   # data/src → native/data/*.json
  export-content.mjs(M1-0 1회용)  bake-meshes.mjs  bake-audio.mjs  bake-ui.mjs  parity.mjs  shot-diff.mjs  shot.mjs(기존)
  godot/    install_godot_nix.sh  build_godot_src.sh  install_godot.sh(4.4.1)  UPGRADE.md
  mac/      ios_run.sh  SIGNING.md   # Mac 원커맨드 기기 실행 (4-3)
```

### 3-2 시뮬과 렌더의 분리, 고정 틱
- **`sim/`은 RefCounted(+ C++ ext 객체)로만 짠다.** Node, 씬, 렌더 API를 쓰지 않는다. `GameSim.step(dt)`를 **SIM_HZ = 120**으로 고정해서 돌린다. 120Hz 화면은 프레임당 1틱, 60Hz는 2틱이다. `max_physics_steps_per_frame=4`.
- **physics interpolation은 항상 켠다.** 이 설정은 프로젝트 시작 때 한 번만 읽히므로 주사율별로 켜고 끌 수 없고, 켜면 jitter_fix도 꺼진다([ProjectSettings.xml 4.7.2](https://github.com/godotengine/godot/blob/4.7.2-stable/doc/classes/ProjectSettings.xml)). ProMotion은 저전력 모드나 발열 때 60이나 가변으로 떨어지는데, 그러면 120 TPS와 위상이 어긋나 프레임마다 0틱이나 2틱이 되는 맥놀이가 생긴다. 그래서 보간이 필수다.
  - NPC: C++ Traffic이 이전·현재 상태를 보관하고, `_process`에서 `Engine.get_physics_interpolation_fraction()`으로 보간한 transform을 MultiMesh 버퍼에 직접 쓴다.
  - 플레이어·보스·투사체 노드: `_physics_process`에서 동기화해 엔진 보간을 받는다.
  - 카메라: 지금처럼 실시간 exp 스무딩을 유지한다(웹 updateCamera가 프레임레이트와 무관함을 확인 ✅). `camera_rig`는 `physics_interpolation_mode=OFF`로 두고 `_process`에서 보간된 타깃을 따라간다.
- 시간 배율(히트스톱 0, 슬로모 0.28/0.3, 일시정지 0)은 `sim dt = TICK × timeScale`로 직접 적용한다. **`Engine.time_scale`은 쓰지 않는다.** 카메라 스무딩, 플래시, 흔들림, UI는 실시간으로 돈다. 시계는 웹처럼 `time`(배율 적용)과 `real_time` 두 개를 유지한다.
- `step()`은 이벤트 배열(`[{type:"tirePop", …}]`)을 돌려준다. `game.gd` 한 곳에서 이것을 view, Fx, Audio, Haptics, UI로 나눠 보낸다. sim은 fx나 audio를 직접 부르지 않는다.
- **웹의 숨은 결합 3가지를 이식하면서 끊는다:**
  1. 차 치수를 메시가 아니라 `vehicle_kinds.json`에서 읽는다.
  2. buildVehicle의 seed 추첨과 갓길 장애물의 RNG 소비를 sim에서 똑같이 재현하고, 뷰는 spec만 받아 메시를 만든다.
  3. 보스 사망·피니시와 압정 판정이 sim의 pos/vel을 쓰게 한다(웹은 `-mesh.position.z`를 쓴다).
- **traffic 코어는 처음부터 C++ GDExtension(`native/ext/traffic`)이다.** 근거는 컨테이너 실측이다. 같은 알고리즘(187대: 버킷 구성, 정렬, leaderOf, IDM의 pow·sin)을 돌렸고 체크섬이 19990.779로 같았다:

  | 구현 | ms/tick |
  |---|---|
  | JS (Node) | 0.095 |
  | GDScript, 4.4.1 release 템플릿 | 3.05 |
  | GDScript, 4.4.1 에디터 헤드리스 | 3.89 (재측정 평균 4.15, p50 3.41) |
  | GDScript, 매 tick 정렬 제거(삽입 정렬 가정) | 2.36 — 그래도 예산 1.5ms 초과 |

  - 실제 `traffic.update` 전체는 Node에서 1-1(126+26대) 0.24~0.35ms, 90판(161+26대) 0.40~0.49ms/tick이다(2회 측정). GDScript로 옮기면 약 11~16ms/tick으로 추정되고, 예산의 7~10배다. 120Hz는 물론 60Hz도 불가능하다.
  - 이 Xeon(2.8GHz)과 A15의 단일 코어 성능은 같은 자릿수라서 컨테이너 측정값을 기기의 대리 지표로 쓴다. 벤치 파일(`core.mjs`, `jsbench.mjs`, `gd/tests/{bench,bench_nosort,viewsync}.gd`)은 지금 세션 scratchpad의 `review_bench/`에 있고, M1-0에서 `native/tests/bench/`로 옮긴다.
  - **C++ 범위:** Rng32, LaneEntity, NpcCar, Traffic(spawnJam, 버킷, leaderOf, gapAhead, laneBlocked, IDM, 차선 변경, stuck assist, honk/letIn/cheater, release, rageHorn), NPC MultiMesh 버퍼 쓰기(3-7). GDScript에는 `traffic_bridge.gd`로 설정 주입, 질의(leaderOf, laneBlocked), 이벤트만 노출한다.
  - **GDScript 판 traffic은 짜지 않는다.** 동등성 기준은 JS가 만든 골든 JSON이다.
  - boss, weapons, behaviors, player는 엔티티가 적어서 typed GDScript로 둔다. T0 perf 스위트로 GameSim 전체 ≤ 2ms(컨테이너)를 확인하고, 넘으면 그 핫패스만 ext로 옮긴다.
- 버킷 갱신 시점을 웹과 똑같이 둔다(player.update, requestLane, honk는 이전 프레임의 버킷을 쓴다). C++ 핫패스 처리:
  - `leaderOf`는 이진 탐색으로 바꾼다.
  - 버킷은 삽입 정렬로 유지한다.
  - `includes` 대신 `is_npc` 플래그를 쓴다.

### 3-3 결정적 RNG (JS 시드와 일치)
- `Rng32`(ext, C++): mulberry32를 `uint32_t`로 구현하고 GDScript에 노출한다(월드 소품 루프도 같은 클래스를 쓴다). GDScript 판(`& 0xFFFFFFFF` 마스킹 + imul)도 JS 스트림과 일치함을 확인했다 ✅(벤치 체크섬). GDScript int가 64비트 signed라서 마스킹이 필요했던 것이고, C++에서는 필요 없다.
- 시드:
  - traffic: `mulberry32(id·1000+7)`
  - 월드 소품: `mulberry32(id·7919+13)`
  - 차 변형: `seed=floor(rng·1e6)`, `variant=canon(seed % variants)`
- **spawnJam의 추첨 순서를 그대로 지킨다:** 벽 차로 → 차로 0~3 {pickWeighted, _makeCar 5회, gapOf} → 갓길 셔플 → 아이템 루프(아이템마다 순서대로: ① 문자열 아이템이면 위치 지터 `rng()` 1회(traffic.js:194, 객체 아이템 `{kind, at}`은 0회) ② `cheater`면 pickWeighted 1회 + `_makeCar` 5회 + `cheaterV` 1회(196-198) ③ 장애물이면 buildShoulderObstacle 소비(고장차 3, 콘 0, 낙하물 2+3nb)) → 잔챙이 {type, cool} → 반대편 26대 × 6.
- **계약의 원천은 이 목록이 아니라 골든 트레이스다**(Codex 리뷰 2026-10-13: 목록이 갓길 위치 지터·cheater 소비를 빠뜨렸던 것을 수정). `tools/export-content.mjs`가 JS 실행 중 `rng()` 호출마다 (호출 순번, 호출 지점 태그, 값)을 기록한 `native/tests/golden/rng_trace_stage{1,5,6}.json`을 만들고, C++ 포트는 같은 태그 순서로 호출하는지 T0에서 비교한다. 목록과 트레이스가 다르면 트레이스가 맞다.
- 골든 데이터는 spawn 레이아웃만 비교한다(런타임 추첨은 dt에 따라 달라진다). 1-1 기준값: 126대, 첫 차는 1차로 버스 s=200.4453, 고장차 109.681(len 7), 콘 147.518, 잔챙이 131.90/66.63, 다음 추첨값 0.3714370721 ✅.
- 웹의 `Math.random` 부분(보스 공격 선택, 도발, fx 등)은 `RandomNumberGenerator(--seed)`로 바꾼다. 네이티브 헤드리스 실행은 **seed로 완전히 재현된다.**

### 3-4 좌표계 (웹과 같은 오른손 좌표계, Y-up, −Z가 전방이라 1:1로 복사)
- `s` = 도로 진행 거리, `z = −s`, x는 좌우(−X가 왼쪽, 1차로 쪽), 노면 y=0. 단위는 m와 m/s.
- `laneX(i)=(i−1.5)·3.6`: 0차로 −5.4 … 3차로 +5.4, 갓길(4)은 9.0. 중앙분리대 −8.25. 반대편은 `−11.1−3.6j`(rotation.y=π). ✅
- 엔티티 s는 차 중심이고 범퍼는 ±len/2. 점유 판정은 `|x−laneX| < w/2+1.2`.
- 함정:
  - 웹의 Euler 순서는 XYZ이고 Godot 기본은 YXZ다. 여러 축을 함께 쓰는 노드(보스 피니시, 잔해)에는 `rotation_order=EULER_ORDER_XYZ`를 준다.
  - 앞면 판정이 Three는 CCW, Godot ArrayMesh는 CW다. 임포터에서 b와 c를 바꾼다.
  - 미사일 모델은 +Z를 향한다. `look_at(…, use_model_front=true)`를 쓴다.
  - 정점 색은 linear다(`vertex_color_is_srgb=false`).
  - PlaneMesh는 +Y, QuadMesh는 +Z를 향한다.
  - JSON 숫자는 전부 float이고, frontRow 키는 문자열이다.
  - JS의 `%`는 C처럼 피제수 부호를 따른다. 그대로 재현하려면 C++는 `%`/`std::fmod`, GDScript는 정수 `%`/`fmod`를 쓴다. `fposmod`는 결과가 달라지므로 JS 코드가 직접 양수 보정을 한 곳에만 쓴다(8절).
  - 스와이프 기준은 px가 아니라 pt로 환산한다.

### 3-4b 도로 모델 `RoadGraph` (N6 — 사용자 피드백: "직선 고속도로만 있다")
가설: ❓ 판마다 같아 보이는 이유의 절반은 직선 도로다. 지형을 판 축으로 쓰되, **sim은 (s, lane) 공간 그대로 두고 렌더만 곡선에 매핑**하면 지형 추가 비용이 구간 타입 1개 = 메시 생성기 1개로 끝난다.
- 구간 타입: `straight`, `curve(R, 방향)`, `merge_ramp`(진입 합류 램프 + 테이퍼), `lane_drop`(공사·차로 감소), `tunnel`, `toll_plaza`(펼침부: 4차로 → 부스 N개, 하이패스/일반 분리, 부스 앞 백색 실선), `jc_split`, `bridge`.
- API: `world(s, lateral) → (pos, tangent)`, `lanesAt(s) → [lane id, 폭, 종류]`(차로 수가 s에 따라 바뀜), `lineRuleAt(s, lane, side)`(점선/실선 = 차로변경 허용 여부, 단속 판정에 사용).
- sim 영향: traffic C++ 코어는 `lanesAt(s)`만 알면 된다(차로 소멸 지점 = 강제 합류, 지퍼 교대 규칙은 lane_drop/merge_ramp 끝에서만 활성). 카메라는 `tangent`를 따라 요(yaw)만 부드럽게 돈다.
- 콘텐츠: 스테이지 JSON에 `road: [{type, len, params}]` 추가. 기존 100판은 전부 `[{type:'straight'}]`로 export되어 동작이 같다.
- 적용 순서: M1 직선(구조만) → M2 1-8 `merge_ramp` + 지퍼 교대(V04_SPEC '파블로프의 악셀', VILLAIN_CATALOG 후보 T2) → M3 `toll_plaza`(후보 T1 요금소 앞 칼치기러, CH3) · `lane_drop` · `tunnel`(P1 패러디) · `curve`.

### 3-5 모듈 매핑 (JS → Godot)
| JS (LOC) | Godot | 방식 |
|---|---|---|
| config.js (304) | `core/cfg.gd` + `data/src/config.json` | 상수는 이식, 표는 M1-0에 1회 export |
| villain_catalog.json + stagegen.js (318) | `data/src/villain_catalog.json` + `tools/content/stagegen.js` → `data/stages.json` | **이식하지 않는다**(lookbehind 정규식 등). 빌드 도구로 소유권을 넘긴다 |
| traffic.js (772) | `ext/traffic/`(C++) + `sim/traffic_bridge.gd` + `view/npc_multimesh.gd` | **C++로 이식** (85%가 sim) |
| player.js (234) · weapons.js (177) · rewards.js (61) | `sim/player.gd` · `sim/weapons.gd` · `sim/rewards.gd` | 이식 |
| boss.js (859) · behaviors/index.js (325) | `sim/boss_manager.gd`, `villain.gd`, `sim/behaviors/*.gd` | 이식 (sim이 pos 소유) |
| shoulder.js (85) | `sim/shoulder_obstacle.gd`(spec+RNG) + bake 메시 | RNG는 이식, 메시는 bake |
| main.js (1366) | `view/game.gd`(상태 머신), `camera_rig.gd`, `sim/autopilot.gd`, SaveGame | 로직 45%는 이식, 연출은 재구성 |
| input.js (78) | `input/input_buffer.gd` + InputMap | 이식 |
| world.js (231) | `view/world.gd` (Environment, 소품 RNG 루프 동일) | 이식 |
| vehicles.js (4072) · scenery.js (2299) | `assets/**/*.res` + `vehicle_factory.gd` + `text_panel.gd` + `shaders/*` | **지오메트리는 bake**, 텍스트 판은 런타임 생성, 셰이더는 손 이식 (3-7) |
| fx.js (1187) | `fx/fx.gd` (GPUParticles3D 레시피) + `shaders/self_lit` | 재작성 (레시피 수치는 그대로) |
| audio.js (1167) | bake한 OGG/WAV + `audio/audio.gd` | **bake** (3-8) |
| ui.js (2697) + style.css (2270) | `ui/*.tscn` + `ui_theme.tres` + SVG 래스터 | 재작성 (가장 큰 항목) |

- **이식 규칙: 인라인 상수는 data 키로 뽑는다.** 예: traffic.js의 IDM·차로 유형별 `T`, `s0`, `aMax` → `config.json`의 `traffic.idm.*`. main.js 인라인 대사(32곳 이상)와 ui.js 처분 카드도 `lines.json`/`cards.json`으로 뽑는다. 튜닝할 곳은 `data/src` 한 군데뿐이어야 한다.

### 3-6 데이터 흐름과 콘텐츠 파이프라인
```
[M1-0, 1회] game/js/{config.js, data/villain_catalog.json, main.js 대사, ui.js 카드} ─ tools/export-content.mjs ─▶ native/data/src/*.json
native/data/src/*.json + tools/content/stagegen.js ─ tools/content/build.mjs ─▶ native/data/*.json(생성물) ─▶ DB ─▶ GameSim
game/js/{vehicles.js, scenery.js} ─ tools/bake-meshes.mjs (Node+canvas stub, 정점색 지오메트리만) ─▶ build/bake/*.json+bin
                                   ─ godot --headless -s res://tools/import_meshes.gd ─▶ native/assets/**/*.res
텍스트 판 ─ 판 모양은 위 bake, 글자는 Godot에서 생성(3-7) ─▶ ImageTexture(런타임) / assets/textures/stickers.png(빌드 시)
셰이더 ─ game/js의 GLSL을 손으로 이식 ─▶ native/shaders/*.gdshader (T2 웹/Godot 샷 쌍 비교)
game/js/audio.js ─ tools/bake-audio.mjs (Chromium OfflineAudioContext, compressor 앞 탭) ─▶ native/assets/audio + data/sfx.json, music.json
game/js/ui.js + css ─ tools/bake-ui.mjs (Chromium @3x, @font-face 번들 폰트) ─▶ native/assets/ui/*.png (9-slice, 텍스트 SVG), ui/svg/*.svg
런타임: 터치 → InputBuffer → GameSim.step(1/120) → events → game.gd → view 동기화 / Fx / Audio / Haptics / UI(값이 바뀔 때만)
```
- **진실 원천: M1-0에서 한 번만 export하고, 그때부터 원천은 `native/data/src/*.json`이다.**
  - 그 커밋에 `web-frozen` 태그를 단다. 웹은 이 태그에서 동작 레퍼런스이자 T4 오라클로 고정된다. 이후 `game/js`는 고치지 않는다(bake 전용 옵션은 태그 전에 넣는다, 3-8).
  - stagegen.js는 `tools/content/`로 복사해 빌드 도구로 소유권을 넘긴다. 웹 쪽 원본은 동결 상태로 둔다. M3의 패밀리 스키마 확장도 여기서 한다.
  - `native/data/*.json`은 생성물이지만 커밋한다. `node tools/content/build.mjs --check`는 차이가 있으면 실패한다.
- export 대상 표(스크래치 검증 스크립트 `stages.mjs`, `dims.mjs`, `golden.mjs`를 재사용):
  - `stages.json`: 100판. `schema_version`을 붙이고, frontRow는 배열로, zigCenter는 null로 정규화한다.
  - `chapters.json`, `album.json`, `cards.json`(처분 카드 표, ui.js에서 수동 추출).
  - `config.json`:
    - tune, `traffic.idm.*`(인라인 상수 추출)
    - npc: kinds의 가중치, 색 순서(RNG에 영향)
    - sky: 7개 + STAGE_SKY (+ Godot 광원 환산값, 2절)
    - shop, shop_default
    - lines: `*_LINES`, MINI_TYPES. main.js 인라인 대사는 수동으로 추출한다.
    - approach / jamShape / sig 원표
  - `haptics.json`(2절 표), `vehicle_kinds.json`: variants, canon, 변형별 [L,W,H], 바퀴, 피벗. **dev stub의 치수는 틀리므로 쓰지 않는다.**
  - `rewards.json`, `text_content.json`(배너, 광고, 지명 EN, 스티커 문구).
  - 테스트 골든: `tests/golden/spawn_{1,5,6}.json`, `rng_1007.json`(처음 1000개 추첨값).
- **세이브:** `lane1.progress.v1`(ver 3)과 같은 구조를 `user://progress.json`에 쓴다.
  - 쓰기: `progress.json.tmp`에 쓰고 `DirAccess.rename`으로 교체한다. 직전본은 `progress.json.bak` 1개로 보관하고, 파싱이 실패하면 .bak로 복구한다. 웹은 localStorage라 이 문제가 없었지만, 네이티브는 쓰는 도중 강제 종료되면 파일이 깨진다.
  - 로드: `ver` 필드로 마이그레이션한다. T0에 v1·v2·v3 샘플 세이브(`tests/saves/`) 로드 테스트를 둔다.
  - Flutter 셸(WKWebView localStorage)의 진행도는 마이그레이션하지 않는다(미출시).
  - 블박 사진은 `user://album/<id>.jpg`.

### 3-7 복셀 메시 파이프라인 (지오메트리는 bake, 텍스트·셰이더는 따로)
- **자산을 세 부류로 나눈다.** "다시 만들지 않고 bake"는 (1)에만 해당한다.

| 부류 | 대상 | 처리 |
|---|---|---|
| (1) 정점색 지오메트리 | 차량·소품·도로·투사체·FX 소품의 모양, 판 모양(갠트리·VMS·배너·포털 프레임) | **bake** (아래) |
| (2) 텍스트를 가진 판 | scenery.js `makeCanvas`/`CanvasTexture` 13곳 + vehicles.js 3곳 ✅: 갠트리 표지(`stage.signs`), VMS 3개(`앞쪽 정체 ${displayKm}km 원인: ${cause}` 등, `world.js:187-203`), 배너, 터널 포털 이름, 아파트 '○동' 번호, 뒷유리 스티커('초보운전', '1차로 내꺼') | **Godot에서 생성.** 판마다 문자열이 달라 한 번 bake하고 끝낼 수 없다. 아래 참고 |
| (3) 셰이더 | `scenery.sky`, `scenery.tunnelCtl`, `scenery.zipper`(ShaderMaterial 3개 ✅), VMS LED, `fx.js` onBeforeCompile `uSelfLit`(selfLit), 해방 파도 | **손으로 이식**(GLSL → Godot shading language). 셰이더마다 웹 Playwright 샷과 Godot 샷을 T2에서 나란히 비교 |

- **(1) bake:** `bake-meshes.mjs`는 수정하지 않은 vehicles.js/scenery.js를 Node에서 호출해 다음 조합을 순회한다. canvas stub은 텍스처를 비워 두고, 판 모양만 남긴다.
  - KINDS × variant × detailed, PROJ 16종, FX_PROPS
  - 히어로 차량의 파손 L1~4 × focus, 오토바이 라이더 포즈 12종
  - 소품 kind × variant × 낮/밤, 도로 세그먼트 변형
  - 덤프 내용: 파트별 삼각형(pos, normal, linear color, 도색 마스크, 램프 마스크), 피벗(바퀴, 운전자, cannon, muzzle 등), userData, 텍스트 판의 UV 사각형.
  - `import_meshes.gd`(헤드리스): 평면 단위로 정점을 용접해 indexed로 만들고(용량 약 −33%), 와인딩을 뒤집고, 오프라인 정점 AO를 굽는다 ❓. 결과는 ArrayMesh `.res`와 `VehicleTemplate.tres`(파트 메시, 피벗, 치수)다.
- **(2) 텍스트 판:**
  - **판마다 다른 문자열**(갠트리, VMS, 배너, 포털 이름): 스테이지를 로드할 때(스테이지 카드 뒤) `SubViewport`(UPDATE_ONCE) + Label을 1회 렌더하고 `ImageTexture`로 굳혀 판 재질에 넣는다. 폰트는 번들 폰트(3-8)다. VMS는 이 텍스처를 `vms_led` 셰이더가 도트 매트릭스로 샘플링한다.
  - **고정 문자열**(스티커, '○동' 숫자 0~9와 '동'): 빌드 때 Godot(Xvfb)으로 아틀라스 PNG를 굽고 UV로 고른다.
  - Chromium으로 굽는 대안은 쓰지 않는다. 컨테이너에는 한글 폰트가 없어서(fc-list에 CJK 없음 ✅) 기본 폰트로 구우면 두부 글자가 나오기 때문이다. bake-ui처럼 Chromium을 써야 하는 곳은 @fontsource 폰트를 `@font-face`로 직접 로드한다.
- **NPC 도색은 런타임 tint로 한다**(MultiMesh `INSTANCE_CUSTOM`). 색마다 bake하지 않는다. 검증: 15색 × 8종에서 bake 결과와 tint 결과를 비교하고, 어긋나면 색별 bake로 물러난다 ❓.
- **드로우 경로: M1부터 MultiMesh가 기본이다.**
  - 이유: 1-1만 해도 126+26대이고, 100판 평균 140.8대, 최대 161대다. 그림자 2 split 패스가 캐스터마다 draw를 더한다. 따로 놓인 MeshInstance3D를 Godot이 자동으로 합쳐 준다고 가정하지 않는다. 노드별 뷰 동기화는 헤드리스에서 이미 0.67ms(p99 2.3ms)로 예산 1.0ms에 가깝다(`viewsync.gd`).
  - NPC: **(kind, variant, part)별 MultiMesh**. 파트는 bone 없는 2개(body, wheels)다. 도색 색, 램프 비트(브레이크·깜빡이·비상등·상향등), 차체 pitch는 `INSTANCE_CUSTOM`에 넣고, 버퍼는 C++ Traffic이 직접 채운다. 램프는 body의 램프 마스크 정점을 `lamp` 셰이더가 HDR emission으로 켠다. 깜빡이 후광은 빌보드 쿼드 MultiMesh다.
  - 히어로 차량(플레이어, 원흉, 보스)은 수가 적고 파손 단계·피니시 연출이 있으므로 MeshInstance3D(`hero_vehicle_view.gd`, surface ≤ 3, 램프는 instance uniform)로 둔다.
  - 소품은 200m 청크마다 MultiMesh + visibility_range.
  - **draw call은 렌더러와 무관하게 결정적이므로 컨테이너에서 잰다.** T2(lavapipe)가 페이즈별로 `Performance.get_monitor(RENDER_TOTAL_DRAW_CALLS_IN_FRAME)`과 `RENDER_TOTAL_PRIMITIVES_IN_FRAME`을 덤프하고, 보이는 draw > 250 또는 그림자 포함 > 400이면 실패한다.
- 검증: 삼각형 수(sedan 1188 / detailed 1520), 치수, 차량 갤러리 스크린샷(`game/dev/vehicles.html`과 같은 각도).

### 3-8 UI · 오디오 · 입력
- **UI:**
  - ui.js의 API 표면을 그대로 둔다(`show_stage_card` → await, `show_fail` → `"retry"|"menu"`, `set_hud`…). 화면은 Control 씬으로 만든다.
  - **폰트:** Black Han Sans/Jua(npm @fontsource) + Noto Sans KR 폴백. 외곽선은 LabelSettings 프리셋 O2/O3/O4/O6.
    - 라이선스는 OFL-1.1이고 Black Han Sans에는 Reserved Font Name이 없다 ✅(병합 허용). OFL 원문(`assets/fonts/OFL.txt`)과 설정 › 크레딧 화면을 넣는다.
    - fontsource는 한글을 번호 붙은 woff 조각(약 89개)으로 나눠 배포한다. fontTools로 병합한 뒤 글리프 수와 cmap 커버리지를 테스트한다(KS X 1001 2350자 + 데이터에 실제로 쓰인 모든 글자).
  - **한글 줄바꿈:** style.css는 `word-break: keep-all`을 18곳(카드 제목, 결과 원흉명, 처분 사유 등)에서 쓴다. Godot autowrap에는 keep-all이 없고, ICU 기본 규칙은 한글 음절 사이 줄바꿈을 허용한다. 그래서 '1차선 참교 / 육'처럼 끊길 수 있다 ❓(실측 필요). T2에 한글 줄바꿈 샷 테스트를 넣고, 깨지면 문자열 전처리로 단어 내부 음절 사이에 U+2060(WORD JOINER)을 넣는다. 그래도 안 되는 곳은 데이터에 명시적 `\n`을 넣는다.
  - 광택 버튼과 표지판 판은 CSS를 Chromium에서 @3x 9-slice PNG로 굽는다. **ui.js의 SVG 48개 중 `<text>`가 있는 5개와 `currentColor`를 쓰는 1개는 Chromium @3x PNG로 굽는다**(ThorVG의 `Image.load_svg_from_string`은 글꼴과 CSS 색을 잃을 수 있다). 나머지(아이콘 43종 포함)는 런타임 SVG 래스터다.
  - 애니메이션은 Tween/AnimationPlayer로 옮기되, M1 화면에 쓰는 것만 한다. 말풍선은 `Camera3D.unproject_position`으로 위치를 잡는다. safe area는 `DisplayServer.get_display_safe_area()`로 처리한다.
- **오디오:**
  - bake 대상: SFX 31종 × 테이크 3~5개, 노래 4곡(루프 포인트 포함), 응원 경적, 앰비언스, 엔진 RPM 루프 약 6개.
  - **탭 위치:** 웹 체인은 sfx/amb/music → compressor → master → WaveShaper 클리퍼다. 체인 뒤에서 뽑으면 SFX마다 압축과 클리핑이 들어간 채로 구워져서, Godot Master의 Compressor·Limiter와 이중으로 걸려 펌핑이 생긴다. 그래서 `bake-audio.mjs`는 `audio.init({context})`로 OfflineAudioContext를 바인딩하고 **각 버스를 compressor 앞에서 탭한다.** 기존 `noLimiter` 옵션(`S.noClip`)은 클리퍼만 빼고 compressor는 남기므로 이것만으로는 부족하다. 그래서 audio.js에 bake 전용 옵션(`preComp`: 버스를 comp 대신 destination에 연결, 기본 동작 불변)을 하나 추가하고 `web-frozen` 태그 전에 넣는다(8절).
  - 버스 구성은 SFX/Ambience/Music→Duck→Master이고, Master에 Compressor(−10dB, 6:1, 3/220ms)와 HardLimiter를 건다.
  - 음악: 마디 단위 전환은 `AudioStreamInteractive`, 스템 동기는 `AudioStreamSynchronized`를 쓴다(직접 구현하지 않는다). 해방 BGM은 응원 박자 그리드(130BPM)에 맞춰 들어간다.
  - 엔진음: 웹은 `setEngine`이 매 프레임 `setTargetAtTime`으로 연속 합성한다. 네이티브는 RPM 루프 약 6개 사이를 크로스페이드하고 `pitch_scale`로 보정한다. 웹과 나란히 녹음해 비교한다.
  - `sfx.json`의 max/gap/pri로 보이스를 받아들일지 정하고, 전체 상한은 40이다.
- **입력:**
  - `InputBuffer`는 웹의 consume/peek/endFrame/tap/isDown 의미를 그대로 따른다. 엣지는 **sim 틱이 소비할 때까지 래치**한다.
  - 스와이프: 34pt(|dx| > 1.2|dy|)면 차선 이동, 위로 60pt(|dy| > 1.5|dx|)면 분노. ✅
  - TouchScreenButton으로 멀티터치를 처리한다(발사를 누른 채 스와이프). 포커스를 잃으면 모든 입력을 해제한다. 테스트용 `InputBuffer.inject()`를 둔다.

---

## 4. 테스트 루프

### 4-1 컨테이너 설치
```bash
bash tools/godot/install_godot_nix.sh   # M1-0 게이트 (a): Nix godot 4.7.2 + export-templates-bin + mesa(lavapipe) + vulkan-loader 같은 클로저
                                        #   템플릿 디렉터리 이름(4.7.2.stable) == 에디터 VERSION_FULL_CONFIG 검사 포함
bash tools/godot/build_godot_src.sh     # (a) 실패 시 (b): 4.7.2-stable 태그를 scons로 소스 빌드, 템플릿은 Nix -bin
godot --version                         # 4.7.2.stable.* 이어야 조명·포스트·T2 작업 가능
cmake -S native/ext -B build/ext && cmake --build build/ext -j4   # godot-cpp(엔진 태그 고정) + traffic + (iOS 모듈은 Mac에서만) → Linux .so
bash tools/godot/install_godot.sh       # M0 검증본: Ubuntu pool 4.4.1 + soname 10개, 28초, 멱등. sim·T0·T1 전용
```

### 4-2 테스트 단계 (모두 exit 0이면 통과)
| 단계 | 명령 | 내용 | 시간 |
|---|---|---|---|
| T0 unit | `godot --headless --path native -s res://tests/run_tests.gd -- --suite=unit` | Rng32가 JS 스트림과 일치, laneX, stages.json 로드, **spawn 골든 일치**, IDM 한 스텝, 이벤트 계약(햅틱 맵 이벤트 누락 0 포함), 세이브 v1·v2·v3 로드·마이그레이션, `build.mjs --check` | < 10s |
| T0 perf | `… -- --suite=perf` | 90판 spawn 후 `traffic.step(1/120)` 3600회: **traffic p95 ≤ 0.5ms**(컨테이너 기준). 1-1 GameSim 전체 3600틱: **≤ 2ms/tick**. 결과를 `build/perf.json`에 남긴다 | 실측 후 기입 |
| T1 autoplay | `… -- --suite=autoplay --stages=1 --seeds=20 --jobs=4 --report=build/native.jsonl` | **SceneTree와 뷰 없이 GameSim(RefCounted)만** 오토파일럿으로 result까지 돌린다. seed를 프로세스 4개로 나눠 병렬 실행. 스크립트 에러 0. playtest.mjs와 같은 JSON 줄 출력: `{stage, phases, bumps, supers, playerHp, fails, done, errors}` | 1-1 한 판 = sim 43~53s = 5~6.4k틱. 목표 seed당 ≤ 5s, C++ traffic 이후 실측 |
| T2 화면 | `xvfb-run -a -s "-screen 0 1280x1024x24" godot --path native --rendering-method mobile --audio-driver Dummy -- --shots=m1 --ff-to=<phase> --out=build/shots` 후 `node tools/shot-diff.mjs --tol=0.5% build/shots native/tests/shots/baseline` | 4.7.2 Mobile 렌더러(lavapipe). `--ff-to`는 한 프레임 안에서 sim 틱을 루프로 돌려 해당 페이즈까지 빨리 감고, 뷰를 동기화한 뒤 N프레임만 렌더한다. 파티클은 고정 시드 + `fixed_fps`. 빈 화면 가드(lum sd ≤ 0.05면 실패). 페이즈별 draw call 덤프(3-7 합격선). 웹 동일 카메라 샷 쌍 ΔE 리포트(`tools/shot.mjs`). 셰이더별 웹/Godot 쌍. 한글 줄바꿈 샷. 베이스라인 diff는 허용 오차 픽셀 0.5%, 넘으면 사람이 눈으로 확인 | 실측 후 기입 (렌더 170~300ms/frame) |
| T3 export | `godot --headless --path native --export-release Linux build/linux/lane1.x86_64` | export 파이프라인 스모크 (Linux 템플릿은 Nix -bin) | < 1분 |
| T4 웹 대비 | `git worktree add build/web-frozen web-frozen` → `npx http-server build/web-frozen -p 8090 -c-1 -s &` → `node tools/playtest.mjs --stages 1 --ff 6 > build/web.jsonl` → `node tools/parity.mjs build/web.jsonl build/native.jsonl` | **동등성 빌드(`rules.n_feedback=false`)로만 돌린다.** 페이즈 시간(sim 시간 기준) 중앙값 ±15%, 완주율 100%. 1:1이 아닌 부분은 웹의 Math.random 탓이라 통계로만 비교한다 | 실측 후 기입 |
- 프레임 시퀀스: `--write-movie build/mov/frame.png --fixed-fps 30 --quit-after N` (M0에서 동작 ✅).
- lavapipe는 170~300ms/frame이라 **GPU 성능 수치로는 의미가 없다.** 화면 회귀, 셰이더 컴파일, draw call 수(결정적) 확인용이다. CPU 쪽 sim 성능은 T0 perf가 대리 지표다(3-2).

### 4-3 Mac/폰에서만 되는 것과 기기 루프
- iOS export·서명·Xcode 빌드, iOS용 ext/모듈 xcframework 빌드(Xcode 툴체인 필요, xcframework export 버그 이력 [#90168](https://github.com/godotengine/godot/issues/90168)). Android APK/AAB도 해당한다(컨테이너에서는 maven.google.com → dl.google.com 403으로 Gradle이 막힘 ✅. Nix 템플릿 + apt apksigner 경로는 ❓).
- Metal과 Adreno/Mali 실제 셰이딩, 120Hz와 프레임 시간, touch-to-photon, 햅틱 체감, 오디오 지연, 발열·배터리, 메모리, 노치·다이내믹 아일랜드의 safe area, 실제 앱 크기.
- iOS 시뮬레이터는 Compatibility 렌더러만 돈다([iOS export](https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_ios.html)). 그래서 **화질 확인은 실기기에서만 한다.**
- **기기 루프 = `tools/mac/ios_run.sh` 명령 1개 (M1-0 산출물):**
  1. `git pull`
  2. `native/ext`와 `native/platform/ios`를 cmake(또는 scons)로 iOS xcframework로 빌드
  3. `godot --headless --path native --export-debug "iOS" build/ios/lane1.xcodeproj`
  4. `xcodebuild -project build/ios/lane1.xcodeproj -scheme lane1 -destination 'generic/platform=iOS' -allowProvisioningUpdates build`
  5. `xcrun devicectl device install app --device <UDID> <.app>` 후 `xcrun devicectl device process launch`
  - 처음 한 번만 하는 서명 체크리스트는 `tools/mac/SIGNING.md`에 둔다: Team ID, 자동 서명, 기기 개발자 모드, 신뢰.
  - **합격 기준: Mac에서 명령 1개로 10분 안에 기기에서 실행된다.**
- **다시 빌드하지 않고 튜닝한다:** 조명·포스트·햅틱 세기는 `data/*.json`에서 런타임에 읽는다. 개발 빌드에는 숨김 디버그 패널(세 손가락 길게 누르기)을 둬서 기기에서 값을 바꾸고, 결과를 JSON으로 내보내 `data/src`에 반영한다.

---

## 5. 마일스톤

### M0 spike — ✅ 완료 (근거)
- 설치 ✅: 4.4.1을 Ubuntu pool에서 받아 soname 10개를 옆에 두고 LD_LIBRARY_PATH로 띄운다. 28초, 멱등. 4.6.3은 glibc 2.43이 필요해 ❌.
- 헤드리스 ✅: `-s res://tests/test_sim.gd`로 9 PASS, 약 1.5s. 실패하면 exit 3이 그대로 전달된다. 더미 렌더러에서 6.9ms/frame.
- 렌더 ✅: Xvfb에서 Compatibility(llvmpipe, 178ms), **Mobile(lavapipe Vulkan, 170~207ms)**, Forward+(290ms, SSAO 확인) 모두 PNG 저장. 복셀 차 20대, 그림자, 포그를 눈으로 확인했다.
- export: 템플릿이 없으면 ❌. apt의 Linux 템플릿으로는 ✅(81MB 바이너리, Mobile 렌더 확인). **iOS/Android 템플릿은 apt로는 받을 수 없다**(Nix -bin 경로는 M1-0).
- 리뷰 벤치 ✅: GDScript traffic 핫루프 32~41배 느림 → traffic 코어 C++ 결정(3-2).
- 산출물은 현재 세션 scratchpad의 `godot-spike/`, `review_bench/`에 있다. M1-0에서 `native/`와 `tools/godot/`로 옮긴다.

### M1 — 1-1 완전 플레이 + 품질 패스 (M1-0 → M1a → M1b → M1c → M1d)
M1은 게임의 대부분이므로 다섯 단계로 나누고, **사용자의 화질 판정을 M1a에 먼저 받는다.** 추정치는 ❓(M1a 결과로 다시 잡는다). 합계 약 4~5주 ❓.

#### M1-0 기반 (목표 1~2일 ❓)
- **선행 조건:** 열린 질문 1(보유 기기와 Mac) 답.
- 범위:
  - 레포 골격(`native/`, run_tests 러너, `tools/native-check.sh`), M0·리뷰 벤치 이전.
  - **버전 게이트(1-2)** 4.7.2 + godot-cpp 고정, `ext/traffic` 골격이 Linux .so로 빌드·로드됨.
  - `export-content.mjs` 1회 실행 → `native/data/src`, `tools/content/`, 골든 생성. audio.js `preComp` 옵션 추가. **`web-frozen` 태그.**
  - `tools/mac/ios_run.sh` + `SIGNING.md`(사용자가 Mac에서 1회 실행).
- 합격: 4.7.2 Xvfb Mobile 샷이 빈 화면 가드 통과, 헤드리스에서 ext .so 로드, **빈 씬이 사용자 iPhone에서 `ios_run.sh` 1회로 10분 안에 뜸.**

#### M1a 기기 룩앤필 (목표 3~5일) — 조기 판정
- 범위:
  - core(cfg, DB) + C++ traffic: Rng32, spawnJam(장애물 RNG 포함), 버킷, IDM, 차선 변경, stuck assist, honk/letIn, NPC MultiMesh.
  - bake: 도로(day), 텍스트 없는 소품, CCTV, player, NPC 8종, 고장차·콘.
  - player: 정체 구간 주행, 차선 변경(터치 스와이프), 경적.
  - world(day 프리셋) + camera_rig(jam 페이즈, real dt 스무딩).
  - 조명·포스트(2절): Linear 톤맵, hemi-sky ambient, PSSM 그림자, 램프 HDR + glow('빨간 바다'), MSAA 4x, 디밴딩, fog. 디버그 패널.
  - **iOS 햅틱 모듈**(Core Haptics + thermalState 로그). 차선 변경·경적·추돌 햅틱.
  - 오디오: 경적 SFX 1개(bake).
- 합격:
  - T0 spawn_1 골든 + rng 1000개 일치. T0 perf: traffic 90판 p95 ≤ 0.5ms.
  - T2: jam 샷(4.7.2), draw ≤ 250 / ≤ 400, 웹 동일 카메라 ΔE 리포트.
  - 기기: 정체 구간에서 120Hz p95 ≤ 8.3ms, thermalState 로그가 나옴.
  - **사용자 판정: 웹(Flutter 셸 또는 Safari)과 나란히 놓고 "조명·120Hz·햅틱이 웹보다 낫다".** 결과는 FEEDBACK_LOG에 기록한다.
- **중단·분기 기준:**
  - 판정이 부정적이면 M1b로 가지 않는다. 디버그 패널로 렌더 설정(톤매퍼 A/B, 반구광 방식, 그림자, glow)을 다시 맞추고(최대 2일) 재판정한다. 그래도 부정적이면 1-1의 엔진 가설을 다시 연다(같은 jam 씬으로 비교).
  - 120Hz를 못 지키면 sim/뷰/렌더 중 어디가 병목인지 프로파일링한다. 렌더라면 그림자 해상도, MSAA, render scale 순으로 낮추고, 그래도 안 되면 2절 규칙대로 60 고정으로 하고 기록한다.

#### M1b 시뮬 동등성 (목표 7~10일 ❓)
- 범위:
  - traffic 나머지: cheater, release, rageHorn.
  - player: jam/boss/cruise 전체, 추돌, 박살, 점프.
  - boss: occupy 모듈, highbeam/컵 투척/경적파/lunge, 타이어 펑크, 로켓 피니시. weapons: 압정, 미사일. 잔챙이 2명.
  - game 상태 머신: intro → jam → boss → kill → release → cruise → result, 견인·재도전. HP, 분노, 점수, 미션 3개, 보상, 세이브(3-6). autopilot.
  - bake: villainSedan, 콘·압정·미사일·컵·경고 마커. camera_rig 전 페이즈(FOV 이징, 흔들림).
  - FX: 폭발, 스파크, 연기, 잔해, 컨페티, 충격파, 스피드라인, 해방 파도. 시계 두 개. 셰이더 손 이식(3-7 (3)), 히치 방지(2절: 셰이더 베이커, 예열, 블박 비동기 캡처).
  - 햅틱 맵 전체(2절 표).
- 합격:
  - T0: spawn_1/5/6 골든과 rng 1000개가 완전히 일치, 세이브 마이그레이션, 이벤트 계약.
  - T0 perf: GameSim ≤ 2ms/tick. T1: 1-1 20 seed 완주율 100%, 에러 0(시간 실측 기입).
  - **T4: `rules.n_feedback=false` 동등성 빌드가 `web-frozen` 대비 페이즈 시간 ±15%.**
  - 기기: 첫 kill 구간 최대 프레임 ≤ 16.7ms.
- **웹 오라클의 알려진 버그 → 네이티브는 고쳐서 구현(T4에서 해당 경로 제외):** (Codex 리뷰 2026-10-13, 웹은 동결이라 수정하지 않음)
  - R1 재도전 스냅샷은 `phaseIdx`만이 아니라 **페이즈가 적용된 보스 상태 전체**(공격표, 이동 상태 stopped/slow/zig, `intervalMul`, 위치)를 저장·복원한다. 웹은 `phaseIdx`만 복원해서 페이즈 전환 뒤 대파하면 초기 공격·이동으로 돌아간다(main.js:712). 테스트: 페이즈 2에서 대파 → 재도전 직후 공격표·이동이 페이즈 2와 같음.
  - R2 갇힘 보조(rubber band·4초 강제 개방·2회 자동 견인)는 `phase=='jam'`이 아니라 **`jamLike`(정체 + 보스 발견 후 정면 잠금 전)** 동안 돈다. 웹은 원흉 35m 안에 들어오면 꺼져서, 갓길 고장차 + 옆 차로 틈 없음이면 소프트락 가능(traffic.js:342). 테스트: 발견 후 고장차 앞 정지 상태에서 4초 안에 탈출.
- 중단 기준: GameSim > 2ms면 해당 GDScript 핫패스를 ext로 옮긴 뒤 진행한다. T4가 15%를 넘으면 수치를 맞추지 말고 페이즈별 이벤트 로그(웹 playtest와 네이티브)를 diff해서 이식 버그부터 찾는다.

#### M1c UI · 오디오 · 텍스트 · 결과 (목표 7~10일 ❓)
- 범위:
  - UI 1차: HUD(범퍼 HP, 분노, 속도계, 진행바, 거리, 보스바+타이어, 배너, 말풍선, 팝, 토스트), 터치 컨트롤, 스테이지 카드, 결과(간소화), 실패 카드, 1-1만 있는 타이틀. 폰트 병합·OFL·크레딧, 한글 줄바꿈.
  - 텍스트 판: 갠트리, VMS(LED 셰이더), 배너, 스티커 아틀라스(3-7 (2)).
  - 오디오 bake 전체(1-1에 쓰는 SFX, 노래 4곡, 앰비언스, 엔진 RPM 루프)와 버스.
  - 최종 품질 패스: 2절의 조명, 포스트, 120Hz, 입력, 햅틱, 오디오, 발열을 기기에서 튜닝.
- 합격:
  - T2: 페이즈 6개 × 샷 베이스라인 승인(웹 대비 비교 샷 포함), 한글 줄바꿈 샷, 텍스트 판 샷.
  - 기기(iPhone 13 Pro 또는 사용자 기준기): 2절 표의 프레임·입력·발열·메모리 목표 충족. 60Hz 기기는 60 고정.
  - **사용자 판정: 1-1 전체로 "웹보다 확실히 낫다"** (그림자, 블룸, 손맛, 햅틱). 결과는 FEEDBACK_LOG에 기록한다.
- 중단 기준: UI가 10일을 넘으면 HUD와 카드만 남기고 타이틀·결과 디테일은 M2로 넘긴다.

#### M1d 웹 피드백 규칙 N1~N5 (목표 3~5일 ❓)
- **기능 플래그 `rules.n_feedback`(기본 true)로 넣는다(웹은 고치지 않음).** T4는 항상 플래그를 끈 동등성 빌드로 돌리므로, 1-1이 웹보다 나빠졌을 때 이식 버그인지 재설계인지 가를 수 있다.
  - N1: 진행바와 거리 숫자는 같은 값 하나에서 나온다(`(p.s−startS)/(villain.s_live−startS)`). 빌런 아이콘은 실시간으로 움직인다.
  - N2: R은 항상 현재 목표를 조준하고 록온 레티클을 보여 준다. 갓길 청소는 별도 행동으로 뺀다.
  - N4: 모든 공격은 록온 기반이다.
  - N5: 깜빡이, 브레이크등, 상향등은 발광 + 블룸으로 키운다. **+ 차 위 신호 아이콘 말풍선**(사용자 추가 요청): 깜빡이 ◀/▶(램프와 같은 박자로 점멸), 브레이크 STOP, 상향등 빔 번쩍, 비상등 ◀▶, 경적 음파, **무깜빡 끼어들기(깜빡이에 X)**. 대상은 빌런·내 주변 25m·이벤트에 반응한 차만, 동시 최대 4개. 빌보드 + 거리 스케일, 색+모양 이중 부호(색약 대응), 빌런 신호에는 약한 햅틱 틱. T2 샷 테스트에 '아이콘 겹침 0' 검사 추가.
  - N6(구조만): 도로는 처음부터 `RoadGraph`(3-4b)로 그린다. M1은 직선 구간 1종만 구현하지만, sim↔렌더 매핑은 전부 `RoadGraph`를 거친다(직선에서 웹과 같은 좌표가 나오는 것이 T4 조건).
- 합격: 플래그를 켠 빌드는 별도 지표로 평가한다. 보스 첫 시도 실패율(봇 노이즈, V04_SPEC 열린 질문 9), 페이즈 길이 목표, 사용자 재플레이.

**M1 리스크:** bake 충실도(와인딩, 색, tint), 반구광·톤맵 재현(ΔE), 기기 루프 속도와 xcframework 빌드, 런타임 텍스트와 한글 줄바꿈, 셰이더 손 이식, UI 이식 분량, lavapipe와 실기기의 차이. ~~GDScript traffic 성능~~ → C++로 해소(3-2).

### M2 — 1챕터 동등성 (1-1 ~ 1-10, 시그니처 모듈) + Android
- **범위:**
  - 웹에 이미 있는 blinker_liar(1-5)와 tailgater(1-6, sig body를 트래픽 버킷에 넣음)를 이식한다.
  - 웹에 없는 **7개는 V04_SPEC을 기준으로 네이티브에서 새로 구현한다**: cutin_snap, duo_link, straddle_mirror, speed_kangaroo, merge_reflex, phone_drift, landlord(1-10 보스, 페이즈 포함).
  - **1-8 merge_reflex는 실제 `merge_ramp` 지오메트리 위에서**(N6): 한 대씩 교대하는 지퍼 합류 규칙 + 대기 차 머리 위 순번, 양보를 기 쓰고 안 하는 빌런(사용자 아이디어).
  - 접근 규칙(갓길 open/crowded/blocked/closed/dark/watched/merge/debris/occupied × 경적 모드)과 JamShaper 프리셋.
  - SKY 프리셋 night/rain/fog와 날씨 GPU 파티클.
  - **N3 '단속' 시스템**: 잔챙이와 숨은 위반차를 하나로 묶은 시스템. 위반별 아이콘, 처음 보일 때 1회 설명, 근접하면 링 + 햅틱. 범위는 V04_SPEC 부록 A.
  - UI 2차: 타이틀·챕터, 도감, 차고/상점, 결과 보상 타임라인과 블박 사진, 일시정지.
  - **Android:** Mac(또는 SDK가 되는 머신)에서 Gradle 빌드 설정, ext의 Android .so, Kotlin 플러그인(`VibrationEffect.Composition` 햅틱, 발열 상태).
- **합격 기준:**
  - 10판 × 20 seed autoplay 완주율 100%.
  - 판별 텔 샷이 베이스라인으로 승인된다.
  - 10판 모두 기기 성능 목표를 충족한다. **Android 중급기는 60 안정.**
  - 보스 첫 시도 실패율 약 30%(봇에 노이즈를 넣어 측정, V04_SPEC 열린 질문 9).
  - 사용자 재플레이: "3초 안에 판이 구분되고 원인이 읽히는가", "해법이 판마다 다른가".
- **리스크:** 새 모듈 7개는 웹이라는 오라클이 없어서 설계 검증을 네이티브에서 처음 하게 된다. UI 분량. Android 빌드 환경.

### M2+ 스파이크 — 휴게소 주차장 미니 코너 (사용자 아이디어 2026-10-13, `docs/PARKING_CORNER.md`)
- 가설: ❓ 본선과 감각이 반대(저속·관찰·정밀 주차)이고 톤은 같은(공식 수단 참교육) 45~75초 쉬어가기가 템포를 살린다.
- 스파이크(M2 합격 직후, 4~5일 ❓): 직각 배치 1종 + 빌런 #1 인간 주차콘·#2 라인은 거들 뿐, 정렬 조작 A/B, 보행자 불변식 T0(시드 1000 퍼징, 접촉 0). 사용자 iPhone 판정 ✅이면 M3에 MVP 5종 + 생성기로 편입(약 3~4주 ❓).
- 재사용: Rng32·고정 틱, cards(과태료 라벨 오버라이드), N3 확인 게이지, N5 아이콘, 경적 피로, 햅틱(주차센서 틱·사이드 딸깍), MultiMesh·bake. 신규: `sim/parking/`(GDScript 키네마틱), `ParkingLotGen`, `data/src/parking_*.json`. RoadGraph 변경 없음(씬 전환).

### M3 — 100판 + 패밀리 모듈
- **범위:**
  - V04_SPEC '100판 일반화'의 패밀리 모듈과 카탈로그 스키마(family, sig{module, params}, approach, fight, payoff). 스키마 확장은 `tools/content`와 `data/src`에서 한다.
  - 터널(조명 셰이더), 합류 테이퍼, 단속 갠트리, 데칼.
  - **`RoadGraph` 지형 구간**: `toll_plaza` + **N7 요금소 앞 칼치기러**(사용자 요청, VILLAIN_CATALOG '네이티브 추가 후보' T1: 무깜빡 대각선 들이밀기 → 미러링으로 3회 막기 → 빗금 안전지대 정지 → 단속 카메라 플래시 → 차단기 일제 개방 해방), `lane_drop`, `tunnel`, `curve`. 지형별 빌런 아이디어 풀은 카탈로그에 누적한다.
  - 피니시 balloon/heli/ufo, 드론, 상점 차량 3종, 1-EX 퍼레이드.
  - 나머지 SKY 프리셋, 소품, 그리고 100판 전체에서 차종이 다 해석되는지 확인.
- **합격 기준:** 100판 × 5 seed 완주율 100%, 에러 0. 최저 사양(A12)에서 60 고정. 앱 크기 ≤ 120MB.
- **리스크:** 자산 수가 늘면서 커지는 앱 크기. ~~160대 이상 판의 sim 비용~~ → T0 perf가 90판(161대)으로 이미 잰다.

### M4 — 플랫폼 기능
- **범위:**
  - Game Center(godot-ios-plugins, Mac에서 scons로 빌드, [repo](https://github.com/godotengine/godot-ios-plugins)), Play Games 3.4.
  - StoreKit 2(API가 아직 불안정 ❓, [repo](https://github.com/godot-sdk-integrations/godot-storekit2)), Play Billing v9.1([repo](https://github.com/godot-sdk-integrations/godot-google-play-billing)).
  - iOS 햅틱 고도화(AHAP 파일 기반 복합 패턴, 오디오 동기). 기본 Core Haptics 모듈과 발열 로그는 M1a에 이미 있다.
  - Android `setFrameRate` 플러그인(Godot는 이 호출을 하지 않는다 ❓, [android java](https://github.com/godotengine/godot/tree/4.7.2-stable/platform/android/java)).
  - 광고(Poing AdMob, [repo](https://github.com/poing-studios/godot-admob-plugin))는 열린 질문 4의 결정에 따른다.
- **합격 기준:** 샌드박스에서 구매·복원, 리더보드 제출, 햅틱 체감 QA, Android 120Hz 기기에서 120 확인.
- **리스크:** 플러그인 성숙도, iOS 플러그인은 Mac에서만 빌드.

### M5 — TestFlight / Play 내부 테스트 → 출시
- **범위:** Apple Developer Program, Play Console, 개인정보 매니페스트와 연령 등급, 크래시 리포트(Play 네이티브 심볼 업로드), 스토어 자산.
- **합격 기준:** TestFlight와 Play 내부 테스트를 2주 진행. 크래시 없는 세션 ≥ 99.5%. Android vitals 크래시와 ANR이 Play 경고선 아래.
- **리스크:** 엔진을 4.7.2에서 올릴 때의 GPU 드라이버 회귀(올리면 T2·기기 판정을 다시 한다). 심사 4.2(Minimum Functionality)는 네이티브 앱이라 위험이 낮다.

---

## 6. Mac / Xcode / Android 빌드 경로 (요약; `docs/MOBILE_BUILD.md`는 M1-0에서 Godot용으로 다시 씀)
1. Mac에 **컨테이너와 같은 버전(4.7.2)의** Godot 공식 빌드와 export 템플릿(Editor › Manage Export Templates)을 설치한다. Xcode는 26 이상(App Store 업로드 요건, MOBILE_BUILD.md 참고), cmake(또는 scons).
2. **iOS:** `bash tools/mac/ios_run.sh` 하나로 ext·iOS 모듈 xcframework 빌드 → Xcode 프로젝트 export → xcodebuild → 기기 설치·실행(4-3). 처음 한 번은 `tools/mac/SIGNING.md`. Linux에서 Xcode 프로젝트만 export할 수 있는지는 ❓.
3. **Android (M2):** OpenJDK 17과 Android SDK(platform-tools, build-tools 35.0.1, platform 35, Gradle 빌드용 NDK). 플러그인이 있으므로 Gradle 빌드로 AAB를 만들고, 디버그 APK는 `adb install`로 올린다 ([Android export](https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_android.html)). VIBRATE 권한이 필요하다.
4. 나중에 선택: macOS CI 러너에서 두 플랫폼을 자동 빌드한다.

---

## 7. 열린 질문 (사용자 결정 필요, 괄호 안이 제안 기본값)
1. **기기 범위와 테스트 장비 — M1-0 전에 반드시 답이 필요하다**: 지금 가진 iPhone 모델(120Hz 여부), Android 기기, Apple silicon Mac이 있는가? (기본값: iOS A12 이상, Android는 Vulkan 기기 + GLES3 자동 폴백. 측정 기준기는 iPhone 13 Pro + 60Hz 아이폰 1대 + Android 중급기 1대.)
2. **120Hz 정책** (기본값: 게임플레이 120, 메뉴 60. 발열이 'serious'이거나 저전력 모드면 자동으로 60. 설정에 '배터리 절약(60)' 토글.)
3. ~~**웹과 데이터 원천** (M2까지 `game/js`에서 튜닝 후 export)~~ → **결정**(2026-10-13 리뷰): `game/js`를 고치면 동결 레퍼런스와 T4 오라클이 함께 움직이고 튜닝할 곳이 두 군데가 되므로, M1-0에서 1회 export하고 원천을 `native/data/src`로 옮긴다. 웹은 `web-frozen` 태그. `app/`(Flutter)는 M1c 합격 뒤 삭제.
4. **수익 모델** (M4 범위를 정함) (기본값: 무료 + 선택형 보상 광고(결과 화면 포상금 2배) + 광고 제거·외형 IAP. 강제 전면 광고는 없음.)
5. **고사양 렌더 티어** (기본값: 모든 기기에 Mobile 렌더러 + bake AO. Forward+ '고화질' 티어(SSAO, 빗길 SSR)는 M3에서 성능 여유가 확인되면 최신 Pro 기기 한정으로 실험한다.)
6. **톤매퍼** (기본값: Linear = 웹과 같은 팔레트. M1a 디버그 패널에서 AgX·Filmic과 A/B해서 사용자가 고른다.)

---

## 8. 리뷰 반영 기록 (2026-10-13)
- 반영: blocker 1(traffic C++), major 10(4.7.2 하드 게이트, iOS 햅틱 M1a, 자산 3부류, Linear·반구광, MultiMesh 기본, M1 분할, Mac 기기 루프, T1/T2 시간, T4 플래그, 히치 방지), minor 8(원천 단일화, 폰트·줄바꿈·SVG, interpolation 상시, main.js:630 햅틱, 발열 측정, 세이브, 오디오 탭, Nix lavapipe).
- 정정 1: `word-break: keep-all`은 리뷰의 9곳이 아니라 style.css에 **18곳**이다(grep). 결론(줄바꿈 테스트 필요)은 같다.
- 정정 2: 오디오 bake를 "`S.noClip` 경로"로 compressor 앞에서 탭할 수는 없다. `noLimiter`는 클리퍼만 빼고 compressor는 남긴다(`audio.js:162-168`). 그래서 bake 전용 `preComp` 옵션을 추가한다(3-8).
- 정정 3: Godot의 Linear 톤매퍼에서는 `tonemap_white`가 쓰이지 않으므로 "Linear(white 1.0)" 대신 "Linear(exposure 1.0)"로 적었다.
- 범위 조정: "M1부터 MultiMesh 기본"은 NPC와 소품에만 적용한다. 히어로 차량(플레이어·원흉·보스)은 파손 단계·피니시 연출 때문에 MeshInstance3D로 둔다(수가 적어서 draw 예산에 영향이 작다).
- 범위 조정: 리뷰는 stagegen.js와 villain_catalog.json을 둘 다 `tools/content/`로 옮기자고 했다. 데이터와 코드를 나눠 catalog는 `native/data/src/`, stagegen.js는 `tools/content/`에 둔다. 웹 원본은 동결 상태로 남긴다(옮기면 웹이 깨진다).
- 범위 조정: iOS 햅틱 모듈은 ".gdip 또는 GDExtension" 중 **GDExtension(ObjC++)**으로 정했다. ext/traffic과 같은 godot-cpp·xcframework 빌드 경로를 쓰기 때문이다.
- 리뷰 밖 자체 정정: 3-4의 "JS `%`는 `fposmod`로"는 틀렸다. JS `%`는 C의 `%`/`fmod`와 같고 `fposmod`와 다르다.

---

## 9. M1 진행 기록

### 2026-10-13 — 컨테이너 야간 작업 (게이트 · 콘텐츠 · bake · Mac 도구 · C++ traffic · 뷰 · 통합)
가설: (I1) TrafficBridge(C++)를 뷰에 연결하면 1-1 정체 슬라이스가 돈다: 주행, 스와이프 차선 변경, 경적 → 답 말풍선, N1 바 = 거리, N5 아이콘. ✅ 컨테이너에서 확인. "웹보다 낫다"는 기기 판정이라 ❓.

**M1-0 합격 대비**
- ✅ 4.7.2 Xvfb Mobile 샷이 빈 화면 가드를 통과한다 (`tools/native-check.sh` shot, lum_sd 0.17).
- ✅ ext .so가 헤드리스에서 로드된다 (godot-cpp 10.0.0-stable, api 4.7, `test_ext`).
- ✅ `export-content.mjs` → `native/data/src`, 골든. `web-frozen` = 753549a (태그 push가 막혀 SHA로 참조). audio.js `preComp`는 웹 동결 때문에 코드 대신 `tools/bake-audio.mjs`가 compressor 앞에서 탭한다.
- ❓ iPhone에서 `ios_run.sh` 1회로 10분: Mac에서 아직 안 돌렸다. 컨테이너에서는 mock macOS로 전 경로, 실제 iOS export(Xcode 프로젝트 생성)까지 확인. 이제 `run/main_scene=res://view/game.tscn`이라 빈 씬 대신 1-1 정체 씬이 뜬다.

**M1a 합격 대비**
- ✅ T0: spawn 1/5/6 골든 + RNG 트레이스 + rng 1000개 일치, traffic 틱 골든 600 + 4800틱과 이벤트 18개 bit-exact.
- ✅ T0 perf: 90판(161 NPC + 반대편 26) C++ p95 0.025–0.065 ms (debug/release), bridge p95 0.04–0.10 ms ≤ 0.5 ms.
- ✅ T2 jam 샷: draw 33–35 (보이는 것) / 59–62 (그림자 포함) ≤ 250 / 400. 웹 동일 카메라 ΔE76 평균 6.67 (텍스트 갠트리 아래 중앙값 0.82) → 리뷰 반영 후 **3.94** (아래 2026-10-13 (2)). native-check에 jam 단계(`--no-jam`으로 끔)를 넣었다.
- ❓ 기기 120Hz p95 ≤ 8.3 ms, thermalState 로그: Mac·기기가 필요하다. lavapipe 570–645 ms/frame(585×1266, MSAA 4x)은 기기 지표가 아니다. 뷰 CPU 동기화 p50 0.6–1.0 ms (debug 빌드, 잡음 큼)로 1.0 ms 예산 경계다.
- ❓ 사용자 판정(조명·120Hz·햅틱이 웹보다 낫다): FEEDBACK_LOG 기록 대기.
- 범위: core·C++ traffic ✅, bake ✅, world·camera ✅, 조명·포스트 ✅, 경적 SFX ✅. player는 ✅이지만 `view/player_driver.gd`(IDM 대역)가 임시로 맡고 `sim/player.gd`는 아직 없다. iOS 햅틱은 호스트(null 백엔드)만 ✅, `.mm`은 미컴파일 ❓.

**통합 (이번 단계)**
- `view/game.gd`: 120 Hz `_physics_process`에서 입력 → PlayerDriver → `TrafficBridge.step` → 이벤트 → N5 순서로 돈다. `_process`는 물리 보간 비율 하나로 NPC·빌런·플레이어 s(HUD)를 같은 시간축에 보간한다. startS·frontS는 `bridge.setup_info()`에서 받는다(단일 원천).
- 경적(main.js:1076): honkCool 1 s(sim 시간), SFX + 햅틱 `horn` + '빵!' 팝 + 링. 답 kind별 말풍선(`ui/bubbles.gd`, lines.json YIELD/NOWAY/LETIN/CHEATER, tired·villain은 inline 대사). 말풍선은 N5 아이콘을 가리지 않게 위로 비킨다.
- `project.godot`: main scene, Haptics autoload 등록. 순서는 DB SaveGame Haptics.
- 테스트 추가:
  - `test_hud_progress`: 60 s 동안 매 틱 바 = 1 − dist/span, 라벨 = round(dist), HUD villain_s = sim live s. 답한 경적마다 말풍선이 뜨는지도 본다.
  - `test_determinism`: 같은 seed면 게임 단과 브리지 양 백엔드 모두 30 s 버퍼가 bit 동일, seed를 바꾸면 달라진다.
  - shim: `test_haptics`(platform/ios 테스트를 러너에 연결), `test_perf_traffic`(`--suite=perf`).
  - 전체 9파일 fails=0. `native-check.sh` GREEN (ext, import, t0, shot, jam).
- 재현성: manual 모드(샷·테스트)는 벽시계 시간을 쓰지 않는다(real_time, 카메라, 링, 바퀴). 그래서 같은 인자로 찍은 샷 두 장이 바이트 동일하다(md5 일치).
- export:
  - Linux release export의 실행 파일이 main scene으로 부팅하고 C++ release .so를 로드한다. 오류 0.
  - iOS export(컨테이너 stub xcframework)의 Xcode 프로젝트는 bundle `com.ffogtive.lane1Chamgyoyuk`, 팀 placeholder, iOS 15.0, iPhone 전용이고, traffic·haptics·godot-cpp xcframework를 담는다. pck에는 game.tscn과 main_scene이 있고 tests/·tools/·data/src는 없다. `ios_run.sh`의 preset·scheme·경로와 일치한다.

**발견 (사용자 판정 필요 ❓)**
- 1-1 정체에서는 차선 차량의 85–95%가 늘 브레이크등을 켠다. 웹과 같은 임계값 vBelow 1.6 m/s라서 생기는 '빨간 바다'다. 그래서 브레이크 파동은 '빨간 물결'이 아니라 **꺼진 틈이 뒤로 흐르는** 모양으로 보인다(final/brake_wave.png의 시공간 패널). 이미 켜진 차선에 `emit_brake_wave`를 강제로 넣어도 눈에 띄지 않는다. 파동을 읽히게 하려면 M1d N5에서 웹과 다른 연출이 필요하다. 예: 브레이크등 밝기를 감속도에 비례시키기, 파동 앞머리 플래시. 동등성 빌드(T4)에서는 끈다.
- 램프 비트: C++은 깜빡이 '활성'(방향)을 쓰고 위상은 뷰가 웹식으로 적용한다. 위상이 두 번 적용되는 일은 없다 ✅.
- 샷: `…/scratchpad/m1/final/{jam_native, jam_web, jam_side_by_side, honk_icons, brake_wave, jam_native_bridge}.png`. jam_native는 웹 프레임에 고정(stub)한 것이고, jam_native_bridge·honk_icons·brake_wave는 C++ TrafficBridge로 찍었다.

### 2026-10-13 (2) — 코드·아트 리뷰 반영 (blocker 2 · major 10 · minor 다수)
가설: blocker·major 리뷰를 모두 고치면(+ 싼 minor) M1a 슬라이스는 초록으로 남고, Mac 없이 할 수 있는 만큼 iPhone 한 명령 경로가 안전해진다. ✅ 컨테이너(테스트 9파일 fails=0, native-check GREEN, mock macOS 전 경로 exit 0). ❓ 실제 Mac·iPhone.
- ~~빈 stub xcframework + `-Wl,-U`면 링크·실행 OK~~ → ❌ 기각(코드 리뷰): Godot가 만든 dummy.cpp가 진입 심볼 주소를 weak 없이 등록해서, 심볼이 없으면 실행 때 dyld가 죽는다. 이제 stub이 `entry_symbol`을 정의하고 false를 돌려준다 ❓(Mac 미검증).

**고친 것 (✅ 컨테이너 확인)**
- iOS 빌드·실행 경로 (`tools/mac/`)
  - `build_ios_ext.sh`: `[libraries]` stub이 manifest의 `entry_symbol`(`traffic_library_init`, `lane1_haptics_init`)을 정의하고 0을 돌려준다. 의존성(godot-cpp) stub은 빈 것 그대로. traffic iOS 최소 버전은 `$IOS_MIN`(15.0)으로 통일했다.
  - `ios_run.sh`:
    - `launch: ok`는 실행 8초 뒤에도 프로세스가 살아 있을 때만 찍는다(`devicectl device info processes`). 죽었으면 `launch: failed (exited within 8s)`, exit 7. install=ok는 그대로 남긴다.
    - 게임이 `user://boot.txt`(iOS Documents)에 부트 줄을 쓰면 `devicectl device copy from`으로 가져와 `native=true|false`를 receipt에 남긴다. 예전 실행의 파일이면 `?`로 둔다.
    - stub이나 실패한 확장은 ✅가 아니라 ⚠️로 표시한다. `--check`에서 cmake가 없으면 경고한다. Metal toolchain이 없거나 export.log에 'Metal shader baking limited'가 있으면 경고한다.
    - receipt에 `running= native= extensions=`를 더했다.
    - mock macOS로 살아 있는 경우(exit 0)와 죽은 경우(exit 7), 오래된 boot.txt를 확인했다.
- 입력: `LaneInput`이 emulate_mouse_from_touch로 생긴 마우스 이벤트(`DEVICE_ID_EMULATION`)를 무시한다. 탭 한 번 = 차선 한 칸 ✅. 테스트는 Xvfb에서 `Input.parse_input_event`로, headless에서는 에뮬레이션 쌍을 직접 넣어서 돌린다. 수정 전 코드로는 두 경로 모두 edge가 2개 나와 실패하는 것을 확인했다.
- safe area: HUD 위젯을 모두 `Hud.safe` 아래로 옮겼다.
  - 모바일에서는 `DisplayServer.get_display_safe_area()`를 캔버스 단위로 바꿔 쓴다. 데스크톱과 샷은 `--safe-pt=59,34`로 가짜 inset을 준다.
  - N5 아이콘과 말풍선도 이 안에 머문다. 아이콘은 HUD 사각형 위에 놓이지 않고, 화면 밖이나 노치 아래에 있는 후보는 4슬롯을 차지하지 않는다.
  - 게이트 jam 단계는 59/34 pt inset으로 찍는다.
- 일시정지 버튼(오른쪽 위)과 앱이 백그라운드로 가면 자동 일시정지(`NOTIFICATION_APPLICATION_PAUSED`). sim·뷰를 멈추고 HUD·입력은 계속 돈다. 메뉴는 없다.
- 샷 카메라: `advance_ticks`가 매 틱 카메라 목표를 플레이어로 맞춘다. 플레이어가 화면 높이의 약 69%에 온다(웹 70%). 테스트는 수정 전 코드로 실패하는 것(14.25 m 뒤처짐)을 확인했다.
- 룩
  - 그림자: SOFT_MEDIUM + blur 0.6. project.godot에도 `soft_shadow_filter_quality(.mobile)=3`을 넣었다.
  - glow는 level 1만 쓴다. 뒷유리 R이 웹 ±3 안에 든다(전에는 +31..+42).
  - AO는 `ao_light_affect` 0.35, `ao_strength` 0.6. 평평한 패치 761개가 최대 3.9 RGB만 움직였다.
  - 접지 블롭을 1.02×1.0으로 줄이고 둥글게 했다.
  - 플레이어 지붕 경광등(0x5a3a00 ↔ 0xffa000 + HDR, 0.18 s 점멸).
  - 1-1 시작 갠트리 2개(빈 녹색 판 #0b7a4b, 카메라 앞 12–30 m면 world.js처럼 흐려짐)와 VMS 3개(빈 판).
  - 핀 고정 ΔE76 평균: 6.67 → **3.94**.
- N5
  - BRAKE는 이벤트로만 뜬다: 브레이크 비트가 켜질 때나 감속 2 m/s² 초과일 때 1.2 s. 상시 크롤에서는 안 뜬다.
  - 깜빡이 꺼진 반주기에는 배지를 흐리게 하지 않고 어두운 화살표 텍스처로 바꾼다.
  - 무깜빡 끼어들기는 화살표 + 빨간 ⊘ 코너 배지다. X는 닫기 버튼처럼 읽혀서 바꿨다.
  - 경적 답을 한 차에는 아이콘을 띄우지 않는다(말풍선이 신호다). HONK 아이콘은 NPC 경적용으로 남긴다.
  - 텍스처는 192 px(2×), 화면 크기 42(약 36 pt).
- 말풍선은 아이콘을 피해 옆으로 비킨다. 꼬리는 항상 답한 차에 닿는다. '빵!' 팝은 흰 글씨에 #1b1c1f 외곽선이고 지붕 +1.2 m에서 0.6 m 떠오르며 1.0→1.25→1.0으로 튄다.
- HUD
  - N1 바: 빈 트랙은 어두운 색, 채움은 노랑→주황, 마커는 위에서 본 내 차.
  - 알약에는 '200'을 28 px 노랑으로 강조한다. 바·숫자는 여전히 `Hud.shown` 하나를 읽는다(N1 테스트 ✅).
  - 속도 게이지: 원판 0.92, 240° 녹→황→적 호.
  - 버튼은 평소 0.45, 누르면 1.0.
- 기타: 확장 로드는 한 번만 시도한다(폴백 모드의 ERROR 반복 제거). native-check jam 단계는 경적을 5.7 s에 울리고, 말풍선과 링이 각각 1개 미만이면 실패한다.

**리뷰와 다르게 한 것**
- glow: "SCREEN 블렌드 + 램프 코어 2–3"은 효과가 없었다. ADDITIVE와 SCREEN이 같은 값을 냈고, 코어는 이미 Mobile HDR 상한(≈2.0)이다. 원인은 level 2 이상의 번짐이라 level 1만 남겼다. SCREEN은 유지했다.
- 거리 알약: Label 2개나 RichTextLabel 대신 같은 `shown`을 읽는 커스텀 드로우로 그렸다. 숨긴 Label은 테스트용 N1 문자열을 유지한다.
- 게이지 바늘·눈금은 아직 없다(M1c).
- `docs/IPHONE_DEPLOY.md` §7/§8과 CLAUDE.md §2 보강은 이 단계의 소유 범위 밖이라 `docs/MOBILE_BUILD.md` 8절에만 넣었다(capability 오류, 데이터 초기화, Simulator 금지, 롤백 주의).

**아침에 iPhone에서 확인할 것** (`git pull` → `tools/mac/ios_run.sh`)
1. 결과 화면이 `launch: ok (running after 8s)`, `running: yes`, `native traffic: true`인지 본다. `false`면 cmake/traffic 빌드가 stub이 된 것이니 ext.log를 보낸다. `running: no`면 기기 로그를 보낸다(MOBILE_BUILD 8절).
2. 다이내믹 아일랜드 아래로 진행 바·'원흉까지 N m'가 완전히 내려와 있는지, ◀ ▶ 경적 버튼이 홈 인디케이터 위에 있는지, 일시정지 버튼(오른쪽 위)이 멈춤/재개되는지 본다.
3. 스와이프 한 번과 ◀/▶ 탭 한 번이 각각 정확히 한 칸인지, 경적이 '빵!' + 링 + 앞차 말풍선 + 햅틱을 내는지 본다.
4. 120Hz 체감, 카메라가 움직일 때 그림자 지글거림, 브레이크등 glow(빨간 바다가 보이는지, 너무 약한지), 지붕 경광등 점멸, 갠트리를 지날 때 흐려지는지 본다.
5. "조명·120Hz·햅틱이 웹보다 낫다?" 판정과 receipt.txt를 FEEDBACK_LOG에 남긴다.

**전체 게임 대비 남은 차이 (M1b~M1d)**
- 플레이어는 아직 `view/player_driver.gd`(IDM 대역)가 맡는다. player.js 이식(HP·추돌·분노·갓길 규칙), 원흉 페이즈·보스, 결과 화면, 점수가 없다.
- UI·오디오·텍스트가 비어 있다. 메뉴·상점·스테이지 선택, 표지판·VMS 글자(M1c), BGM과 경적 외 효과음, 스테이지 배지·제목·잔챙이 카운터·분노 버튼이 없다.
- 스테이지는 1-1 낮뿐이다. 밤·날씨가 없다.
- 브레이크 파동을 읽히게 하는 연출(사용자 결정 ❓), 뷰 CPU 0.6–1.0 ms(1.0 ms 경계, 기기 측정 ❓), 실제 Metal·120 Hz·발열 ❓가 남아 있다.

### 2026-10-14 — M1b 통합: 1-1을 iPhone에서 끝까지 (GameSim · 압정/분노 버튼 · BGM · 결과)
가설: `view/game.gd`가 GameSim을 1/120 고정 틱으로 돌리고 `state()`/`events()`만으로 그리면, 1-1을 폰에서 끝까지 플레이할 수 있다. 흐름: 정체(BGM + 엔진) → 원흉 등장·잠금 → 압정/분노 타격 피드백 → 처치 → 해방 파도 → 결과 → 다시/다음. ✅ 컨테이너(e2e 5 seed, 버튼 경로, 견인 → 재도전, 페이즈 음악, 샷, iOS export). ❓ 기기 체감.

**사용자 기기 피드백 → 이번 빌드**
- "배경음도 없고" → 페이즈마다 `Audio.phase()`(웹 enterPhase)를 부른다. 인트로·정체는 mus_jam + 정체 앰비언스, 원흉전은 mus_boss, 해방은 환호 뒤 0.6 s에 mus_release를 시작해 결과 화면까지 이어 간다. 엔진음은 매 프레임 낸다. iOS 세션은 Playback이라 무음 스위치를 켜도 들린다 ❓(기기).
- "원흉까지 갔는데 아무것도 안 나타나고 / 원흉 차도 뒤에서 앞으로 통과" → 원흉은 BossSim이 몰고, 뷰는 `state().villains`를 따른다(e2e 위치 오차 0.000 m). 35 m 앞에서 '원흉 발견!'과 HP 판이 뜬다. 갓길로 앞지르면 '정면 잠금!'이 뜬다. 잠금 전에는 leash가 원흉 앞으로 2.5 m까지만 허용한다(P0#1).
- "압정 버튼은 없나?" → 오른쪽 아래 빨간 **압정** 버튼(꾹 누르기)과 **분노** 버튼이 있다.
  - 정체에서 압정은 잔챙이를 맞히고, 맞힐 대상이 없으면 경적이 된다(웹과 같다).
  - 원흉전에서 압정은 레티클 안의 원흉을 맞힌다. 원흉 차로 ±1 안이면 초록이고, 밖이면 회색 + '◀ 원흉 차로로' + '빗나감!'이다.
  - 분노는 잠금 전에 분노 경적, 잠금 뒤에 폭탄이다.
  - 스와이프: 아래는 브레이크, 위는 분노다.
- DBG 탭이 진행 바 앞을 가림 → 탭을 숨겼다. 세 손가락 탭이나 F1로 연다. 갠트리 격자 문제는 UI 단계에서 고쳤다(dissolve).

**iPhone에서 지금 보일 것** (`git pull` → `tools/mac/ios_run.sh`)
1. 2 s 인트로 뒤 정체 BGM이 나온다. 하단 바: ◀ ▶ · 경적 · 압정(큰 빨강) · 분노.
2. 갓길로 가면 '원흉 발견! 정속주행 김사장'이 뜬다. 원흉은 1차선 앞에서 정체 선두를 잡고 있다. 앞질러 잠그면 레티클(LOCK)이 원흉 위에 붙는다.
3. 공격 예고를 3D로 그린다(새 `fx/hazard_view.gd`, UI 단계에서 비어 있던 부분):
   - 상향등: 빛기둥이 점멸하다가 켜진다.
   - 경적: 차로마다 아치가 퍼진다.
   - 투척: 포물선을 그리며 날아오고, 떨어질 곳에 빨간 링이 찬다.
   - 이 밖에 돌진, 상향등 릴레이 경직(약점! ×4)이 있다.
4. 처치하면 슬로모 폭발, '참교육 완료!' + 패배 대사, 궤도 카메라가 나온다. 해방되면 ✓ 파도, '해방된 차량 N대', 해방 BGM이 나온다.
5. 결과 카드: 걸린 시간 · 최저 내구도 · 견인 · 원흉전 시간, 미션 3개, 포상금. 기록은 `Progress.record_result`에 저장한다. 버튼:
   - 다음 빌런: 1-2 로드. 1-2는 범용 보스다.
   - 다시하기: 1-1 다시.
   - 메뉴: 아직 타이틀 화면이 없어서 1-1을 다시 시작한다.
6. HP가 0이 되면 '견인!' 카드가 뜨고, 다시 도전하면 원흉 33 m 뒤에서 이어 간다. 결과 카드에는 견인 1회와 ★2 실패가 정직하게 찍힌다(P0#6).

**바꾼 것** (커밋 없음)
- `view/game.gd`
  - GameSim을 중심으로 다시 썼다.
  - 입력은 LaneInput → `GameSim.input`으로 간다. 압정은 누르는 동안 + 틱보다 짧은 탭의 edge를 넘긴다. 브레이크·분노·경적도 같은 길이다.
  - 이벤트 → HUD/FightFx/카메라/N5/말풍선 + 웹 audio.play 대응 SFX + 햅틱. 같은 소리를 페이즈 소리와 이벤트 소리로 두 번 내지 않는다.
  - 히어로 차량은 틱에서 놓고 엔진이 보간한다.
  - 재도전하면 NPC 사양과 고장차를 다시 읽는다.
  - 처치 페이즈에서는 원흉 말풍선을 숨긴다. 배너가 같은 대사를 이미 보여 주기 때문이다.
  - 호스팅 계약을 갖췄다: `stage_finished`·`paused_changed`·`hosted`·`intro_hold`+`begin()`·`loadout`. `test_screens_host`의 INFO 줄은 모두 true다.
  - `--autoplay` 플래그를 추가했다.
- `fx/hazard_view.gd`(신규), `view/hero_vehicle_view.gd`(`set_flat`: 터진 타이어), `view/debug_panel.gd`(탭 숨김 + `toggle()`).
- 테스트:
  - `test_e2e_1_1`(`--suite=e2e`), `test_phase_audio`(unit).
  - `test_view_smoke`·`test_hud_progress`를 GameSim 경로로 바꿨다.
  - `run_tests.gd`는 종료 전에 오디오를 비운다(재생 중이던 스트림이 누수 경고로 보고되던 문제).
  - `shot_game.gd`(신규): 통합 game.tscn의 페이즈별 샷.
  - `shot_jam.gd`: `--stub/--state`의 차량 고정을 제거했다. TrafficStub 경로가 없어져서 이제 카메라만 고정한다.
- `tools/native-check.sh`: 6단계 `e2e`를 추가했다. 헤드리스 e2e 다음 Xvfb `shot_game`을 돌린다. `--no-e2e`로 끈다.

**검증**
- e2e 5 seed(1007/3/11/42/77) 모두 intro → jam → boss → kill → release → cruise → result 카드까지 갔다.
  - 판 시간 43.2–46.7 s, 원흉전 10.9–12.9 s, 전부 ★3, 최저 HP 80–97, 견인 0.
  - 레티클이 화면에 있고 압정 버튼이 보인다. SFX 141–173개, 햅틱 143–167개.
- 압정 버튼 경로: LaneInput `fire:down`을 1.2 s 유지하자 fire 6, hit/miss 6이 나왔고, 떼자 멈췄다.
- 견인 → 재도전: 카드 retry → jam → boss → result. 결과는 견인 1, 최저 HP 0, ★2 실패, 32.4 s.
- `test_phase_audio`: 음악은 jam → boss → (환호) → release 순서로만 바뀐다. release 요청은 0.60 s 뒤에 온다. cruise 앰비언스는 free다. 엔진 루프가 돈다.
- 전체 unit 22파일 fails=0, integration(screens_host) fails=0. `native-check.sh` GREEN(ext·import·t0·shot·jam·e2e).
- 1-2~1-6 범용 보스 probe(GameSim + autopilot): 모두 result까지 갔다(57–87 s). 오류 0.
- iOS export dry-run(`--export-debug iOS`)은 exit 0, 27 s.
  - 폴더 440 MB 중 409 MB는 디버그 엔진 xcframework, 20 MB는 MoltenVK다. `lane1.pck`는 11.2 MB다.
  - libtraffic iOS xcframework는 들어가고 tests/는 빠진다.
  - .ipa는 Linux라 만들지 않는다. Mac에서 빌드·설치·실행·기능 확인은 각각 ❓다.
- 샷: `…/scratchpad/m1b/final/final_{jam, boss_approach, boss_lock, attack, kill, release, result}.png`.

**알려진 차이 · 결정 필요 ❓**
- 튜닝 승인이 필요하다(GameSim 단계): `weapons.tack.rate` 5(웹 7), 약점 창 안 `bomb.dmg` 16(웹 28). 원흉전을 10–20 s에 맞추려고 바꾼 값이다.
- 기기 빌드의 main scene은 아직 `view/game.tscn`이다. 타이틀·스테이지 선택·차고(`screens/app.tscn`)로 바꾸는 것은 FI(NATIVE_PARITY 8)에서 한다. 계약은 준비됐다.
- 1-2~1-6은 시그니처 미이식 상태로 범용 보스와 공격표를 쓴다(M2).
- 예고 연출은 단순하다: 원뿔, 아치, 구, 링. 웹의 컵·폰 모델은 아니다. 부순 콘은 정적 배칭이라 남아 보인다. 고장차만 숨긴다.
- 원흉전 화면이 붐빈다. '치명! −N' 팝이 도발 말풍선과 겹친다(M1d 정리 후보).
- 기기에서 아직 확인하지 않은 것 ❓: 무음 스위치를 켠 BGM, 햅틱 체감(fire 5/s), 120 Hz에서 FX·예고를 켠 프레임 시간.

### 2026-10-14 (2) — 기기 2차 피드백 반영: 통과 버그 · 링 게이지 · 압정≠경적 · 분노 사다리/아이템 통합
가설: ✅ 스킬 sim(`sim/skills_sim.gd`)과 연출(`fx/skill_fx.gd`·`fx/skill_cues.gd`·카메라·HUD)은 이미 있었다. 빠진 것은 뷰 배선(LaneInput 분노·item1·item2·skip → GameSim, loadout → GameSim·HUD)뿐이었다. 배선 뒤에는 터치만으로 1-1에서 모든 단계와 아이템을 쓸 수 있다(네이티브 + 폴백). ❓ 기기에서 '쾌감' 판정.

**피드백 → 원인 → 반영** (상세는 FEEDBACK_LOG 2026-10-14 행)
- ① 빌런 뒤에서 앞으로 통과: iPhone 경로(GDScript 폴백 `_Creep`)가 빌런을 리더·차로 점유로 보지 않았다 → `traffic_bridge.gd` 폴백만 수정(C++ 무변경). `test_collide` 폴백 포함.
- ② 링·막대 중복: 막대 삭제, 분노 버튼 링(5칸, 1·3·MAX)이 유일한 게이지. `test_hud_rage`.
- ③ 압정이 경적: GameSim이 정체에서 대상 없는 압정을 경적으로 바꿨다(웹 이식) → 압정은 경적·스킬을 절대 만들지 않는다, 대상이 없으면 `fire_dry`. `test_input_zones`.
- ④ 쾌감 + 분노 단계 스킬 + 아이템: `docs/SKILLS.md` 사다리 t1/t3/t5 + item1 점프 / item2 드론 + 피니시 킬캠 + 건너뛰기(sim·연출은 각 담당, 이번 단계는 통합).

**통합 (이번 단계)**
- `input/lane_input.gd`:
  - 존 `item1`/`item2`에서 손가락이 닿는 순간 엣지가 1개 생긴다(`consume_item(slot)`, `item_requested`). 빈 슬롯은 `Rect2()`라 존이 아니다.
  - skip: `skip_armed`일 때 빈 화면을 탭하면(스와이프·버튼 아님) `consume_skip()`.
  - 분노는 길게 눌러도 탭 1회다(닿는 순간).
  - 키보드: Q/1 item1, E/2 item2, Enter/K skip.
- `view/game.gd`:
  - `tables.options.loadout`: 호스트(app)가 준 loadout을 쓰고, 단독 실행이면 `Progress.loadout()`을 쓴다. manual(테스트·샷)은 호출자가 준 값만 쓴다.
  - `hud.finish_id` = 장착 피니시.
  - `_route_input`: `&"item1"`/`&"item2"`/`&"skip"`을 보낸다.
  - `input.skip_armed` = `state.skills.skip_ready`(또는 HUD 힌트).
  - 드론의 `fire`(drone: true)는 햅틱 없이 작은 tack 소리만 낸다.
  - manual `advance_ticks`: FightFx는 Σ TICK × 그 틱의 sim 배율(히트스톱이면 멈추고 슬로모면 느려진다), SkillCues는 실시간으로 진행한다.
  - 테스트용 `event_tap`.
  - skill_*·tier_ready·item_ready·finisher의 소리·햅틱은 SkillCues만 낸다(중복 없음).
- `ui/hud.gd`:
  - '탭: 건너뛰기' 힌트는 sim의 `skip_ready`를 따른다. HUD 자체 kill 시계가 sim보다 약 30 ms 빨라서, 그 틈의 탭이 무시되던 것을 고쳤다(터치 e2e가 잡았다).
  - 드론의 fire로는 압정 버튼이 반동하지 않는다.
- `tools/native-check.sh` e2e 단계: `shot_game_skills.gd --fallback`(iPhone 경로) 터치 스킬 런을 추가했다. 캐스트·skip·결과가 하나라도 빠지면 exit 1.

**테스트 · 샷**
- `tests/skills_touch_run.gd`(공용 드라이버):
  - 접근은 autopilot이 한다. 정체 t1과 원흉전은 '사람'이 HUD rect에 `InputEventScreenTouch`를 보낸다(Viewport.push_input, 캔버스 좌표).
  - 원흉전 동안 손가락 0으로 압정을 누르고 있다. ◀ ▶ 탭으로 예고를 피한다.
  - 순서: 분노 t1 → item1 → 분노 t3(0.2 s 홀드) → item2 → 분노 t5 처형 → 피니시 → 빈 화면 탭 skip → 결과.
  - 분노가 모자라면 그 단계 칸 수로 채운다. 경제는 `test_e2e_skills` 몫이다. t5 때 HP가 처형선 위면 처형선 아래로 낮춘다. 채운 내역은 INFO 줄에 찍는다.
- `tests/test_e2e_touch_skills.gd`(`--suite=e2e`), 네이티브 + 폴백, seed 1007, 각 20+ 체크 fails=0:
  - 정체 t1_horn + rage_horn. 압정을 누르고 있어도 경적 0.
  - t1_wave / t3_carpet / t5_finish가 각 1회 나오고 맞는다. 탭 직전 HUD 얼굴 = 그 단계.
  - mv_jump / mv_drone가 맞고, 그동안 압정이 계속 눌려 있다.
  - item 존이 등록되고, 모든 존이 서로 겹치지 않는다.
  - t3에서 SkillFx 압정 12개 + 데칼이 나온다. t5가 처형하고 처형선 0.40이다.
  - finisher rocket → 카메라 rocket, HUD rocket.
  - SkillCues가 haptic skillT5Charge·skillT3Hit 등을 내고(72–81 cue), Audio SFX 144–162개가 나온다.
  - skip{finish}. HUD 힌트 = sim skip_ready(모든 프레임 불일치 0). 경적 누출 0. 결과 카드.
- `tests/shot_game_skills.gd`(Xvfb, 통합 game.tscn): 20장 + `skills_sheet.png`.
  - 장면: jam_t1_cast/wave, fight_lock, t1_cast/hit, jump_air/land, t3_cast/hit/after, drone_cast/hit, t5_cast/charge/impact, finish_a/b, skip, release, result.
  - 네이티브·폴백 모두 RESULT ok=true.
  - 위치: `…/scratchpad/skills/final/{native,fallback}/`.

**검증**
- unit 27파일 fails=0. e2e 3파일 fails=0(e2e_1_1 · e2e_skills · e2e_touch_skills). integration fails=0.
- `native-check.sh` GREEN(ext·import·t0·shot·jam·e2e, 스킬 샷 포함).
- iOS export dry-run exit 0(12 s, 441 MB 폴더, `lane1.pck` 11.5 MB).
  - pck에 skills_sim·skill_cues·sk_*/fin_* wav가 들어가고 tests/는 빠진다.
  - 경고는 기존 것뿐이다(boot_splash 속성, .ipa는 macOS 전용).
- Mac 빌드·설치·실행·기능 확인은 각각 ❓다. 이 컨테이너는 Mac에 닿지 않는다.

**알려진 차이 · 결정 필요 ❓**
- t5 임팩트의 흰 플래시(config.skills.fx.t5.flash α 0.85)가 2–3프레임 화면을 덮는다(샷 15). α 0.6–0.65 후보, 기기에서 판정.
- 점프·드론을 쓰면 스킬 피해가 원흉 HP의 36–58 %라 '50 % 이하' 지침을 넘는 판이 있다. 기기 체감으로 dmgIn이나 hpMul을 정한다.
- 폴백에는 잔챙이(mini)가 없다. iPhone 정체에서 드론은 장애물만 치우고, 압정은 `fire_dry`만 낸다.
- 1-5 폴백 autopilot이 정체에 갇힌다. 이번 변경 전부터 있던 문제다(sim 담당 보고). iPhone 1-5에서 확인이 필요하다.
- 원흉전 화면이 붐빈다. 차 위 말풍선이 HUD 범퍼 줄 밑에 깔린다(Bubbles는 옆으로만 피한다).
- shop.json의 점프·드론 설명('쿨 4초', '원흉에 자동 사격')이 원흉전 동작(쿨 6 s, 패시브 사격은 정체 잔챙이만)과 다르다. 문구 수정은 상점 담당.

### 2026-10-14 (3) — 리뷰(rvA 적대 검증 · rvB 연출) 반영
가설: ✅ 남은 막힘은 sim·데이터·뷰만 고쳐서 풀린다. ① 정체 점프의 빌런 관통 · 폴백 점프 겹침, ④ 폴백 + 아이템에서 MAX 미도달, 처형 프레임 백화 · 숫자 겹침이다. 네이티브와 폴백이 모두 그린이다. 상세 값은 SKILLS.md §0-1에 있다.

- 정체 점프: `GameSim.jam_hop`이 시전 때 착지 칸을 고르고 `PlayerSim.glide`로 그 칸에 내린다. 빌런은 넘지 않는다(`blocked`).
  - 폴백 `_Creep`은 플레이어를 중심 기준 리더로 본다. 플레이어나 밀린 차와 겹친 차는 14 m/s로 뒤로 물러난다.
  - `TrafficBridge.makes_room()`이 참이면(폴백) 짧은 칸(1.2 m)도 쓴다. 네이티브는 차 + 0.7 m 칸만 쓴다(C++ 무변경).
- `rageGain.lock` 0.2 → 0.3이다. `Autopilot.policy = "max_exec"`와 `tests/test_e2e_economy.gd`(폴백 + 점프·드론, 충전 없음, 10 seed)를 추가했다.
- 1-2 지그 빌런: 플레이어 몸 쪽으로 옆걸음하면 그 틱은 멈춘다(`boss_sim.gd`). `test_collide`에 stage 2 zig 케이스를 넣었다. 수정 전 84–86틱 겹침, 수정 후 0이다.
- 3손가락 개발 패널은 빈 화면 손가락 3개가 0.3 s 안에 닿아야 열린다(`lane_input.gd`). Debug 빌드 설정에 `테스트: 아이템 체험`(`dev_items`, App._loadout)을 넣었다.
- 연출: t5 · kill 플래시를 약하게 하고 처치 틱에는 1회만 낸다. 숫자는 표시만 ×10이고, 비켜 쌓이며 화면 안에 머물고 처치 때 지워진다. 분노 t1 얼굴은 `충격파`, 압정과 간격 44 u, 존 grow 0이다.
  - 배너 0.20, 아이템 시전 배너, 점프 체공 연출을 넣었다. t3 압정 18개를 밝은 재질로 바꾸고 첫 타 소리를 붙였다. 로켓 피니시 샷을 넓혔다. 정체 표지판에 글자를 넣었다(Label3D).
- 반려 · 보류: SkillFx 셰이더 예열(rvA minor)은 보류했다. lavapipe에서도 강제 정지 없는 비동기 컴파일이고, Metal은 파이프라인 캐시 동작이 달라 기기 프레임 시간을 먼저 본다. 원흉전 잠금 뒤 플레이어–NPC 겹침(boss 모드는 NPC를 안 본다)도 범위 밖이다.
- 검증:
  - unit 27파일 fails=0.
  - e2e 4파일 fails=0. `e2e_economy`는 폴백 + 아이템에서 10/10 처형, 원흉전 14.0–15.5 s다.
  - integration fails=0. `native-check.sh` GREEN.
  - iOS export dry-run exit 0(12.7 s, `lane1.pck` 11.5 MB, tests 제외, 기존 경고만).
  - 샷 네이티브·폴백 RESULT ok=true. t5 임팩트 프레임 휘도 표준편차는 51.7 / 49.2다(이전 19.6).
  - Mac 빌드·설치·실행·기능 확인은 각각 ❓다.
