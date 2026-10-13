# SIGNING — iPhone 개발 설치를 위한 1회 준비 (Mac)

가설: ❓ 아래 1~5단계를 한 번 끝내면 그 뒤로는 `tools/mac/ios_run.sh` 한 줄로 설치·실행된다. 무료 Apple ID
(Personal Team)로 충분하고, 7일마다 같은 명령을 다시 돌리면 된다. (Mac·실기기 미검증 — 메뉴 이름은 Xcode 27
공식 문서 기준 ✅, 실제 화면은 ❓)

> 이 저장소는 **공개(public)** 다. Team ID, iPhone UDID, Apple ID, Mac 주소는 **어떤 파일에도 쓰지 않는다.**
> `ios_run.sh`가 키체인·`devicectl`에서 자동으로 찾고, 바꿔야 할 때만 환경변수나 저장소 밖 파일
> `~/.lane1/deploy.env`(chmod 600)에 둔다.

| 무엇 | 값 | 어디서 정해지나 |
|---|---|---|
| Bundle ID | `com.ffogtive.lane1Chamgyoyuk` | `native/export_presets.cfg` (고정, 바꾸지 말 것 — 무료 계정은 7일에 App ID 10개 한도) |
| Xcode 프로젝트 / Scheme / 제품 | `.local/ios-export/debug/lane1.xcodeproj` / `lane1` / `lane1.app` | Godot export가 생성 |
| Team ID | 자동 감지 | 키체인의 `Apple Development` 인증서 **OU 필드** (괄호 안 값이 아님) |
| iPhone | 자동 감지 | `xcrun devicectl list devices`에서 페어링된 iPhone 1대 |
| 덮어쓰기 | `LANE1_TEAM_ID`, `LANE1_DEVICE_ID`, `GODOT` | 환경변수 또는 `~/.lane1/deploy.env` |

## 1단계. Xcode 설치와 첫 실행

1. App Store에서 **Xcode 27.x**를 설치하고 한 번 연다. 추가 구성요소 설치 창이 뜨면 **iOS**를 선택해 설치한다.
   - 나중에 추가하려면: **Xcode > Settings… (⌘,) > Components > iOS 27 > Get** ✅ ([Apple](https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components))
   - Xcode 27은 **macOS Tahoe 26.6 이상**이 필요하다 ✅ ([Xcode 27 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes)).
2. 터미널에서 (비밀번호는 Mac 로그인 비밀번호, 직접 입력):
   ```bash
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   sudo xcodebuild -license accept
   sudo xcodebuild -runFirstLaunch
   xcodebuild -version        # Xcode 27.x 확인
   ```
3. `cmake`는 traffic 확장(C++) iOS 빌드에만 필요하다. 없으면 `ios_run.sh --check`부터 경고하고, traffic은 stub(진입 심볼이
   false를 돌려줌)이 되어 게임은 GDScript 교통 폴백으로 뜬다 ❓(기기 미검증). 결과 화면과 receipt에 `native traffic: false`로 남는다.
   `brew install cmake` (Homebrew가 있을 때).

## 2단계. Apple 계정 로그인 (Xcode)

