# IPHONE_DEPLOY — Claude Code → (Mac) → iPhone 개발 설치 (이 프로젝트용 적용본)

가설:
- ❓ 사용자가 이전 프로젝트에서 실제로 쓴 절차(xcodebuild 자동 서명 → codesign·Bundle ID 검증 → devicectl 설치·실행,
  실행별 영수증, 잠금)를 Godot export 앞단에 붙이면, Mac에서 `tools/mac/ios_run.sh` 한 줄로 같은 신뢰도의 설치가 된다.
- ✅ 이 클라우드 컨테이너는 사용자 Mac에 닿지 않는다(사설 VPN 주소 도달 불가, SSH 키 없음 — 확인함). 그래서 지금
  쓸 수 있는 길은 **Mac에서 직접 실행**뿐이고, 클라우드 → Mac runner(0B)는 템플릿만 둔다.
- ✅ 저장소 `ffogtive/G3`는 **공개**다. 원본 가이드 9절의 개인 식별자(Mac 주소·사용자, SSH 키 경로, Team ID,
  iPhone ID)는 이 문서와 저장소 어디에도 쓰지 않는다. Team·기기는 자동 감지 또는 저장소 밖 로컬 설정.

> 원본: 사용자의 "Claude Code에서 Mac을 거쳐 iPhone 앱 업데이트하기"(2026-10-13). 절 번호(§0~§9)는 원본과 같게 맞췄다.
> 상세 빌드 문서: `docs/MOBILE_BUILD.md`, 1회 서명 준비: `tools/mac/SIGNING.md`.

## 아침에 할 일 (5단계)

1. **Mac 앞에서**(SSH 말고, 로그인된 화면의 Terminal) Xcode 27.x가 열리고 `Xcode > Settings… > Apple Accounts`에
   로그인돼 있는지 확인. 처음이면 `tools/mac/SIGNING.md` 1~2단계.
2. iPhone을 케이블로 연결 → 잠금 해제 → "이 컴퓨터 신뢰" → 개발자 모드 켜짐 확인(SIGNING.md 3~4단계).
3. 받기·갱신(처음이면 홈 폴더에 `G3`를 만들고, 이미 있으면 갱신만): 아래 한 줄이 4번까지 이어서 실행한다.
   `cd ~ && { [ -d G3/.git ] || git clone https://github.com/ffogtive/G3.git; } && cd G3 && git fetch origin claude/lane1-mockup && git checkout claude/lane1-mockup && git pull --ff-only && bash tools/mac/ios_run.sh`
   (iPhone은 케이블 또는 같은 Wi‑Fi에서 이전에 페어링된 상태면 된다. `brew install cmake ninja`가 있으면 C++ traffic, 없으면 GDScript 폴백)
4. `tools/mac/ios_run.sh` — 끝에 **build / install / launch가 따로** 찍힌다. "신뢰하지 않는 개발자"면 iPhone에서
   `설정 > 일반 > VPN 및 기기 관리 > 개발자 앱 > 신뢰` 후 `tools/mac/ios_run.sh --launch-only`.
5. 앱이 뜨면 기능 확인(화면·터치·햅틱). 결과는 `.local/deploy-runs/<최신>/receipt.txt`(식별자 없음)와 함께 알려 준다.

---

## §0. 실행 환경에 따라 고르기

| Claude Code 위치 | 이 프로젝트에서 | 상태 |
|---|---|---|
| 사용자 Mac 자체 | `tools/mac/ios_run.sh` 직접 실행 | 준비됨 ❓(Mac 미검증) |
| SSH 서버 → Mac 접속 가능 | 소스 전송(§4) 후 Mac에서 실행. 서명은 GUI 세션 Terminal에서(§6) | 연결 정보는 이 저장소에 두지 않음 |
| 클라우드 + Mac 접속 가능 | §0A: 플랫폼 비밀 저장소의 키 파일 + 검증된 known_hosts | 이 세션엔 없음 |
| **클라우드, 사설 Mac 접근 불가 (지금 이 컨테이너)** | §0B: Mac에 등록한 runner가 받아서 설치 — `tools/mac/iphone-install.yml.template` | **템플릿만**. 공개 저장소라 활성화 금지(아래) |

