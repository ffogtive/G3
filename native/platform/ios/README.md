# native/platform/ios — IOSHaptics (Core Haptics + thermal state) GDExtension

가설:
- ✅ (컨테이너) Godot 4.7.2의 **C GDExtension 인터페이스만으로**(godot-cpp 없이) RefCounted 클래스 `IOSHaptics`를
  등록할 수 있다. Linux null 백엔드로 바인딩(call/ptrcall, float·int·bool·String, 수명)을 53개 검사(PASS 53, FAIL 0)로 확인했다.
- ❓ (Mac·실기기 미검증) iOS에서는 CHHapticEngine 1개를 상주시키고 AHAP 패턴을 미리 파싱해 두면, 엔진 기본
  `Input.vibrate_handheld`(호출마다 엔진·패턴 생성, continuous+intensity만)보다 첫 햅틱 지연이 짧고
  transient·sharpness가 표현된다. 판정은 M1a 실기기 체감.

## 파일

| 파일 | 내용 |
|---|---|
| `haptics.gdextension` | manifest. `entry_symbol = lane1_haptics_init`, `compatibility_minimum = "4.7"`, 라이브러리 3개(linux .so / macos .dylib / ios .xcframework) |
| `src/haptics_gdextension.cpp` | C 인터페이스 바인딩(클래스 등록, 메서드 call/ptrcall 래퍼) |
| `src/haptics_core.{h,cpp}` | 플랫폼 무관 로직: 값 클램프, 호출 통계, `debug_state()` JSON |
| `src/haptics_backend.h` | 백엔드 인터페이스 |
| `src/haptics_backend_ios.mm` | iOS: CHHapticEngine 수명주기, transient/continuous/AHAP, UIKit feedback generator, NSProcessInfo thermalState·저전력 모드 |
| `src/haptics_backend_null.cpp` | 호스트(Linux 테스트, macOS 에디터): 호출만 센다 |
| `tests/test_haptics.gd`, `tests/run.gd` | T0 테스트(바인딩 + `autoload/haptics.gd` 라우팅) |
| `icon_1024.png` | iOS 앱 아이콘 placeholder (`tools/mac/make_placeholder_icon.py`) |
| `bin/`, `build/` | 빌드 산출물 (gitignore) |

## API (GDScript에서는 `autoload/haptics.gd`의 `Haptics.haptic("horn")`만 쓴다)

```
backend_name() -> String            # "corehaptics" | "null"
is_supported() -> bool              # CHHapticEngine.capabilitiesForHardware.supportsHaptics
start() -> bool / stop() / prepare()
transient(intensity, sharpness) -> bool
continuous(intensity, sharpness, duration_s) -> bool
register_pattern(name, ahap_json) -> bool / play_registered(name) -> bool / play_pattern(ahap_json) -> bool
selection() / impact(style 0..4, intensity)       # UISelectionFeedbackGenerator / UIImpactFeedbackGenerator
thermal_state() -> String           # "nominal" | "fair" | "serious" | "critical" ("unknown" on host)
is_low_power_mode() -> bool / thermal_change_count() -> int
debug_state() -> String (JSON) / build_info() -> String
```

수명주기(Apple "Preparing your app to play haptics", `CHHapticEngine.resetHandler`/`stoppedHandler`):
`start()`는 엔진을 한 번 만들고(autoShutdown 끔) 켜 둔다 → `stoppedHandler`는 멈춤 표시만, 다음 재생 때 다시 켬 →
`resetHandler`(햅틱 서버 재시작)는 원하는 상태면 재시작(플레이어는 버리고 등록 패턴은 유지) → 백그라운드 진입 시
정지, 포그라운드/활성화 시 재시작 → `NSProcessInfoThermalStateDidChangeNotification`으로 변화 횟수를 센다.
`autoload/haptics.gd`는 모바일에서 10초마다 `THERMAL t=… state=… low_power=… fps=…` 줄을 남긴다(NATIVE_PORT 2, 발열 행).

## 왜 godot-cpp가 아닌가

- iOS는 확장을 **정적 링크**한다. traffic(godot-cpp)과 같은 godot-cpp xcframework를 두 manifest에 적으면 Godot
  4.7.2 iOS export가 PBX 참조를 중복으로 넣고, 안 적으면 haptics가 traffic의 의존성에 기대게 된다(컨테이너 재현).
- C 인터페이스만 쓰면 이 모듈은 traffic 빌드가 실패해도 **단독으로 링크된다** — `ios_run.sh`의 "ext가 실패해도
  게임은 뜬다" 요구.
- 헤더는 고정 엔진에서 뽑는다: `godot47 --headless --dump-gdextension-interface` (build_ios_ext.sh가 자동).

## 빌드

```bash
bash tools/mac/build_ios_ext.sh --host     # Linux: bin/liblane1_haptics.linux.x86_64.so (컨테이너 테스트)
                                           # macOS: bin/liblane1_haptics.macos.dylib (Mac 에디터가 export할 때 로드)
bash tools/mac/build_ios_ext.sh            # Mac: + bin/liblane1_haptics.ios.xcframework (xcrun clang++ -arch arm64,
                                           #      libtool -static, xcodebuild -create-xcframework) ❓
```

- iOS 최소 버전 15.0 = export preset `application/min_ios_version` (Godot 4.7.2 기본값, Xcode 27 배포 대상 15–27 ✅).
- CoreHaptics·UIKit·Foundation은 `-framework`를 따로 주지 않는다: Godot 템플릿의 libgodot.a가 autolink 한다(4.7.2 템플릿 확인).
- iOS 빌드가 실패하면 build_ios_ext.sh가 빈 xcframework(stub)를 둔다. 생성된 Xcode 프로젝트는 진입 심볼을
  `-Wl,-U,_lane1_haptics_init`로 약하게 참조하므로 링크되고, `Haptics` autoload는 `Input.vibrate_handheld`로 내려간다.

## 테스트 (컨테이너, ✅ 53 PASS)

```bash
bash tools/mac/build_ios_ext.sh --host
godot47 --headless --path native --import          # .godot/extension_list.cfg 에 manifest 등록
godot47 --headless --path native -s res://platform/ios/tests/run.gd
```

`test_haptics.gd`는 `native/tests/run_tests.gd` 규약(run() -> int)을 따른다. gate 소유자가 `native/tests/`로 옮기면
`run_tests.gd`가 자동으로 집는다.
