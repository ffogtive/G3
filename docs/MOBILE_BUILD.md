# MOBILE_BUILD — Godot 4.7.2 네이티브 빌드: 내 iPhone 설치 → (나중에) TestFlight/App Store · Android

가설:
- ❓ (M1) iPhone을 Mac에 꽂고 Xcode에 Apple ID로 한 번 로그인해 두면(무료 Personal Team 가능, 7일 프로비저닝)
  `tools/mac/ios_run.sh` **명령 하나로 10분 안에** 게임이 iPhone에서 뜬다. — 컨테이너에서 export·스크립트 흐름은 ✅,
  Mac·실기기는 미검증.
- ❓ (M2) Core Haptics(transient+continuous+sharpness)와 thermalState 로그는 작은 ObjC++ GDExtension
  (`native/platform/ios`, C 인터페이스)으로 Godot에 붙는다. — 바인딩은 컨테이너 null 백엔드로 ✅(53 PASS),
  Core Haptics 호출부는 Mac 빌드 전 ❓.
- ❓ Godot 4.7.2 iOS 템플릿은 Xcode 27.x에서도 빌드된다: Xcode 27이 ld64·`-ld_classic`을 없앴지만 템플릿은
  `-ld_classic`을 Xcode 15.0–15.1에서만 붙인다(생성된 project.pbxproj 확인 ✅). 실제 링크는 Mac 첫 빌드에서 판정.

> 기준일 2026-10-13. 엔진은 **Godot 4.7.2-stable**(컨테이너 `godot47`와 동일, docs/NATIVE_PORT.md 1-2).
> 웹판(`game/`)은 동결(SHA `753549a`), Flutter 셸(`app/`)은 부록 A에 그대로 남긴다.
> 표기: ✅ 확인(공식 문서·컨테이너 실행) · ❓ Mac/실기기 미검증 또는 2차 출처 · ❌ 기각

## 아침에 할 일 (5단계)

1. **Mac 준비 확인** — Xcode 27.x가 열리고, `Xcode > Settings… > Apple Accounts`에 Apple ID가 로그인돼 있는지
   본다. 처음이면 `tools/mac/SIGNING.md` 1~2단계(10분).
2. **iPhone 연결** — 케이블로 꽂고 잠금 해제 → "이 컴퓨터 신뢰" → 개발자 모드 켜기(SIGNING.md 3~4단계).
3. **받기** — `cd <G3> && git pull`
4. **실행** — `tools/mac/ios_run.sh` (점검만: `--check`). 첫 실행은 Godot 4.7.2 + 템플릿 1.3 GB를 받아
   SHA-512를 확인한다. 끝에 `build / install / launch` 결과와 소요 시간이 따로 찍힌다.
5. **결과 보내기** — 실패하면 마지막 화면 + `.local/deploy-runs/<최신>/receipt.txt`를 보내 준다
   (Team ID·UDID는 출력에서 `AB******YZ`로 가려져 있다). 실행이 "신뢰하지 않는 개발자"로 막히면
   iPhone `설정 > 일반 > VPN 및 기기 관리 > 개발자 앱 > 신뢰` 후 `tools/mac/ios_run.sh --launch-only`.

---

## 0) 요약 (가설 대비)