1. **Xcode > Settings… > Apple Accounts > 왼쪽 아래 `+` > Apple Account > Continue** → Apple ID와 2단계 인증을
   **직접** 입력한다 ✅ ([Apple: Set up code signing for physical devices](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices#Set-up-code-signing-for-physical-devices)).
2. 목록에 `<이름> (Personal Team)`(무료) 또는 유료 팀이 보이면 끝. 인증서는 첫 빌드 때
   `xcodebuild -allowProvisioningUpdates`가 만든다. 미리 만들려면 같은 화면에서 팀 선택 >
   **Manage Certificates… > `+` > Apple Development** ❓(버튼 이름은 Xcode 27 실화면 확인 필요).
3. 팀이 여러 개면 `ios_run.sh`가 처음 한 번 물어보고 `~/.lane1/deploy.env`에 기억한다.

> Team ID 확인이 필요할 때: 키체인 접근(Keychain Access) > 로그인 > 내 인증서 > `Apple Development: …`
> 더블클릭 > **조직 단위(Organizational Unit)** 값이 Team ID다. 인증서 이름 괄호 안의 10자리는 개인 ID라서
> **Team ID가 아니다** ✅ ([Apple DTS, Developer Forums](https://developer.apple.com/forums/thread/802517)).

## 3단계. iPhone 연결과 페어링

1. iPhone을 **케이블로** Mac에 연결하고 잠금을 푼다. **"이 컴퓨터를 신뢰하겠습니까?" > 신뢰** → 기기 암호.
2. Xcode에서 **Xcode > Open Developer Tool > Device Hub**를 연다(또는 실행 대상 메뉴 > Manage Devices…).
   왼쪽에서 iPhone을 고르고 **Pair** 버튼이 있으면 누른다 ✅ ([Apple: Device Hub](https://developer.apple.com/documentation/xcode/managing-your-simulated-and-physical-devices-in-device-hub)).
   처음엔 "기기 준비 중"이 몇 분 걸릴 수 있다.
3. 확인: `xcrun devicectl list devices` 에 iPhone이 보이면 된다(시뮬레이터 ID와 혼동 금지).
   - Xcode 27은 **iOS 17 이상** 기기만 개발 실행을 지원한다 ✅ ([Xcode Support](https://developer.apple.com/support/xcode/)).
   - 무선 페어링은 iOS 27 이상에서만. 처음엔 케이블을 권장한다.

## 4단계. 개발자 모드 (iPhone)

1. iPhone **설정 > 개인정보 보호 및 보안 > (보안) 개발자 모드 > 켬** → 경고에서 **재시동**.
2. 재시동 후 뜨는 알림에서 위로 밀고 **켜기(Enable)** → 기기 암호 ✅ ([Apple: Enabling Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)).
   - 이 메뉴는 3단계 페어링을 시작한 뒤에만 보인다.
   - `ios_run.sh`는 devicectl의 `developerModeStatus`가 `disabled`면 이 안내를 띄우고 멈춘다.

## 5단계. 첫 실행과 "신뢰하지 않는 개발자"

```bash
cd ~/<repo>/G3 && git pull
tools/mac/ios_run.sh            # 첫 실행은 Godot 4.7.2 + 템플릿(~1.3 GB) 다운로드 포함
```

1. 빌드 중 **"codesign이(가) 키체인의 키 'Apple Development: …'에 접근하려고 합니다"** 창이 뜨면 Mac 로그인
   비밀번호를 입력하고 **항상 허용**. (비밀번호를 명령줄·파일에 넣지 않는다.)
2. 설치는 됐는데 실행이 `invalid code signature … not been explicitly trusted` 로 실패하면(무료 Personal Team
   첫 설치에서 정상) iPhone에서:
   **설정 > 일반 > VPN 및 기기 관리 > 개발자 앱 > `Apple Development: <Apple ID>` > "<Apple ID>" 신뢰 > 신뢰**
   ❓(개발자 서명 앱 기준 경로는 Apple 공식 문서가 아니라 포럼·지원 문서 기준: [Apple Support](https://support.apple.com/118254),
   [Developer Forums](https://developer.apple.com/forums/thread/685271)) → 그다음
   `tools/mac/ios_run.sh --launch-only`
3. SSH로 Mac에 들어와 실행했다가 `errSecInternalComponent` 가 나면: Mac 화면의 **로그인된 Terminal에서** 같은
   명령을 다시 실행한다(키체인이 GUI 세션에 묶여 있음, docs/IPHONE_DEPLOY.md §6).

## 무료 Personal Team의 한계 ✅ ([Apple: Choosing a Membership](https://developer.apple.com/support/compare-memberships/))

- 프로비저닝 **7일 만료** → 7일 뒤 앱이 안 열리면 `tools/mac/ios_run.sh` 다시 실행(데이터는 유지, 앱 삭제 금지).
- 기기당 개발 앱 3개, 7일에 App ID 10개. Bundle ID를 바꾸지 말 것.
- Game Center·푸시 등 일부 capability 불가(현재 preset은 모두 꺼 둠).

## 하지 않는 것

- 기존 앱 삭제(데이터 초기화) — `ios_run.sh`는 언제나 같은 Bundle ID로 덮어 설치한다.
- Team ID·UDID·Apple ID를 저장소 파일, 커밋, 이슈, 로그 붙여넣기에 남기기 (`ios_run.sh` 출력은 `AB******YZ`로 가림).
- `security unlock-keychain -p <비밀번호>` 같은 강제 해제, 인증서/개인키 내보내기.