### §0B 주의 — 공개 저장소에는 self-hosted runner를 붙이지 않는다

- GitHub 권고: self-hosted runner는 **private 저장소에서만** 쓴다. 공개 저장소의 fork가 PR로 runner(=사용자 Mac,
  로그인 키체인의 서명 키, 페어링된 iPhone)에서 코드를 실행할 수 있기 때문 ✅
  ([About self-hosted runners](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/about-self-hosted-runners),
  [Security hardening](https://docs.github.com/en/actions/security-for-github-actions/security-guides/security-hardening-for-github-actions#hardening-for-self-hosted-runners)).
- 쓰려면 먼저 (a) 저장소를 private로 바꾸거나 (b) **승인된 커밋만 미러하는 별도 private 배포 저장소**를 만든다(권장).
  그다음 템플릿을 그 저장소의 `.github/workflows/iphone-install.yml`로 복사한다. 이 저장소에는 `.github/workflows`를 만들지 않았다.
- 템플릿 요점: `workflow_dispatch`만, `if: github.ref == 'refs/heads/iphone-deploy'`, `runs-on: [self-hosted, macOS, iphone-deploy]`,
  `concurrency`(취소 없음), `timeout-minutes: 30`, `actions/checkout`을 커밋 SHA로 고정 + `persist-credentials: false`,
  체크아웃 밖의 고정 스크립트 `~/Deploy/lane1/deploy-iphone.command`가 `ios_run.sh --yes`를 부른다.
- workflow 성공 ≠ 설치 성공. receipt의 build/install/launch 줄을 확인한다(원본 §0B).

## §1. 인증 원칙 (원본 그대로)

- 비밀번호·개인키·토큰 원문을 대화·CLAUDE.md·저장소에 넣지 않는다. Apple ID 로그인·2FA·키체인 승인·기기 신뢰는 사용자가 직접.
- 이 프로젝트의 로컬 설정은 저장소 밖 **`~/.lane1/deploy.env`**(chmod 600, `ios_run.sh`가 권한을 고친다):
  ```
  LANE1_TEAM_ID=<10자리, 생략하면 자동 감지>
  LANE1_DEVICE_ID=<UDID, 생략하면 페어링된 iPhone 1대 자동>
  GODOT=<Godot 4.7.2 실행 파일, 생략하면 자동/설치>
  ```
  같은 이름의 환경변수가 파일보다 우선한다. 파일은 `KEY=VALUE`로만 읽고 `source`하지 않는다.

## §2. Mac과 iPhone 최초 준비

`tools/mac/SIGNING.md` (Xcode 27 메뉴 경로: `Xcode > Settings > Apple Accounts`, `Xcode > Open Developer Tool > Device Hub`,
iPhone `설정 > 개인정보 보호 및 보안 > 개발자 모드`, 신뢰 `설정 > 일반 > VPN 및 기기 관리`).

## §3. 프로젝트별 설정표 (이 프로젝트 값)

| 항목 | 값 |
|---|---|
| Mac 프로젝트 경로 | 사용자의 G3 클론 (어디든; 스크립트가 자기 위치에서 찾음) |
| 빌드 원본 | `native/` (Godot 4.7.2 프로젝트) → Godot가 Xcode 프로젝트를 생성 |
| Xcode 진입점 | `.local/ios-export/debug/lane1.xcodeproj` (`--release`면 `release/`) — 생성물, 커밋 안 함 |
| iOS Scheme | `lane1` (export 경로 basename에서 결정, 컨테이너 export로 확인 ✅) |
| Bundle Identifier | `com.ffogtive.lane1Chamgyoyuk` (`native/export_presets.cfg`, 업데이트 중 유지) |
| 빌드된 .app | `.local/iphone-deploy/Build/Products/Debug-iphoneos/lane1.app` (`PRODUCT_NAME = lane1`) |
| Apple Team ID | **자동 감지**: 키체인 `Apple Development` 인증서의 OU → Xcode 계정 → 1회 질문(`~/.lane1/deploy.env`). 저장소엔 placeholder `LANE1TEAM0`만 |
| 실제 iPhone ID | **자동 감지**: `xcrun devicectl list devices --json-output`에서 페어링된 iPhone 1대, 아니면 목록 + 질문, 또는 `--device` |
| DerivedData / 실행 로그 | `.local/iphone-deploy/`, `.local/deploy-runs/<ts>-<pid>/` (`.local/`은 `.gitignore`) |
| 소스 전송 목록(원격일 때) | `native/` (`.godot/` 제외), `tools/mac/`, `tools/godot/build_ext.sh` |
| 테스트 명령 | 컨테이너: `godot47 --headless --path native -s res://tests/run_tests.gd`, 햅틱 `-s res://platform/ios/tests/run.gd` |
| 기능 확인 | 앱 시작 화면, 터치 반응, 차선 변경·경적 햅틱, `THERMAL` 로그 줄(10초 간격; Mac의 Console.app에서 iPhone 선택, 또는 수동으로 `xcrun devicectl device process launch --console …` ❓) |

> 원본 가이드는 Team·기기 값을 설정표에 적는다. 이 저장소는 공개라서 그 두 칸만 **자동 감지/로컬 설정**으로 바꿨다.

## §4. 변경한 소스 전달

- Mac에서 직접: `git pull`이면 끝.
- 원격에서 Mac으로(§0A 경로가 생겼을 때): 필요한 것만 명시적으로, 삭제는 따로.
  ```bash
  tar -cf /tmp/lane1-src.tar --exclude native/.godot --exclude native/ext/godot-cpp native tools/mac tools/godot/build_ext.sh
  # scp/ssh는 플랫폼 비밀 저장소의 키 + 검증된 known_hosts로 (원본 §0A). 주소·사용자는 여기에 쓰지 않는다.
  ```

## §5. Mac에서 빌드하고 설치하기 → `tools/mac/ios_run.sh`

원본 §5 템플릿의 각 줄이 스크립트의 어디에 있는지:

| 원본 §5 | ios_run.sh |
|---|---|
| `xcodebuild … -scheme … -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath <root>/.local/iphone-deploy -allowProvisioningUpdates -allowProvisioningDeviceRegistration DEVELOPMENT_TEAM=… CODE_SIGN_STYLE=Automatic CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES build > build.log` | 같은 인자(모의 실행에서 글자 그대로 확인 ✅). 추가: 프로파일에 기기가 없다는 오류면 `-destination id=<UDID>`로 1회 재시도 |
| `test -d "$DEPLOY_APP"`, `codesign --verify --deep --strict`, `PlistBuddy Print :CFBundleIdentifier` ≠ 대상이면 중단 | 동일. 불일치면 설치하지 않고 exit 4 |
| `xcrun devicectl device install app --device … --json-output install.json` | 동일 (`install.log`도 저장) |
| `xcrun devicectl device process launch --device … --terminate-existing <bundle> --json-output launch.json` | 동일. launch 인자 없음(원본 §8 "검증용 launch argument 금지") |
| `DEPLOY_RUN=.local/deploy-runs/$(date +%Y%m%d-%H%M%S)-$$`, EXIT trap → `exit-code` | 동일 + `receipt.txt`(결과·git SHA·Bundle ID, 식별자 없음) |
| `mkdir .local/iphone-deploy.lock` 실패 시 중단, 자동 삭제 안 함 | 동일 + `owner` 파일(pid, 시작 시각). 다른 실행의 잠금은 절대 지우지 않음(exit 9) |
| 기존 앱을 먼저 삭제하지 않는다 | uninstall 호출 없음 |
| `umask 077` | **바꿈**: 빌드 산출물은 기본 권한(설치 후 앱 번들 파일 읽기 문제 예방), 실행 로그 폴더만 700, deploy.env는 600 |

앞단(원본에 없는 부분): Xcode/기기/개발자 모드 사전 점검 → Godot 4.7.2 + 템플릿 설치(SHA-512 검증) → iOS 확장
빌드(실패해도 계속) → `Godot --headless --export-debug iOS` → 생성된 pbxproj의 Team placeholder 치환.
결과는 **build / install / launch를 따로** 출력하고, 기능 확인은 항상 "❓ 사용자 확인"으로 남긴다.

## §6. 서명 오류 (errSecInternalComponent)

- 원본 사례: SSH 세션에서 `codesign`이 `errSecInternalComponent`로 실패, 같은 빌드를 로그인된 Mac Terminal에서 실행하면 성공.
- `ios_run.sh`는 SSH 세션이면 미리 경고하고, 실패 시 "Mac 화면의 로그인된 Terminal에서 다시 실행, 키체인 창에서 로그인
  비밀번호 입력 후 '항상 허용'"을 안내하고 멈춘다. 비밀번호를 명령줄에 넣는 키체인 강제 해제·키 내보내기는 하지 않는다.
- 원격에서 GUI 세션으로 넘길 때(`open -a Terminal …`)는 `open` 성공 ≠ 빌드 성공: 그 실행의 `exit-code`, `build.log`,
  `install.json`, `launch.json`을 확인한다.

## §7. 완료 판정과 자주 생기는 오류

빌드 성공 / 설치 성공 / 실행 성공 / 기능 확인을 따로 기록한다. 보고에는 어떤 커밋(receipt의 git SHA)을 어떤
Bundle ID로 설치했는지와 미검증 사항만 짧게 — 기기 ID·Team ID는 쓰지 않는다.

| 증상 | 처리 |
|---|---|
| No Accounts / Team 없음 | Xcode > Settings > Apple Accounts 로그인, 팀 여러 개면 1회 선택 |
| errSecInternalComponent | §6 |
| 기기가 목록에 없음 | 케이블·잠금 해제·"신뢰"·Device Hub 페어링 (exit 5) |
| 개발자 모드 꺼짐 | 설정 > 개인정보 보호 및 보안 > 개발자 모드 (exit 5) |
| 설치됐지만 실행 실패 | **설치 성공은 유지해서 보고**. 신뢰·잠금 해제 후 `--launch-only` (exit 7) |
| 7일 뒤 안 열림 | 무료 프로파일 만료 → 다시 실행(앱 삭제 금지) |
| 잠금 디렉터리가 남음 | `cat .local/iphone-deploy.lock/owner`의 pid가 끝났는지 확인 후 그 잠금만 정리 |
| 앱이 번쩍하고 꺼짐 | receipt `running=no`(실행 후 8초 안에 프로세스 사라짐, exit 7). 설치 성공은 유지해서 보고, `boot.txt`·기기 로그 확인 |
| capability·프로파일 오류 | 해당 앱 ID의 entitlement와 Team 프로파일 확인. **기능을 지워 빌드만 통과시키지 않는다** |
| 데이터가 초기화된 것처럼 보임 | Bundle ID·세이브 경로·마이그레이션 확인. **기존 앱 삭제 금지** |

- Simulator 테스트만으로 기기 검증 완료라고 하지 않는다(햅틱·120Hz·발열은 실기기 전용).
- 세이브 스키마가 바뀐 뒤 이전 바이너리 재설치는 안전한 롤백이 아닐 수 있다.

## §8. CLAUDE.md 지침

루트 `CLAUDE.md`의 "## 2. iPhone 배포"가 원본 §8을 이 프로젝트에 맞춘 요약이다.

## §9. 실제 설정값

**이 공개 저장소에는 기록하지 않는다.** Mac 주소·사용자, SSH 키 경로, Team ID, iPhone ID는 사용자 Mac의
`~/.lane1/deploy.env` 또는 플랫폼 비밀 저장소에만 둔다. 확인용으로만 쓰는 Xcode 버전: 사용자 Mac은 **Xcode 27.x**
(원본 9절 기준). Godot 4.7.2 템플릿과 Xcode 27의 호환은 `docs/MOBILE_BUILD.md` 7절 ❓.

## 출처

- 원본 가이드 §5·§6·§8의 공식 참고: [실제 기기에서 앱 실행](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices),
  [GitHub self-hosted runner](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/about-self-hosted-runners),
  [gh workflow run](https://cli.github.com/manual/gh_workflow_run), [gh run watch](https://cli.github.com/manual/gh_run_watch)
- Xcode 27 (devicectl JSON v5, ld64 제거) — https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes
- Xcode 지원 범위 — https://developer.apple.com/support/xcode/
- Team ID = 인증서 OU — https://developer.apple.com/forums/thread/802517
- Developer Mode — https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device
- Device Hub — https://developer.apple.com/documentation/xcode/managing-your-simulated-and-physical-devices-in-device-hub
