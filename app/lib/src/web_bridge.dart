import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 네이티브 ↔ 게임(JS) 사이에서 쓰는 스크립트/핸들러 모음.
///
/// JS 쪽 사용법 (통합 담당용):
/// ```js
/// // 앱 안에서 실행 중인지
/// if (window.__LANE1_APP__) { ... }
/// // 햅틱: 'light' | 'medium' | 'heavy' | 'selection' | 'vibrate'
/// window.flutter_inappwebview?.callHandler('haptic', 'medium');
/// ```
/// `window.flutter_inappwebview.callHandler` 는 `flutterInAppWebViewPlatformReady`
/// 이벤트 이후에 확실히 존재한다(대개 첫 프레임 전에 준비됨).
abstract final class WebBridge {
  static const String hapticHandler = 'haptic';

  /// 문서 시작 시 주입: 앱 환경 표시.
  static String appFlagScript({
    required String platform,
    required String version,
  }) =>
      'window.__LANE1_APP__ = Object.freeze({ platform: ${_js(platform)}, '
      'version: ${_js(version)}, haptics: true });';

  /// 앱이 비활성/백그라운드로 갈 때.
  ///
  /// game/js/main.js 와 audio.js 는 `visibilitychange` 에서 `document.hidden` 을 읽어
  /// 일시정지(jam/boss 단계에서만) + AudioContext.suspend 를 한다. 그런데 WebView 가
  /// 앱 백그라운드 전환을 항상 visibilitychange 로 알려주지는 않으므로(특히 Android,
  /// iOS 제어센터/앱 전환기), `document.hidden` 을 잠시 true 로 덮고 이벤트를 직접 쏜다.
  /// 덮어쓰기는 [showScript] 에서 걷어낸다. 여러 번 불려도 안전(멱등).
  static const String hideScript = r'''
(function () {
  try {
    if (!window.__lane1NativeHidden) {
      window.__lane1NativeHidden = true;
      Object.defineProperty(document, 'hidden', { configurable: true, get: function () { return true; } });
      Object.defineProperty(document, 'visibilityState', { configurable: true, get: function () { return 'hidden'; } });
    }
    document.dispatchEvent(new Event('visibilitychange'));
  } catch (e) {}
  return true;
})();
''';

  /// 앱이 다시 전면으로 올 때. 덮어쓴 속성을 지우고(원래 getter 복귀) 이벤트를 쏴서
  /// 오디오를 되살린다. 게임 일시정지는 풀지 않는다(유저가 직접 재개).
  static const String showScript = r'''
(function () {
  try {
    if (window.__lane1NativeHidden) {
      window.__lane1NativeHidden = false;
      delete document.hidden;
      delete document.visibilityState;
    }
    document.dispatchEvent(new Event('visibilitychange'));
  } catch (e) {}
  return true;
})();
''';

  /// Android 뒤로가기 → 게임의 일시정지 키(Escape) 토글. input.js 의 KEYMAP 을 따른다.
  static const String backButtonScript = r'''
(function () {
  try {
    var o = { key: 'Escape', code: 'Escape', bubbles: true };
    window.dispatchEvent(new KeyboardEvent('keydown', o));
    window.dispatchEvent(new KeyboardEvent('keyup', o));
  } catch (e) {}
  return true;
})();
''';

  static DateTime _lastHaptic = DateTime.fromMillisecondsSinceEpoch(0);

  @visibleForTesting
  static void resetHapticThrottle() =>
      _lastHaptic = DateTime.fromMillisecondsSinceEpoch(0);

  /// `callHandler('haptic', kind)` 처리. 30ms 안에 연속 호출되면 무시(진동 폭주 방지).
  static Future<bool> onHaptic(List<dynamic> args) async {
    final now = DateTime.now();
    if (now.difference(_lastHaptic) < const Duration(milliseconds: 30)) {
      return false;
    }
    _lastHaptic = now;
    final kind = args.isEmpty ? 'light' : '${args.first}'.toLowerCase();
    switch (kind) {
      case 'heavy':
        await HapticFeedback.heavyImpact();
      case 'medium':
        await HapticFeedback.mediumImpact();
      case 'selection':
        await HapticFeedback.selectionClick();
      case 'vibrate':
        await HapticFeedback.vibrate();
      default:
        await HapticFeedback.lightImpact();
    }
    return true;
  }

  static String _js(String s) =>
      "'${s.replaceAll(r'\', r'\\').replaceAll("'", r"\'").replaceAll('\n', r'\n')}'";
}
