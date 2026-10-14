# app/ — 1차선 참교육 Flutter 껍데기

가설: 게임을 Flutter로 다시 짤 필요 없이, 앱 안 로컬 서버(`http://localhost:28080`)로 `assets/web/index.html`(= `dist/index.html`)을 InAppWebView에 띄우면 iOS·Android 출시본이 된다. (Linux에서 analyze/test ✅ · 실기기 ❓)

1. **게임 갱신**: 저장소 루트에서 `npm run build:app` → `dist/index.html`이 `app/assets/web/index.html`로 복사된다. 그다음 앱을 다시 빌드한다.
2. **아이폰 설치 (Mac)**: `cd app && flutter pub get && flutter build ios --config-only && open ios/Runner.xcworkspace` → Xcode의 Runner › Signing & Capabilities에서 Team을 고른다(`DEVELOPMENT_TEAM`은 일부러 비워 두었다) → 기기를 고르고 Run(또는 `flutter run --release`). CocoaPods는 필요 없다(SwiftPM 사용, `ios/Podfile`이 없는 것이 정상).
3. **구조**: `lib/src/local_asset_server.dart`(루프백 서버, 고정 포트 28080) · `lib/src/game_page.dart`(WebView, 스플래시, 백그라운드 일시정지) · `lib/src/web_bridge.dart`(JS 스크립트, `haptic` 핸들러).

자세한 설치·출시 절차는 [`docs/MOBILE_BUILD.md`](../docs/MOBILE_BUILD.md)에 있다.

## 메모
- **포트(28080)는 바꾸지 않는다.** 포트가 localStorage(세이브)의 origin이라서, 바꾸면 기존 세이브가 보이지 않는다. 포트가 사용 중이면 28081, 28082, 임의 포트 순으로 대체하는데, 그 세션에서는 세이브가 분리된다.
- **햅틱 (JS → 네이티브)**: `window.flutter_inappwebview?.callHandler('haptic', 'light' | 'medium' | 'heavy' | 'selection' | 'vibrate')`. 앱 안에서 실행 중인지는 `window.__LANE1_APP__`으로 판별한다.
- **앱 아이콘**: 지금은 Flutter 기본 아이콘이다. 1024×1024 PNG(투명 없음)를 준비해서 다음 중 하나로 교체한다.
  - Xcode의 `ios/Runner/Assets.xcassets/AppIcon`에 넣는다.
  - `flutter_launcher_icons`를 dev_dependency로 추가하고 `flutter_launcher_icons: {image_path: assets/icon/icon.png, android: true, ios: true, remove_alpha_ios: true}`를 설정한 뒤 `dart run flutter_launcher_icons`를 실행한다.
- **번들 ID**: iOS는 `com.ffogtive.lane1Chamgyoyuk`, Android는 `com.ffogtive.lane1_chamgyoyuk`이다. App Store Connect에 등록하면 바꿀 수 없으므로, 출시 전에 최종값으로 정한다.