| 질문 | 결론 | 근거 |
|---|---|---|
| Mac에서 명령 1개로 설치·실행? | `tools/mac/ios_run.sh` — 확장 빌드 → Godot export(Xcode 프로젝트) → xcodebuild(자동 서명) → codesign·Bundle ID 검증 → devicectl 설치 → 실행 ❓ | 사용자 검증 가이드 §5 메커니즘 그대로 (docs/IPHONE_DEPLOY.md) |
| 무료 Apple ID로 되나? | ✅ Personal Team: 7일 만료, 기기당 앱 3개, 7일에 App ID 10개 | [Choosing a Membership](https://developer.apple.com/support/compare-memberships/) |
| Xcode / macOS | **Xcode 27.x**, macOS Tahoe 26.6+. 배포 대상 iOS 15–27, 기기 개발 실행은 **iOS 17+** ✅ | [Xcode Support](https://developer.apple.com/support/xcode/), [Xcode 27 RN](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes) |
| Godot 4.7.2 ↔ Xcode 27 | ❓ 공식 호환표 없음. 알려진 위험 1개(ld64 제거)는 템플릿이 피해 감 ✅, 나머지는 첫 빌드로 판정 | 아래 7절 |
| 최소 iOS / 기기 | `min_ios_version = 15.0`(Godot 4.7.2 기본값) + `capabilities/performance_a12 = true` → A12(iPhone XS)+ | Godot 4.7.2 소스 `platform/ios/export/export_plugin.h` (`get_minimum_deployment_target() == "15.0"`) ✅ |
| 120Hz ProMotion | 템플릿 Info.plist에 `CADisableMinimumFrameDurationOnPhone = true`가 이미 있다 ✅, 엔진은 `display/window/ios/allow_high_refresh_rate` 기본 true | 생성된 `lane1/lane1-Info.plist` ✅, docs/NATIVE_PORT.md 1-2 |
| 출시(TestFlight/App Store) | 유료 Apple Developer Program 필요(Personal Team은 App Store 서명 불가). 업로드는 Xcode 26+ / iOS 26 SDK | [QA1915](https://developer.apple.com/library/archive/qa/qa1915/_index.html), [Upcoming requirements](https://developer.apple.com/news/upcoming-requirements/) |

## 1) 준비물

| 항목 | 값 |
|---|---|
| Mac | Apple silicon 권장, macOS Tahoe 26.6 이상 (Xcode 27 요건 ✅) |
| Xcode | 27.x (App Store). iOS 플랫폼 구성요소 설치. `cmake`는 traffic 확장 빌드에만(없으면 경고 후 계속) |
| iPhone | iOS 17 이상(Xcode 27 개발 실행 하한 ✅), A12 이상, 개발자 모드 |
| Apple ID | 무료 가능. Xcode에 로그인만 하면 된다 — 비밀번호·2FA는 사용자가 직접 입력 |
| 디스크 | Godot 앱 ~0.2 GB + 템플릿 ~1.3 GB(`~/Library/Application Support/Godot/export_templates/4.7.2.stable`) + DerivedData |

## 2) Godot 4.7.2 + export 템플릿 (ios_run.sh가 자동 설치)

`ios_run.sh`는 `GODOT` → `~/.lane1/godot/4.7.2/Godot.app` → `/Applications/Godot.app` → PATH 순으로 찾고,
`--version`이 `4.7.2.stable`로 시작하는 것만 쓴다. 없으면 아래를 그대로 한다(수동으로 해도 같다):

```bash
REL=https://github.com/godotengine/godot/releases/download/4.7.2-stable
mkdir -p ~/.lane1/downloads ~/.lane1/godot/4.7.2 && cd ~/.lane1/downloads
curl -fLO "$REL/Godot_v4.7.2-stable_macos.universal.zip"
curl -fLO "$REL/Godot_v4.7.2-stable_export_templates.tpz"
curl -fLO "$REL/SHA512-SUMS.txt"
grep -E 'macos.universal.zip|_export_templates.tpz' SHA512-SUMS.txt | grep -v mono | shasum -a 512 -c -
ditto -x -k Godot_v4.7.2-stable_macos.universal.zip ~/.lane1/godot/4.7.2/
# .tpz = zip, 최상위 폴더 templates/  (에디터의 Editor > Manage Export Templates > Install from File과 같은 결과)
T="$HOME/Library/Application Support/Godot/export_templates/4.7.2.stable"
mkdir -p "$T" && unzip -q Godot_v4.7.2-stable_export_templates.tpz -d /tmp/tpz && cp -R /tmp/tpz/templates/. "$T/"
cat "$T/version.txt"   # 4.7.2.stable
```

- SHA-512(2026-10-13, 공식 `SHA512-SUMS.txt`에서 확인 ✅, `tools/mac/lib/common.sh`에 고정):
  - `Godot_v4.7.2-stable_macos.universal.zip` `38aa16e5…bac69ca`
  - `Godot_v4.7.2-stable_export_templates.tpz` `ca4d71c4…ccb84079`
- 에디터 데이터 경로(macOS) `~/Library/Application Support/Godot/` ✅ ([Godot docs: data paths](https://github.com/godotengine/godot-docs/blob/master/tutorials/io/data_paths.rst)),
  .tpz는 zip ✅ ([exporting projects](https://github.com/godotengine/godot-docs/blob/master/tutorials/export/exporting_projects.rst)).
  에디터를 self-contained 모드(`._sc_`)로 쓰면 템플릿은 `editor_data/` 아래로 간다 — 그 경우 `GODOT`를 지정하고 템플릿도 그쪽에 둔다.
- 릴리스: [4.7.2-stable on GitHub](https://github.com/godotengine/godot/releases/tag/4.7.2-stable) · [godotengine.org archive](https://godotengine.org/download/archive/4.7.2-stable/)

## 3) Export preset (`native/export_presets.cfg`)

옵션 이름은 4.7.2 소스(`platform/ios/export/export_plugin.cpp`, `editor/export/editor_export_platform_apple_embedded.cpp`)와
컨테이너 export로 확인했다 ✅.

| 옵션 | 값 | 이유 |
|---|---|---|
| `application/bundle_identifier` | `com.ffogtive.lane1Chamgyoyuk` | 고정(무료 팀 App ID 한도) |
| `application/app_store_team_id` | `LANE1TEAM0` (placeholder) | Godot는 빈 Team ID면 export를 거부한다. **공개 저장소라 실제 값 금지** → ios_run.sh가 생성된 pbxproj에만 실제 팀을 넣고 `DEVELOPMENT_TEAM=`으로도 넘긴다 |
| `application/code_sign_identity_*`, `provisioning_profile_*` | 빈 값 | 빈 값이면 Godot가 `CODE_SIGN_STYLE = Automatic`을 쓴다(소스 `CodeSigningDetails`) ✅ |
| `application/export_project_only` | `true` | Godot는 Xcode 프로젝트만 만들고 빌드·설치는 스크립트가(가이드 §5) |
| `application/min_ios_version` | `15.0` | 4.7.2 기본값, Metal은 14+ 필요 |
| `application/targeted_device_family` | `0` (iPhone) | 세로 폰 게임. 0→`TARGETED_DEVICE_FAMILY "1"` ✅ |
| `capabilities/performance_a12` | `true` | A12 하한 (UIRequiredDeviceCapabilities에 `iphone-ipad-minimum-performance-a12`) ✅ |
| `shader_baker/enabled` | `true` | NATIVE_PORT 3-1 "모바일 preset은 셰이더 베이커 켬". Metal 셰이더 bake는 Mac export에서만 ❓ |
| `icons/icon_1024x1024` | `res://platform/ios/icon_1024.png` | placeholder |
| include / exclude | `data/*.json` / `tests/*, tools/*, data/src/*, platform/ios/tests/*, *.md` | pck에 `data/*.json` 포함, 테스트·도구 제외 확인 ✅ |

Android(M2 placeholder, 키스토어는 저장소 밖), Linux(컨테이너 스모크)도 같은 파일에 있다.

## 4) 한 줄 실행: `tools/mac/ios_run.sh`

```
tools/mac/ios_run.sh [--release] [--clean] [--device <UDID|이름>] [--no-ext] [--launch-only] [--check] [--yes]
```

| 단계 | 하는 일 | 실패하면 |
|---|---|---|
| preflight | `xcode-select -p`(CommandLineTools면 중단), `xcodebuild -version ≥ 16`(27 기대), `-checkFirstLaunchStatus`, iOS SDK, devicectl, python3 | 고칠 명령을 그대로 출력, exit 3 |
| device | `xcrun devicectl list devices --json-output` → 페어링된 iPhone 1대(여러 대면 1회 질문, `--device`로 지정). `developerModeStatus`가 `disabled`면 켜는 법 출력 | exit 5 |
| team | `LANE1_TEAM_ID` → `~/.lane1/deploy.env` → 키체인 `Apple Development` 인증서의 **OU**(+ Xcode 계정 defaults) | 여러 개면 1회 질문 후 deploy.env(600)에 저장 |
| godot | 4.7.2 앱·템플릿 확인/설치(SHA-512 검증) | exit 3 |
| extensions | `tools/mac/build_ios_ext.sh`: haptics(xcrun clang++ → xcframework) + traffic(cmake -G Xcode) | **경고만 하고 계속**(빈 stub xcframework → 게임은 그 클래스 없이 뜬다) |
| export | `Godot --headless --path native --import` → `--export-debug iOS .local/ios-export/debug/lane1.xcodeproj` → pbxproj의 `LANE1TEAM0`를 실제 팀으로 치환 | exit 4 |
| build | `xcodebuild -project … -scheme lane1 -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath .local/iphone-deploy -allowProvisioningUpdates -allowProvisioningDeviceRegistration DEVELOPMENT_TEAM=… CODE_SIGN_STYLE=Automatic CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES build` (프로파일에 기기가 없다는 오류면 `-destination id=<UDID>`로 1회 재시도) → `test -d` → `codesign --verify --deep --strict` → `PlistBuddy CFBundleIdentifier == com.ffogtive.lane1Chamgyoyuk` | errSecInternalComponent → 로그인된 Terminal에서 실행 안내, exit 4 |
| install | `xcrun devicectl device install app --device … lane1.app --json-output install.json` (기존 앱 삭제 없음) | exit 6 |
| launch | `xcrun devicectl device process launch --device … --terminate-existing com.ffogtive.lane1Chamgyoyuk --json-output launch.json` | "신뢰하지 않는 개발자" 안내, exit 7 (설치 성공은 따로 표시) |

- 실행마다 `.local/deploy-runs/<YYYYmmdd-HHMMSS>-<pid>/`: `build.log export.log ext.log install.json launch.json
  devices.json receipt.txt exit-code`(EXIT trap). 동시 실행은 `.local/iphone-deploy.lock`(mkdir)으로 막고, **남은
  잠금을 자동으로 지우지 않는다**(owner 파일의 pid 확인 후 사람이 지움).
- `--release`: `--export-release` + Xcode Release + `CODE_SIGN_IDENTITY="Apple Development"`(여전히 개발 서명).
- 무인 실행(`--yes`/러너): 질문 없이, 모호하면 목록과 함께 실패한다.

## 5) 손으로 하는 경로 (스크립트가 막힐 때)

```bash
G=~/.lane1/godot/4.7.2/Godot.app/Contents/MacOS/Godot
bash tools/mac/build_ios_ext.sh                      # 실패해도 stub이 남는다
"$G" --headless --path native --import
"$G" --headless --path native --export-debug iOS "$PWD/.local/ios-export/debug/lane1.xcodeproj"
open .local/ios-export/debug/lane1.xcodeproj         # Signing & Capabilities > Team 선택 > iPhone 선택 > ⌘R
```

Xcode에서 한 번 Run하면 기기 등록·프로파일 생성이 확실히 되므로, 그다음부터 `ios_run.sh`가 그대로 쓴다.

## 6) iOS 확장 (GDExtension)

| 확장 | 경로 | 빌드 | 실패 시 |
|---|---|---|---|
| IOSHaptics (Core Haptics + thermalState) | `native/platform/ios` (C 인터페이스, godot-cpp 없음) | `xcrun clang++ -arch arm64` → `libtool -static` → `xcodebuild -create-xcframework` | stub → `Haptics`가 `Input.vibrate_handheld`로 폴백 |
| traffic (C++ 교통 코어) | `native/ext` (godot-cpp, gate 소유) | `cmake -G Xcode -DCMAKE_SYSTEM_NAME=iOS` (native/ext/README.md) | stub → 경고. 그 클래스를 쓰는 씬은 동작 안 함 |

- 생성된 Xcode 프로젝트는 두 진입 심볼을 `-Wl,-U,_traffic_library_init -Wl,-U,_lane1_haptics_init`로 약하게 참조한다
  (컨테이너 export로 확인 ✅) — stub이어도 링크된다.
- `Haptics` autoload(`native/autoload/haptics.gd`): `haptic("horn")`이 `data/haptics.json`을 읽어 IOSHaptics →
  `Input.vibrate_handheld(ms, amp)` → no-op 순으로 고른다. `thermal_state()`는 모듈이 없으면 `"unknown"`.
  autoload 등록(`project.godot`)은 gate 소유자 몫: 순서 DB SaveGame InputBuffer Audio **Haptics** Fx UI.

## 7) Godot 4.7.2 × Xcode 27.x 호환성 ❓

| 점검 | 결과 |
|---|---|
| 공식 호환표 | ❓ Godot 문서는 Xcode 최소 버전을 적지 않는다 ([exporting_for_ios.rst](https://github.com/godotengine/godot-docs/blob/master/tutorials/export/exporting_for_ios.rst)). 4.7.2 릴리스 소식에도 iOS 항목 없음(2차 출처 검색) |
| ld64 제거 (Xcode 27: "The ld64 linker has been removed and the `-ld_classic` option is no longer supported") | ✅ 템플릿은 `LD_CLASSIC_1500/1501/1510`만 정의 → Xcode 27에서는 빈 값. 새 링커의 `-U` 지원은 ❓ |
| 배포 대상 | ✅ Xcode 27 iOS 배포 대상 15–27, 우리 15.0 |
| 기기 | ✅ Xcode 27 개발 실행 iOS 17+ — 그 이하 iPhone이면 ios_run.sh가 경고 |
| libc++ 변경(Xcode 27: `bitset::operator[]`, map/set 알고리즘) | ❓ traffic·haptics는 해당 API 미사용(소스 검색), libgodot.a는 템플릿 빌드 시점 툴체인 |
| devicectl JSON v5 (`hardwareProperties` 등 deprecated → `properties`) | ✅ 대응: ios_run.sh가 두 형식 모두 읽는다(모의 JSON 2종 테스트) |
| 4.6.2 + Xcode 26.4 "failed to launch" 포럼 보고 | ❓ 답 미확인 ([forum](https://forum.godotengine.org/t/godot-4-6-2-xcode-26-4-physical-ios-device-launch-fails/138380)) — 실패하면 launch.log를 보고 판단 |

## 8) 자주 나는 오류

| 증상 | 처리 |
|---|---|
| `xcode-select … CommandLineTools` | `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` ✅ ([Godot iOS docs](https://github.com/godotengine/godot-docs/blob/master/tutorials/export/exporting_for_ios.rst)) |
| `errSecInternalComponent` | SSH가 아니라 **로그인된 Mac의 Terminal**에서 실행, 키체인 창에서 "항상 허용" (docs/IPHONE_DEPLOY.md §6) |
| `No Account for Team` / `requires a development team` | Xcode > Settings > Apple Accounts 로그인 (SIGNING.md 2단계) |
| 프로파일에 기기 없음 | 스크립트가 `-destination id=<UDID>`로 1회 재시도. 그래도 안 되면 5)처럼 Xcode에서 한 번 Run |
| 설치는 됐는데 실행 실패 | 개발자 신뢰(설정 > 일반 > VPN 및 기기 관리) 또는 잠금 해제 → `--launch-only`. **설치 성공은 유지해서 보고** |
| 7일 뒤 앱이 안 열림 | 무료 프로파일 만료 → `ios_run.sh` 다시 (앱 삭제 금지, 데이터 유지) |
| `maximum App ID limit` | 7일에 App ID 10개 한도. Bundle ID를 바꾸지 않는다 |
| 화면이 비어 있음 | `native/project.godot`에 `run/main_scene`이 아직 없다(ios_run.sh가 경고) — gate 산출물 대기 |

## 9) 컨테이너에서 확인한 것 ✅ / 못 한 것 ❓

✅ (Linux, Godot 4.7.2 + 공식 템플릿)
- `bash tools/mac/build_ios_ext.sh --container-stubs && godot47 --headless --path native --export-debug iOS <dir>/lane1.xcodeproj`
  → 17 s, exit 0. scheme `lane1`, `PRODUCT_NAME lane1`, `PRODUCT_BUNDLE_IDENTIFIER com.ffogtive.lane1Chamgyoyuk`,
  `CODE_SIGN_STYLE Automatic`, `IPHONEOS_DEPLOYMENT_TARGET 15.0`, `TARGETED_DEVICE_FAMILY "1"`, A12 capability,
  `CADisableMinimumFrameDurationOnPhone`, 확장 xcframework 3개 참조 + `-Wl,-U` 약한 참조.
- `ios_run.sh`를 가짜 macOS 도구(uname/xcodebuild/xcrun/security/codesign/PlistBuddy 모의)로 끝까지 실행: 정상 경로
  exit 0, 개발자 모드 꺼짐 exit 5, 신뢰 실패 exit 7(설치 ok 표시), errSecInternalComponent exit 4, 기기 없는 프로파일 →
  `id=` 재시도 성공, Bundle ID 불일치 exit 4(설치 안 함), 잠금 존재 exit 9(잠금 유지), `--check`, `--launch-only`.
  xcodebuild·devicectl 인자는 가이드 §5와 글자 그대로 일치. `shellcheck` 0건.
- IOSHaptics 호스트 빌드 + 53개 테스트 PASS.

❓ (Mac·실기기에서만)
- 실제 xcodebuild 서명·링크(Xcode 27 새 링커), Core Haptics 체감, Metal shader baker, 120Hz, 발열 로그, 10분 목표.
- devicectl JSON v5의 `properties` 실제 키 이름(재귀 탐색으로 대응), Xcode 계정 defaults 키 이름.

## 10) 출시 로드맵 · Android

- **TestFlight/App Store**: 유료 Apple Developer Program(연 99 USD) 가입 → 같은 Bundle ID로 App Store Connect 앱 생성 →
  `--release` export를 Xcode Organizer에서 Archive·업로드(Xcode 26+ / iOS 26 SDK 요건 ✅
  [Upcoming requirements](https://developer.apple.com/news/upcoming-requirements/)). 4.2(최소 기능) 체크리스트는 부록 A의
  "App Store 4.2 대응 체크리스트"가 그대로 유효하다(네이티브라 웹뷰 리스크는 사라짐).
- **Android (M2)**: `export_presets.cfg`의 Android preset은 placeholder. OpenJDK 17 + Android SDK, 키스토어는 저장소
  밖. 컨테이너는 dl.google.com 차단으로 Gradle 불가(NATIVE_PORT 6).

## 출처 (본문)

- Xcode 27 Release Notes — https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes
- Xcode 27.2 beta 2 Release Notes — https://developer.apple.com/documentation/xcode-release-notes/xcode-27_2-release-notes
- Xcode Support (배포 대상·기기 범위) — https://developer.apple.com/support/xcode/
- Running your app on simulated or physical devices — https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices
- Device Hub — https://developer.apple.com/documentation/xcode/managing-your-simulated-and-physical-devices-in-device-hub
- Enabling Developer Mode — https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device
- Team ID는 인증서 OU (Apple DTS) — https://developer.apple.com/forums/thread/802517
- 신뢰 설정 경로 — https://support.apple.com/118254 , https://developer.apple.com/forums/thread/685271
- devicectl `--terminate-existing` / `--console` (포럼·2차) — https://developer.apple.com/forums/thread/756393 , https://github.com/appium/node-devicectl
- xcodebuild `-allowProvisioningUpdates` + `DEVELOPMENT_TEAM` (2차) — https://docs.fastlane.tools/codesigning/xcode-project/
- Godot iOS export — https://github.com/godotengine/godot-docs/blob/master/tutorials/export/exporting_for_ios.rst
- Godot exporting projects (CLI, .tpz) — https://github.com/godotengine/godot-docs/blob/master/tutorials/export/exporting_projects.rst
- Godot data paths — https://github.com/godotengine/godot-docs/blob/master/tutorials/io/data_paths.rst
- Godot 4.7.2 release — https://github.com/godotengine/godot/releases/tag/4.7.2-stable , https://godotengine.org/article/maintenance-release-godot-4-7-2/
- Godot 4.7.2 소스(iOS export) — https://github.com/godotengine/godot/blob/4.7.2-stable/platform/ios/export/export_plugin.cpp , https://github.com/godotengine/godot/blob/4.7.2-stable/editor/export/editor_export_platform_apple_embedded.cpp
- GitHub self-hosted runner 보안 — https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/about-self-hosted-runners
- 사용자 배포 가이드(익명화 적용본) — docs/IPHONE_DEPLOY.md

---

## 부록 A. (구) Flutter + WebView 셸 경로 (`app/`) — 원문 보존

> 2026-10-13 이전 문서를 그대로 옮겼다. 웹판 동결(`753549a`) 이후 기본 경로는 위의 Godot 네이티브다.
> 아래 절 번호·"가설"은 그 당시 것이다. 출처 목록은 이 부록 끝에 있다.

가설:
- ❓ 무료 Apple ID(Personal Team)와 Mac + Xcode만 있으면 `app/`(Flutter + flutter_inappwebview 셸)을 내 아이폰에 설치할 수 있다. 단, **7일마다 Xcode에서 다시 설치**해야 한다. (근거 문서는 ✅ 확인했고, 실기기 설치는 아직 미검증)
- ❓ 출시하려면 Apple Developer Program(연 99달러)이 필요하다. **게임을 앱 번들에 내장해 완전 오프라인으로 돌리고, 네이티브 기능(햅틱·Game Center 등)을 몇 개 붙이면** 4.2(Minimum Functionality) 리젝 위험을 크게 낮출 수 있다.

> 기준일: 2026-10-13. 버전·가격·정책은 자주 바뀐다. 각 항목 옆 출처 링크로 최신 상태를 다시 확인할 것.
> 표기: ✅ 공식 문서로 확인 · ❓ 2차 출처뿐이거나 실기기 미검증 · ❌ 기각

---

### 0) 핵심 요약 (가설 대비)

| 질문 | 결론 | 근거 |
|---|---|---|
| 무료 Apple ID로 내 아이폰에 설치할 수 있나? | ✅ 가능. 단 App ID 10개(7일 만료), 기기 3대(7일 만료), **기기당 앱 3개**, 프로비저닝 7일 만료 | [Apple: Choosing a Membership](https://developer.apple.com/support/compare-memberships/) |
| 무료 Apple ID로 App Store/TestFlight에 올릴 수 있나? | ❌ 불가. Personal Team은 App Store용 서명을 할 수 없다 | [Apple QA1915](https://developer.apple.com/library/archive/qa/qa1915/_index.html) |
| 출시 비용 | Apple 연 **99 USD**(한국 약 ₩129,000 ❓), Google Play **1회 25 USD** | [Apple Enroll](https://developer.apple.com/programs/enroll/), [Play Console Help](https://support.google.com/googleplay/android-developer/answer/6112435?hl=en) |
| 현재 Flutter stable | **3.47.7** (2026-10-08, Dart 3.13.5). `app/`도 이 버전으로 생성됨 | [releases_macos.json](https://storage.googleapis.com/flutter_infra_release/releases/releases_macos.json) |
| Flutter 최소 iOS | **iOS 15** (3.47에서 13 → 15로 상향) | [Supported platforms](https://docs.flutter.dev/reference/supported-platforms), [What's new in 3.47](https://flutter.dev/blog/whats-new-in-flutter-3-47) |
| Xcode 최소 버전 | `flutter doctor`의 하한은 Xcode 15(권장 16)지만, **실제로는 Xcode 26 이상 필수** (App Store 업로드 요건: 2026-04-28부터 Xcode 26 + iOS 26 SDK) | [flutter_tools xcode.dart](https://github.com/flutter/flutter/blob/stable/packages/flutter_tools/lib/src/macos/xcode.dart), [Apple Upcoming Requirements](https://developer.apple.com/news/upcoming-requirements/) |
| CocoaPods 필요한가? | **이 프로젝트는 불필요** (소스로 ✅, Mac 실빌드는 ❓). Flutter 3.47 stable은 SwiftPM이 기본값이고(Xcode 15 이상일 때), 모든 플러그인이 SwiftPM을 지원하면 Podfile을 만들지 않고 `pod install`도 건너뛴다. `app/`의 유일한 iOS 플러그인 `flutter_inappwebview_ios 1.2.0-beta.3`은 `Package.swift`를 포함한다. 그래서 `ios/Podfile`이 없는 게 정상이다. SwiftPM 미지원 플러그인을 나중에 추가할 때만 필요하다 | [Flutter SwiftPM 문서](https://docs.flutter.dev/packages-and-plugins/swift-package-manager/for-app-developers), flutter_tools 3.47.7 소스(`features.dart`의 `swiftPackageManager` stable 기본 활성, `macos/darwin_dependency_management.dart`) |

---

### 1) 준비물

| 항목 | 요구사항 | 비고 |
|---|---|---|
| Mac | **Apple silicon 권장**. Flutter가 Intel Mac 지원을 단계적으로 중단하는 중이다 ([Flutter 수동 설치 문서](https://docs.flutter.dev/install/manual)) | Xcode 27은 Apple silicon 전용이라는 보도가 있음 ❓ ([2차 출처](https://blakecrosley.com/blog/xcode-27-release)) |
| macOS | Xcode 27.x → **macOS Tahoe 26.6 이상**, Xcode 26.4.1~26.6 → Tahoe 26.2 이상, Xcode 26.0~26.3 → Sequoia 15.6 이상 | ✅ [Xcode system requirements](https://developer.apple.com/xcode/system-requirements/) |
| Xcode | **26 이상**(App Store 업로드 요건). 아이폰이 iOS 27이면 **Xcode 27 권장** | Xcode 27의 기기 디버깅 지원 범위는 iOS 17 이상, Xcode 26은 iOS 15 이상 ✅ ([출처](https://developer.apple.com/xcode/system-requirements/)) |
| iPhone | **iOS 15 이상** (`app/`의 배포 타깃이 15.0), USB 케이블 | 무선 페어링은 iOS 27 이상에서만 가능하고, 그 미만은 케이블 필요 ✅ ([Device Hub 문서](https://developer.apple.com/documentation/xcode/managing-your-simulated-and-physical-devices-in-device-hub)) |
| Apple ID | 무료 계정으로 충분(개인 기기 설치용). 출시할 때는 유료 Developer Program 가입 | 2단계 인증 필수(유료 가입 시) |
| Node.js | 레포 루트의 `npm run build:app`용 | 게임 번들 빌드 |
| Flutter SDK | **3.47.x stable** (`app/`이 3.47.7, revision `abaf9c5`로 생성됨) | 버전이 다르면 `flutter upgrade` |
| (선택) Android | Android Studio + 실기기(USB 디버깅) | Google Play 출시 때 필요 |

---

### 2) 최초 1회 셋업 (Mac)

#### 2-1. Xcode
1. App Store에서 Xcode를 설치한다(최신 버전).
2. 터미널에서 다음을 실행한다. ✅ [Flutter: Set up iOS development](https://docs.flutter.dev/platform-integration/ios/setup)
```bash
# 커맨드라인 도구가 설치된 Xcode를 가리키게 하고 첫 실행 작업을 끝낸다
sudo sh -c 'xcode-select -s /Applications/Xcode.app/Contents/Developer && xcodebuild -runFirstLaunch'
# 라이선스 동의
sudo xcodebuild -license
# iOS 플랫폼 지원 + 시뮬레이터 런타임 다운로드
xcodebuild -downloadPlatform iOS
```

#### 2-2. Flutter SDK
```bash
# Apple silicon용 zip을 받아 ~/develop 에 풀기 (버전은 releases 페이지에서 최신 stable 확인)
mkdir -p ~/develop
curl -O https://storage.googleapis.com/flutter_infra_release/releases/stable/macos/flutter_macos_arm64_3.47.7-stable.zip
unzip flutter_macos_arm64_3.47.7-stable.zip -d ~/develop/
echo 'export PATH="$HOME/develop/flutter/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc

flutter --version     # 3.47.x stable 인지 확인
flutter doctor -v     # Xcode 항목이 [✓] 인지 확인 (CocoaPods 미설치 경고는 이 프로젝트에선 무시해도 됨 — 2-3 참고)
```
- zip 파일명과 경로는 [Flutter 수동 설치 문서](https://docs.flutter.dev/install/manual)와 [releases_macos.json](https://storage.googleapis.com/flutter_infra_release/releases/releases_macos.json)을 기준으로 했다. VS Code의 Flutter 확장으로 설치해도 된다.

#### 2-3. CocoaPods (선택 — 지금 `app/`에는 불필요)
- Flutter 3.44부터 **Swift Package Manager(SwiftPM)가 기본**이고, SwiftPM 미지원 플러그인만 CocoaPods로 폴백한다. CocoaPods 레지스트리(trunk)는 **2026-12-02부터 읽기 전용**이다. 기존 pod은 계속 쓸 수 있다. ✅ [Flutter SwiftPM](https://docs.flutter.dev/packages-and-plugins/swift-package-manager/for-app-developers), [CocoaPods blog](https://blog.cocoapods.org/CocoaPods-Specs-Repo/)
- `app/`이 쓰는 `flutter_inappwebview_ios 1.2.0-beta.3`은 SwiftPM을 지원한다(`ios/flutter_inappwebview_ios/Package.swift`, changelog "Add Swift Package Manager support"). flutter_tools 3.47.7 소스상 이 경우 Podfile 생성과 `pod install`을 건너뛴다. 그래서 **CocoaPods 없이 빌드된다**(소스 ✅ / Mac 실빌드 ❓). `flutter doctor`의 CocoaPods 경고(`[!]`)는 무시해도 된다.
- 대신 **첫 Xcode 빌드 때 SwiftPM이 github.com에서 `swift-collections`를 받는다**(플러그인 의존성). 인터넷이 연결된 상태에서 빌드한다.
- 나중에 SwiftPM 미지원 플러그인을 추가하면 Flutter가 `ios/Podfile`을 만들고 `pod install`을 돌린다. 그때만 아래처럼 설치한다.
```bash
# 공식 가이드 방식 (macOS 기본 Ruby, 설치할 때만 sudo)
sudo gem install cocoapods
# 또는 Homebrew를 쓴다면
brew install cocoapods

pod --version   # Flutter 도구 기준 최소 1.10.0, 권장 1.16.2 이상
```
- 출처: [CocoaPods Getting Started](https://guides.cocoapods.org/using/getting-started.html), [flutter_tools cocoapods.dart](https://github.com/flutter/flutter/blob/stable/packages/flutter_tools/lib/src/macos/cocoapods.dart) (최소/권장 버전 상수)

#### 2-4. 레포 받기
```bash
git clone <이 레포 URL> ~/G3 && cd ~/G3
git checkout claude/lane1-mockup
npm install
```

---

### 3) 게임 빌드 → 앱에 동기화

앱 폴더: `app/` (Flutter 프로젝트). 게임은 `dist/index.html`(약 1.3MB, 단일 파일)이다. 앱은 이 파일을 **앱 번들 에셋에 포함**하고, 앱 안의 로컬 HTTP 서버로 `http://localhost:28080/assets/web/index.html`을 띄운다.

```bash
cd ~/G3
npm run build:app     # = npm run build && node tools/sync-app.mjs
                      #   dist/index.html → app/assets/web/index.html 복사
```
- 경로 대응: `package.json`의 `build:app` → `tools/sync-app.mjs` → `app/assets/web/index.html` → `app/pubspec.yaml`의 `flutter: assets: - assets/web/` → `app/lib/src/local_asset_server.dart`가 `/assets/web/…`만 서빙(포트 28080).
- `app/assets/web/index.html`은 레포에 커밋돼 있다. 그래서 Node 없이도 바로 Xcode로 빌드할 수 있다. 다만 게임 최신본이라는 보장은 없으니, 가능하면 `npm run build:app`부터 한다.
- **게임을 고칠 때마다**: `npm run build:app` → 앱 다시 빌드(Run). Flutter 에셋은 빌드할 때 번들에 들어가므로, 앱을 다시 빌드하지 않으면 반영되지 않는다.
- **포트(28080)는 절대 바꾸지 않는다.** localStorage(세이브)는 origin(`http://localhost:28080`) 단위로 저장되므로 포트가 바뀌면 기존 세이브가 보이지 않는다. 28080이 사용 중이면 28081 → 28082 → 임의 포트로 대체하는데, 그 세션에서는 세이브가 분리된다.

---

### 4) 아이폰에 설치하기

#### 4-A. Xcode로 설치 (처음엔 이 방법 권장)

1. **Flutter 쪽 준비** (Xcode가 참조할 설정 파일을 생성한다)
   ```bash
   cd ~/G3/app
   flutter pub get
   flutter build ios --config-only     # Generated.xcconfig, SwiftPM 플러그인 패키지 등 Xcode 설정만 갱신 (빌드는 안 함)
   ```
   - `ios/Flutter/Generated.xcconfig`, `ios/Flutter/ephemeral/`는 git에서 제외된 생성물이다. clone 직후 이 단계를 건너뛰고 Xcode를 열면 `FlutterGeneratedPluginSwiftPackage`를 찾지 못한다. `--config-only`는 flutter_tools 3.47.7 `commands/build_ios.dart`에 있는 플래그다(✅ 소스 확인).
2. **워크스페이스 열기**: 반드시 `.xcworkspace`를 연다(`.xcodeproj` 아님).
   ```bash
   open ios/Runner.xcworkspace
   ```
3. **Apple ID 추가**: Xcode 27은 `Xcode > Settings > Apple Accounts`, Xcode 26은 `Xcode > Settings > Accounts`에서 `+` → Apple ID로 로그인한다. 무료 계정은 Team이 **"(Personal Team)"**으로 표시된다. ✅ [Apple: Running your app…](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices)
4. **서명 설정**: 왼쪽 내비게이터에서 `Runner` 프로젝트 → TARGETS `Runner` → **Signing & Capabilities**
   - `Automatically manage signing` 체크 (또는 "Set Up Signing" 버튼이 보이면 클릭)
   - **Team**: `내이름 (Personal Team)`
   - **Bundle Identifier**: 전 세계에서 고유해야 한다. 현재 기본값은 `com.ffogtive.lane1Chamgyoyuk`이고, 다른 팀이 이미 등록했으면 실패한다. 그럴 땐 `com.<내영문아이디>.lane1` 등으로 바꾼다.
   - ⚠️ 무료 계정은 **7일 동안 App ID 10개까지**만 등록할 수 있다. 번들 ID를 이것저것 바꾸면 금방 한도에 걸리니 하나로 정해 계속 쓴다.
   - 출시까지 생각하면 번들 ID는 이때 최종값으로 정하는 게 좋다(App Store Connect에 등록하면 바꿀 수 없다).
5. **아이폰 연결 + 개발자 모드**
   - USB로 연결 → 아이폰에 "이 컴퓨터를 신뢰하겠습니까?"가 뜨면 **신뢰**.
   - Xcode 27: 상단 실행 대상(run destination) 메뉴 → **Manage Devices…** → **Device Hub**에서 기기를 선택하고 **Pair**. (Xcode 26 이하: `Window > Devices and Simulators`) ✅ [Device Hub 문서](https://developer.apple.com/documentation/xcode/managing-your-simulated-and-physical-devices-in-device-hub)
   - 아이폰: **설정 > 개인정보 보호 및 보안 > (보안 섹션) 개발자 모드** 켜기 → 경고창에서 **재시동** → 재시동 후 확인창에서 위로 쓸어 올리고 **켜기(Enable)** → 암호 입력. 이 메뉴는 **Mac과 페어링을 시작한 뒤에야 나타난다.** ✅ [Apple: Enabling Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)
6. **Release 구성으로 바꾸기 (중요)**: `Product > Scheme > Edit Scheme… > Run > Info > Build Configuration = Release`
   - 이유: iOS 14 이상에서 Flutter **Debug 빌드는 홈 화면 아이콘으로 다시 실행할 수 없다**(JIT 제한). Mac 없이 들고 다니며 플레이하려면 Release(또는 Profile)로 설치해야 한다. ✅ [Flutter iOS 14 notes](https://flutter.cn/docs/development/ios-14), [Agora FAQ](https://docs.agora.io/en/api-reference/faq/quality/flutter_debug)
7. **실행 대상**에서 내 아이폰을 고르고 **Run(⌘R)**.
   - 처음에는 Xcode가 기기를 등록하고 프로비저닝 프로필을 만든다. "Register" 버튼이 보이면 누른다.
8. **"신뢰하지 않는 개발자(Untrusted Developer)"** 경고가 뜨면 아이폰에서
   **설정 > 일반 > VPN 및 기기 관리 > 개발자 앱 > (내 Apple ID) > 신뢰**. 신뢰하려면 인터넷 연결이 필요할 수 있다. 메뉴가 없으면 앱을 한 번 실행해 본 뒤 다시 확인한다. ✅ [Flutter iOS setup](https://docs.flutter.dev/platform-integration/ios/setup), [Apple HT204460](https://support.apple.com/en-us/HT204460) (iOS 18 이상은 버튼 이름이 "허용 및 재시동"일 수 있음, 기업용 앱 기준)
   - Mac에서 서명 키 접근 허락을 물으면 macOS 암호를 입력하고 **항상 허용**.
9. 아이폰 홈 화면에서 앱을 실행하고 플레이해 본다. 첫 터치 때 사운드 잠금이 풀리는지(`audio.init()`) 확인한다.
10. **7일 뒤 앱이 안 열리면**: 무료 프로필이 만료된 것이다. Mac에 연결하고 다시 Run하면 된다. ✅ [Apple Developer Forums (DTS)](https://developer.apple.com/forums/thread/724896)

#### 4-B. 터미널로 설치 (`flutter run --release`)
4-A의 3~5단계(Team과 번들 ID 지정, 개발자 모드)를 한 번 마친 뒤부터는 터미널만으로 설치할 수 있다.
```bash
cd ~/G3 && npm run build:app
cd app
flutter devices                    # 내 아이폰 ID 확인
flutter run --release -d <기기ID>   # 릴리스 빌드로 설치 + 실행 (홈 화면에서 재실행 가능)
```

#### 4-C. 디버깅 팁 (웹뷰 안 들여다보기)
- iOS 16.4 이상에서는 `isInspectable`이 켜진 웹뷰만 Mac Safari로 검사할 수 있다. ✅ [WebKit: isInspectable](https://webkit.org/blog/13936)
  - `app/lib/src/game_page.dart`는 `isInspectable: kDebugMode`다. 따라서 **Debug 빌드에서만 검사**할 수 있다(Xcode Scheme을 Debug로 하거나 `flutter run`을 `--release` 없이 실행).
  - 4-A 6단계의 Release 설치본은 검사할 수 없는 게 정상이다.
- 아이폰: 설정 > (앱 >) Safari > 고급 > **웹 속성(Web Inspector)** 켜기. Mac Safari: 설정 > 고급 > **"웹 개발자용 기능 보기"** 체크 → 메뉴 `개발 > (내 아이폰) > localhost`. ✅ [WebKit: Enabling Web Inspector](https://webkit.org/web-inspector/enabling-web-inspector/)
- 콘솔에서 `window.__game`으로 상태를 볼 수 있다.

---

### 5) 자주 나는 오류와 해결

| 증상 / 메시지 | 원인 | 해결 |
|---|---|---|
| `No profiles for '…' were found` / `Signing for "Runner" requires a development team` | Team 미지정 | Signing & Capabilities에서 Team 선택, Automatically manage signing 체크 |
| `Failed to register bundle identifier` / `… cannot be registered to your development team` | 번들 ID가 다른 팀에 이미 등록됨 | 번들 ID를 고유하게 변경 (예: `com.<내아이디>.lane1`) |
| `maximum App ID limit reached` (무료 계정) | 7일에 App ID 10개 한도 초과 | 며칠 기다리거나, **이미 쓴 번들 ID를 재사용** ✅ [compare-memberships](https://developer.apple.com/support/compare-memberships/) |
| 앱이 3개 이상 안 깔림 | 무료 계정은 기기당 앱 3개 | 예전에 깐 개발 앱 삭제 |
| "신뢰하지 않는 개발자" / 앱이 바로 닫힘 | 기기에서 개발자 인증서를 아직 신뢰하지 않음 | 설정 > 일반 > VPN 및 기기 관리 > 개발자 앱 > 신뢰 (4-A의 8단계) |
| "Developer Mode disabled" / 실행 대상에 기기가 안 보임 | 개발자 모드 꺼짐, 페어링 안 됨 | 4-A의 5단계. 신뢰 창을 실수로 닫았다면 아이폰 재시동 ✅ [Device Hub 문서](https://developer.apple.com/documentation/xcode/managing-your-simulated-and-physical-devices-in-device-hub) |
| 기기 iOS가 Xcode보다 새것이라 실행 불가 | Xcode에 해당 iOS 지원이 없음 | Xcode를 최신으로 업데이트(iOS 27 기기 → Xcode 27) ❓ |
| 7일 뒤 앱이 안 열림 | 무료 프로비저닝 7일 만료 | Mac에 연결해 다시 Run / `flutter run --release` |
| 홈 화면에서 앱을 누르면 바로 꺼짐(Mac 연결 해제 후) | **Debug 빌드**로 설치함 | Scheme을 Release로 바꾸거나 `flutter run --release` |
| `CocoaPods not installed` / `pod install` 실패 | SwiftPM 미지원 플러그인을 추가해 Flutter가 `ios/Podfile`을 만든 경우에만 생긴다(지금 `app/`에는 Podfile이 없어 해당 없음). 또는 Xcode 15 미만이라 SwiftPM이 꺼진 경우 | 2-3 설치. 그다음 `cd app && flutter clean && flutter pub get && flutter build ios --config-only`(Flutter가 `pod install`까지 돌린다). 그래도 실패하면 `cd ios && pod install --repo-update` |
| `Package resolution failed` / `swift-collections` 다운로드 실패 | 첫 빌드 때 SwiftPM이 github.com에서 의존성을 받지 못함 | 인터넷 연결 확인. Xcode `File > Packages > Reset Package Caches` 후 다시 빌드 |
| Apple silicon에서 `ffi` 관련 pod 오류 | Ruby ffi gem 문제 | `sudo gem uninstall ffi && sudo gem install ffi -- --enable-libffi-alloc` (Flutter 도구가 안내하는 명령) ✅ [cocoapods.dart](https://github.com/flutter/flutter/blob/stable/packages/flutter_tools/lib/src/macos/cocoapods.dart) |
| `Module 'flutter_inappwebview_ios' not found` / `Missing package product 'FlutterGeneratedPluginSwiftPackage'` 등 | `.xcodeproj`로 열었거나 설정 미생성(`ios/Flutter/ephemeral`은 git 제외 생성물) | **`Runner.xcworkspace`**로 열기. `flutter pub get` 후 `flutter build ios --config-only` |
| **검은/흰 화면** 또는 앱의 "게임 파일이 앱에 없습니다" 화면 | ① 에셋 미동기화(`build:app` 누락) → localhost 404 ② `127.0.0.1`로 로드(iOS 17 이상은 ATS가 IP 주소 접속을 기본 차단) ③ 로컬 서버 시작 전에 URL 로드 ④ 포트 충돌 | ① `npm run build:app` 후 재빌드. ②③④는 `app/`에 이미 반영됐다: `http://localhost:28080` 로드, Info.plist `NSAllowsLocalNetworking = YES`, `await _server.start()` 후 로드, 포트 충돌 시 28081·28082로 대체. ✅ [Apple: NSAllowsLocalNetworking](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking) (iOS 17부터 IP 주소 기본 차단, 원문 확인). 그 밖에는 4-C의 Web Inspector(Debug 빌드)로 콘솔 확인 |
| 첫 화면이 "로딩 중…"에서 오래 멈춤 (와이파이가 느리거나 인증 필요한 공용 와이파이) | 게임 HTML이 Google Fonts CSS를 `<head>`의 일반 `<link rel="stylesheet">`로 받는다. 이 요청이 실패하지 않고 **응답 없이 매달리면** 뒤따르는 게임 `<script>` 실행이 막힌다. 완전 오프라인(비행기 모드)이면 바로 실패해서 문제없다 | 헤드리스 Chromium 실측: 폰트 요청을 차단하면 정상 부팅, 응답 없이 매달리게 하면 15초가 지나도 "로딩 중…". 출시 전 **폰트 번들화**(6-3)로 해결한다. 임시로는 네트워크를 바꾸거나 비행기 모드로 실행한다 |
| WebGL이 안 나옴 / 백그라운드에서 돌아오면 화면이 멈춤 | WebGL 컨텍스트 손실 | 백그라운드 일시정지와 오디오 정지는 `app/`이 이미 처리한다(`WebBridge.hideScript`, Chromium으로 확인). 게임 쪽 `webglcontextlost`/`restored` 처리는 ❓ (실기기 확인 필요) |
| **소리 안 남** | ① 첫 터치 전이라 AudioContext가 잠김 ② **무음(벨소리) 스위치 ON**: iOS 16.3 이상에서 Web Audio는 기본 세션(ambient)이라 무음 모드면 음소거됨 ③ 웹뷰 설정 | ① 화면을 한 번 터치(`audio.init()`) ② 게임 JS에서 `navigator.audioSession.type = 'playback'` 설정(지원 시), 또는 네이티브에서 AVAudioSession 카테고리를 playback으로 ❓ [WebKit bug 251532](https://bugs.webkit.org/show_bug.cgi?id=251532), [WebKit bug 237322](https://bugs.webkit.org/show_bug.cgi?id=237322) ③ `mediaPlaybackRequiresUserGesture: false`, `allowsInlineMediaPlayback: true` (flutter_inappwebview 설정) |
| 폰트가 시스템 폰트로 보임 | Google Fonts는 네트워크로 받음(오프라인이면 대체) | 출시 전 폰트 파일을 번들에 포함 (6-3 체크리스트) |
| (Android) 흰 화면 | `http://localhost` 평문(cleartext) 차단 | `app/`에 이미 반영됐다: `android/app/src/main/res/xml/network_security_config.xml`이 `localhost`와 `127.0.0.1`만 평문을 허용하고, 매니페스트에 INTERNET 권한이 있다. Android 실빌드는 ❓ |

---

### 6) 출시 로드맵

#### 6-1. Apple (TestFlight → App Store)
1. **Apple Developer Program 가입**: 연 **99 USD**(현지 통화로 표시되며, 한국은 약 ₩129,000 ❓ [2차 출처](https://support.cafe24.com/hc/ko/articles/25401873784089)). 개인으로 가입하면 D-U-N-S가 필요 없다. 법적 실명과 2단계 인증이 필요하다. 법인으로 가입하면 D-U-N-S, 공식 웹사이트, 도메인 이메일이 필요하다. ✅ [Apple Enroll](https://developer.apple.com/programs/enroll/)
2. Xcode에서 Team을 Personal Team에서 **유료 팀**으로 바꾼다. 번들 ID를 최종 확정하고 등록한다(Automatic signing을 쓰면 Xcode가 등록해 준다).
3. **App Store Connect > 앱 > + > 신규 앱**을 만들고 번들 ID를 연결한다. ✅ [Flutter: Build and release an iOS app](https://docs.flutter.dev/deployment/ios)
4. 버전: `app/pubspec.yaml`의 `version: 0.1.0+1`(현재값). 출시할 때 `1.0.0+1` 등으로 올리고, 빌드 번호 `+N`은 업로드할 때마다 올린다. `app/lib/src/game_page.dart`의 `kAppVersion`도 함께 맞춘다.
5. 빌드와 업로드:
   ```bash
   cd ~/G3 && npm run build:app
   cd app && flutter build ipa          # build/ios/ipa/*.ipa 생성
   ```
   → **Transporter** 앱에 `.ipa`를 끌어다 놓거나, Xcode Organizer에서 `.xcarchive`를 열어 **Validate App → Distribute App**. ✅ [Flutter deployment/ios](https://docs.flutter.dev/deployment/ios)
   - 업로드 요건: **Xcode 26 이상 + iOS 26 SDK** (2026-04-28부터), 배포 타깃 iOS 13 이상 (2026-09-09부터, 우리는 15). ✅ [Upcoming Requirements](https://developer.apple.com/news/upcoming-requirements/)
   - 2027년 4월부터는 iOS 27 SDK가 요구될 예정이다 ❓ [MacTech](https://www.mactech.com/2026/09/10/app-store-submissions-now-open-for-the-latest-os-releases/)
6. **TestFlight**: 내부 테스터 최대 **100명**(팀 멤버), 외부 테스터 최대 **10,000명**(이메일 또는 공개 링크). 외부 테스트는 첫 빌드가 **베타 앱 심사**를 받아야 한다. 각 빌드는 **90일** 동안 테스트할 수 있다. ✅ [TestFlight](https://developer.apple.com/testflight/), [App Store Connect Help](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview)
7. **심사 제출 전 메타데이터**: 스크린샷, 설명, **개인정보처리방침 URL**(App Store Connect와 앱 안 양쪽에 필수, 가이드라인 5.1.1(i)), 앱 개인정보 라벨, **연령 등급 설문**(2026-01-31부터 새 등급 체계), 수출 규정(암호화) 질문. ✅ [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), [Upcoming Requirements](https://developer.apple.com/news/upcoming-requirements/)
   - 한국 게임물 등급: 애플·구글은 게임물관리위원회가 지정한 **자체등급분류사업자**라서 스토어의 등급 설문으로 처리된다 ❓ [inews24](https://www.inews24.com/view/1737742)
8. **Submit for Review**.

#### 6-2. Google Play
1. **Play Console 개발자 등록**: **1회 25 USD**, 만 18세 이상, 신분증과 카드 인증(실명). ✅ [Play Console Help](https://support.google.com/googleplay/android-developer/answer/6112435?hl=en)
2. **신규 개인 계정 규칙**: 프로덕션에 출시하기 전에 **테스터 12명 이상을 14일 연속** 옵트인 상태로 유지하는 비공개 테스트가 필요하다. 이탈에 대비해 15~20명을 모으길 권장한다 ❓. ✅ [Play Console Help 14151465](https://support.google.com/googleplay/android-developer/answer/14151465)
3. **타깃 API**: 2026-08-31부터 신규 앱과 업데이트는 **Android 16 (API 36)** 이상을 타깃으로 해야 한다(연장 신청 시 2026-11-01까지). ✅ [Android target SDK](https://developer.android.com/google/play/requirements/target-sdk)
4. 업로드 키스토어를 만들고 `flutter build appbundle`로 `.aab`를 만든 뒤 Play Console에 업로드한다(Play App Signing). 절차는 [Flutter: Build and release an Android app](https://docs.flutter.dev/deployment/android)을 따른다.
5. Android 실기기 테스트: 휴대폰에서 개발자 옵션 → USB 디버깅을 켜고 `flutter run --release`.

#### 6-3. App Store 4.2(Minimum Functionality) 대응 체크리스트

가이드라인 원문의 핵심(✅ [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)):
- **4.2**: "repackaged website" 이상의 기능, 콘텐츠, UI가 있어야 한다. 지속적인 오락 가치나 유용성이 없으면 거절될 수 있다.
- **4.2.2**: 웹 클리핑이나 링크 모음 위주면 안 된다.
- **2.5.2**: 앱은 번들 안에서 자급자족해야 하고, **기능을 바꾸는 코드를 다운로드해 실행하면 안 된다**. 따라서 게임 JS를 원격에서 받아오면 안 된다.
- **2.5.6**: 웹을 표시할 땐 WebKit을 써야 한다(WKWebView는 해당).
- **2.5.1**: 공개 API만 써야 한다. `flutter_inappwebview` 정식 6.1.5(2024-10)는 Flutter 3.35 이상에서 **2.5.1 비공개 API 리젝** 이슈가 보고됐다. 이 문제는 `flutter_inappwebview_ios 1.2.0-beta.3`(=`flutter_inappwebview 6.2.0-beta.3`, 2026-02)에서 수정됐고, `app/`은 이미 이 버전을 쓴다. ✅ [pub.dev changelog](https://pub.dev/packages/flutter_inappwebview_ios/changelog)
- 참고로 4.7(HTML5 미니게임)은 바이너리에 **내장되지 않은** 소프트웨어에 대한 규정이라, 게임을 번들에 넣는 우리 구조에는 해당하지 않는다.

리뷰어가 비행기 모드로 테스트해 흰 화면이 뜨면 래퍼로 판정한다는 보고가 있다 ❓ ([MobiLoud](https://www.mobiloud.com/blog/app-store-review-guidelines-webview-wrapper), [Apple 포럼 4.2 사례](https://developer.apple.com/forums/thread/121924)).

- [ ] **완전 오프라인**: HTML/JS/폰트/사운드가 모두 앱 번들에 있다. 비행기 모드로 첫 실행부터 클리어까지 확인한다.
- [ ] **폰트 번들화**: Black Han Sans, Jua(Google Fonts) 파일을 에셋에 넣고 `@font-face`로 로컬 로드한다(라이선스 확인 ❓). 오프라인 완결성뿐 아니라, 느린 네트워크에서 "로딩 중…"에 멈추는 문제(5장 표)도 이걸로 해결된다.
- [ ] **브라우저 흔적 제거**: 주소창, 뒤로가기, 로딩 스피너 없음. 길게 눌러 링크 미리보기, 텍스트 선택, 확대/축소(핀치), 바운스 스크롤, 더블탭 줌을 끈다. (`app/`의 WebView 설정에 대부분 반영됨: `disableContextMenu`, `isTextInteractionEnabled: false`, `supportZoom: false`, `disallowOverScroll`, `allowsLinkPreview: false`. 실기기 ❓)
- [ ] **네이티브 셸 품질**: 앱 아이콘(지금은 Flutter 기본 아이콘), 런치 스크린(검정 처리됨), 상태바/노치(safe area), 화면 방향(세로 + 가로 좌우).
  - [x] 앱 이름: Info.plist `CFBundleDisplayName`과 Android `android:label`은 "1차선 참교육"이다.
- [ ] **네이티브 기능 통합** (JS → `window.flutter_inappwebview.callHandler(...)` → Dart):
  - [ ] **햅틱**: 펑크, 충돌, 해소 순간에 Flutter `HapticFeedback`을 호출한다. 네이티브 쪽 `haptic` 핸들러는 준비됐다(`light`·`medium`·`heavy`·`selection`·`vibrate`). 게임 JS가 `window.__LANE1_APP__`이 있을 때 `callHandler('haptic', …)`를 부르는 작업만 남았다.
  - [ ] **Game Center**: 스테이지 기록 리더보드와 업적. 유료 Developer Program이 필요할 가능성이 높다 ❓.
  - [ ] **공유 시트**: 결과 카드 스크린샷 공유.
  - [x] **수명주기**: 앱이 백그라운드로 가면 자동 일시정지하고 오디오를 정지한다. 복귀하면 오디오만 되살리고, 일시정지는 유저가 직접 푼다(`app/lib/src/web_bridge.dart`). Chromium으로 확인했고 실기기는 ❓.
- [ ] **세이브 데이터 이중화**: localStorage 진행도를 네이티브 저장소(예: shared_preferences)에도 백업한다. WKWebView에 WebKit의 7일 스토리지 삭제 정책이 적용되는지는 불확실하다 ❓.
- [ ] **디버그 기능 숨김**: 릴리스 빌드에서 `window.__game`과 `?skip=` 같은 URL 디버그 파라미터를 끈다. `isInspectable`은 이미 `kDebugMode`라 릴리스에서 꺼진다.
- [ ] **완성도**: 크래시나 플레이스홀더 텍스트가 없게 한다(2.1). 개인정보처리방침 URL을 앱 안에도 넣는다(5.1.1).
- [ ] **심사 메모**(App Review Information > Notes)에 "WebGL 게임 엔진을 앱 번들에 내장, 완전 오프라인 동작, 햅틱·Game Center 등 네이티브 통합"을 명시한다.

---

### 7) 확인 못 한 것 (❓)

- **실기기 설치 전 과정 미검증**: 이 문서는 Linux 컨테이너(Xcode, iOS 시뮬레이터, Android SDK 없음)에서 공식 문서만 보고 작성했다. Mac에서 처음 따라 할 때 막히는 단계가 나오면 이 문서를 고쳐야 한다.
- ~~`npm run build:app`과 `app/` 세부 사항~~ → 리뷰에서 실제 파일과 맞췄다 ✅ (에셋 `app/assets/web/index.html`, 포트 28080, `NSAllowsLocalNetworking`, Android cleartext는 localhost만 허용).
- **CocoaPods 없이 SwiftPM만으로 빌드되는지**: flutter_tools 3.47.7 소스와 플러그인 `Package.swift`로는 ✅이다. Mac 실빌드는 ❓.
- **Xcode 26으로 iOS 27 기기에 설치되는지**: 안전하게 Xcode 27을 권장했다.
- **Xcode 27이 Apple silicon 전용인지**: 2차 출처뿐이다(Apple 페이지는 macOS Tahoe 26.6 이상만 명시).
- **Game Center를 Personal Team에서 쓸 수 있는지**: Apple capability 표의 체크 표시를 텍스트로 확인하지 못했다.
- **무음 스위치 + Web Audio**: `navigator.audioSession.type = 'playback'`이 WKWebView에서 실제로 해결하는지 실기기 확인이 필요하다.
- **WKWebView localStorage 7일 삭제 정책 적용 여부**: 출처끼리 엇갈린다. 그래서 네이티브 백업을 권장했다.
- **한국 원화 가격**(₩129,000)과 **한국 게임 등급 처리 방식**: 2차 출처뿐이다.
- **iOS 한국어 설정 메뉴 이름**: "VPN 및 기기 관리", "개발자 모드", "웹 속성"은 iOS 버전에 따라 표기가 다를 수 있다.
- ~~`flutter build ios --config-only` 출처 없음~~ → flutter_tools 3.47.7 `commands/build_ios.dart`에 이 플래그가 있음을 확인했다 ✅. 그래도 실패하면 `flutter build ios --release --no-codesign`으로 대신한다.
- `flutter_inappwebview` 6.2.0은 아직 **beta**다. 출시 전에 정식 버전이 나왔는지 확인한다.

---

### 출처

**Flutter**
- Flutter stable 릴리스 목록 — https://storage.googleapis.com/flutter_infra_release/releases/releases_macos.json
- Flutter CHANGELOG (stable, 3.47.7) — https://github.com/flutter/flutter/blob/stable/CHANGELOG.md
- Set up iOS development — https://docs.flutter.dev/platform-integration/ios/setup
- Supported deployment platforms — https://docs.flutter.dev/reference/supported-platforms
- What's new in Flutter 3.47 (iOS 최소 15) — https://flutter.dev/blog/whats-new-in-flutter-3-47
- Build and release an iOS app — https://docs.flutter.dev/deployment/ios
- Build and release an Android app — https://docs.flutter.dev/deployment/android
- Swift Package Manager for app developers — https://docs.flutter.dev/packages-and-plugins/swift-package-manager/for-app-developers
- Install Flutter manually — https://docs.flutter.dev/install/manual
- flutter_tools Xcode 최소/권장 버전 — https://github.com/flutter/flutter/blob/stable/packages/flutter_tools/lib/src/macos/xcode.dart
- flutter_tools CocoaPods 최소/권장 버전 — https://github.com/flutter/flutter/blob/stable/packages/flutter_tools/lib/src/macos/cocoapods.dart
- flutter_tools SwiftPM 기본 활성(stable) — https://github.com/flutter/flutter/blob/stable/packages/flutter_tools/lib/src/features.dart
- flutter_tools 플러그인이 모두 SwiftPM이면 Podfile·pod install 생략 — https://github.com/flutter/flutter/blob/stable/packages/flutter_tools/lib/src/macos/darwin_dependency_management.dart
- `flutter build ios --config-only` 플래그 — https://github.com/flutter/flutter/blob/stable/packages/flutter_tools/lib/src/commands/build_ios.dart
- Flutter iOS 14 debug 제한 — https://flutter.cn/docs/development/ios-14 , https://docs.agora.io/en/api-reference/faq/quality/flutter_debug

**CocoaPods / 플러그인**
- CocoaPods Getting Started — https://guides.cocoapods.org/using/getting-started.html
- CocoaPods trunk 읽기 전용 계획 — https://blog.cocoapods.org/CocoaPods-Specs-Repo/
- flutter_inappwebview — https://pub.dev/packages/flutter_inappwebview
- flutter_inappwebview_ios changelog (SwiftPM, 2.5.1 수정) — https://pub.dev/packages/flutter_inappwebview_ios/changelog
- InAppLocalhostServer — https://inappwebview.dev/docs/in-app-localhost-server

**Apple**
- Xcode system requirements — https://developer.apple.com/xcode/system-requirements/
- Upcoming requirements (Xcode 26 / iOS 26 SDK, 2026-04-28) — https://developer.apple.com/news/upcoming-requirements/
- Choosing a Membership (Personal Team 한도) — https://developer.apple.com/support/compare-memberships/
- QA1915 Personal Team은 App Store 서명 불가 — https://developer.apple.com/library/archive/qa/qa1915/_index.html
- Enabling Developer Mode on a device — https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device
- Running your app on simulated or physical devices — https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices
- Managing devices in Device Hub — https://developer.apple.com/documentation/xcode/managing-your-simulated-and-physical-devices-in-device-hub
- 신뢰 설정 경로(기업용 앱 기준) — https://support.apple.com/en-us/HT204460
- 무료 프로필 만료 시 재실행 (DTS 답변) — https://developer.apple.com/forums/thread/724896
- Apple Developer Program 가입/비용 — https://developer.apple.com/programs/enroll/
- TestFlight — https://developer.apple.com/testflight/
- TestFlight overview (90일) — https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview
- App Review Guidelines (4.2, 2.5.1, 2.5.2, 2.5.6, 4.7, 5.1.1, 2.1) — https://developer.apple.com/app-store/review/guidelines/
- NSAllowsLocalNetworking (iOS 17 이상 IP 주소 기본 차단) — https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking
- 4.2 리젝 사례 (포럼) — https://developer.apple.com/forums/thread/121924

**WebKit**
- isInspectable — https://webkit.org/blog/13936
- Enabling Web Inspector — https://webkit.org/web-inspector/enabling-web-inspector/
- Web Audio 무음 스위치 이슈 — https://bugs.webkit.org/show_bug.cgi?id=251532 , https://bugs.webkit.org/show_bug.cgi?id=237322

**Google Play**
- Play Console 시작하기 (25 USD) — https://support.google.com/googleplay/android-developer/answer/6112435?hl=en
- 신규 개인 계정 테스트 요건 (12명/14일) — https://support.google.com/googleplay/android-developer/answer/14151465
- Target API level 요건 — https://developer.android.com/google/play/requirements/target-sdk

**2차 출처 (❓)**
- Xcode 27 출시 정리 — https://blakecrosley.com/blog/xcode-27-release
- iOS 27 SDK 2027-04 요건 — https://www.mactech.com/2026/09/10/app-store-submissions-now-open-for-the-latest-os-releases/
- Apple 개발자 회비 원화 — https://support.cafe24.com/hc/ko/articles/25401873784089
- WebView 래퍼 4.2 대응 — https://www.mobiloud.com/blog/app-store-review-guidelines-webview-wrapper
- 자체등급분류사업자 — https://www.inews24.com/view/1737742
