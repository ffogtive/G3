import 'dart:async';
import 'dart:collection';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'local_asset_server.dart';
import 'web_bridge.dart';

const String kAppTitle = '1차선 참교육';
const String kAppVersion = '0.1.0';

/// 게임 화면: 로컬 서버 기동 → InAppWebView 로 http://localhost:PORT/assets/web/index.html.
class GamePage extends StatefulWidget {
  const GamePage({super.key, this.enableWebView = true, this.server});

  /// false 면 서버·WebView 를 띄우지 않고 스플래시만 그린다(위젯 테스트용:
  /// 테스트 호스트에는 WebView 플랫폼 구현이 없다).
  final bool enableWebView;

  /// 주입용(테스트). null 이면 기본 [LocalAssetServer].
  final LocalAssetServer? server;

  @override
  State<GamePage> createState() => _GamePageState();
}

class _GamePageState extends State<GamePage> with WidgetsBindingObserver {
  late final LocalAssetServer _server = widget.server ?? LocalAssetServer();
  InAppWebViewController? _web;
  WebUri? _url;
  bool _pageReady = false;
  String? _error;
  Timer? _splashTimeout;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.enableWebView) _boot();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _splashTimeout?.cancel();
    unawaited(_server.close());
    super.dispose();
  }

  Future<void> _boot() async {
    try {
      await _server.start();
      if (!mounted) return;
      setState(() {
        _url = WebUri.uri(_server.indexUri);
        _error = null;
      });
      _armSplashTimeout();
    } catch (e) {
      _showError('로컬 서버를 시작하지 못했습니다.\n$e');
    }
  }

  /// 로드 완료 이벤트를 못 받아도 스플래시에 갇히지 않게.
  void _armSplashTimeout() {
    _splashTimeout?.cancel();
    _splashTimeout = Timer(const Duration(seconds: 12), _markReady);
  }

  void _markReady() {
    _splashTimeout?.cancel();
    if (mounted && !_pageReady) setState(() => _pageReady = true);
  }

  void _showError(String message) {
    _splashTimeout?.cancel();
    if (mounted) setState(() => _error = message);
  }

  Future<void> _reload() async {
    if (!mounted) return;
    setState(() {
      _error = null;
      _pageReady = false;
    });
    try {
      await _server.ensureRunning();
      final web = _web;
      if (web != null) {
        _armSplashTimeout();
        await web.loadUrl(
          urlRequest: URLRequest(url: WebUri.uri(_server.indexUri)),
        );
      } else {
        await _boot();
      }
    } catch (e) {
      _showError('게임을 다시 불러오지 못했습니다.\n$e');
    }
  }

  // ───────────────────────── 앱 생명주기 → 게임 일시정지/오디오
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final web = _web;
    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        // 제어센터/앱 전환기(inactive)부터 바로 멈춘다. 여러 번 불려도 안전.
        _eval(WebBridge.hideScript);
        if (state == AppLifecycleState.paused && web != null && _isAndroid) {
          unawaited(web.pause().catchError((_) {})); // Android WebView.onPause
        }
      case AppLifecycleState.resumed:
        // 전체화면이 풀렸을 수 있으니 다시 적용.
        unawaited(applyImmersiveMode());
        if (web != null && _isAndroid) {
          unawaited(web.resume().catchError((_) {}));
        }
        unawaited(
          _server
              .ensureRunning()
              .then((portChanged) {
                // 직전 포트를 다시 못 잡았으면 WebView 가 죽은 origin 을 보고 있다 → 새 URL 로 재로드.
                if (portChanged) return _reload();
              })
              .catchError(
                (Object e) =>
                    debugPrint('[GamePage] server restart failed: $e'),
              )
              .whenComplete(() => _eval(WebBridge.showScript)),
        );
      case AppLifecycleState.detached:
        break;
    }
  }

  void _eval(String source) {
    final web = _web;
    if (web == null || !_pageReady) return;
    unawaited(web.evaluateJavascript(source: source).catchError((_) => null));
  }

  static bool get _isAndroid => !kIsWeb && Platform.isAndroid;

  // ───────────────────────── WebView
  InAppWebViewSettings get _settings => InAppWebViewSettings(
    javaScriptEnabled: true,
    mediaPlaybackRequiresUserGesture: false,
    allowsInlineMediaPlayback: true,
    transparentBackground: false,
    disableContextMenu: true,
    supportZoom: false,
    builtInZoomControls: false,
    displayZoomControls: false,
    verticalScrollBarEnabled: false,
    horizontalScrollBarEnabled: false,
    useShouldOverrideUrlLoading: true,
    isInspectable: kDebugMode,
    // iOS
    allowsBackForwardNavigationGestures: false,
    allowsLinkPreview: false,
    disableLongPressContextMenuOnLinks: true,
    disallowOverScroll: true,
    isTextInteractionEnabled: false,
    suppressesIncrementalRendering: false,
    preferredContentMode: UserPreferredContentMode.MOBILE,
    contentInsetAdjustmentBehavior:
        ScrollViewContentInsetAdjustmentBehavior.NEVER,
    underPageBackgroundColor: Colors.black,
    allowsAirPlayForMediaPlayback: false,
    allowsPictureInPictureMediaPlayback: false,
    // Android
    overScrollMode: OverScrollMode.NEVER,
    domStorageEnabled: true,
    databaseEnabled: true,
    useHybridComposition: true,
    textZoom: 100,
    algorithmicDarkeningAllowed: false,
    safeBrowsingEnabled: false, // 로컬 페이지라 불필요(Google 조회 트래픽 방지)
  );

  UnmodifiableListView<UserScript> get _userScripts => UnmodifiableListView([
    UserScript(
      source: WebBridge.appFlagScript(
        platform: _isAndroid ? 'android' : 'ios',
        version: kAppVersion,
      ),
      injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
    ),
  ]);

  bool _isLocal(Uri? uri) {
    if (uri == null) return true;
    if (uri.scheme == 'about' || uri.scheme == 'data' || uri.scheme == 'blob') {
      return true;
    }
    return (uri.host == 'localhost' || uri.host == '127.0.0.1') &&
        uri.port == _server.port;
  }

  Widget _buildWebView(WebUri url) {
    return InAppWebView(
      initialUrlRequest: URLRequest(url: url),
      initialSettings: _settings,
      initialUserScripts: _userScripts,
      onWebViewCreated: (c) {
        _web = c;
        c.addJavaScriptHandler(
          handlerName: WebBridge.hapticHandler,
          callback: (JavaScriptHandlerFunctionData data) =>
              WebBridge.onHaptic(data.args),
        );
      },
      shouldOverrideUrlLoading: (c, action) async {
        // 게임 밖으로 나가는 메인 프레임 이동은 막는다(외부 링크가 생기면 여기서 처리).
        final isMain = action.isForMainFrame;
        if (!isMain || _isLocal(action.request.url)) {
          return NavigationActionPolicy.ALLOW;
        }
        return NavigationActionPolicy.CANCEL;
      },
      onLoadStop: (c, url) => _markReady(),
      onReceivedError: (c, request, error) {
        // 서브리소스(예: 오프라인일 때 Google Fonts) 실패와 재로드로 인한 취소는 무시.
        if (!(request.isForMainFrame ?? true)) return;
        if (error.type == WebResourceErrorType.CANCELLED) return;
        _showError('게임을 불러오지 못했습니다.\n${error.description}');
      },
      onReceivedHttpError: (c, request, response) {
        if (!(request.isForMainFrame ?? true) || !_isLocal(request.url)) return;
        _showError(
          response.statusCode == 404
              ? '게임 파일이 앱에 없습니다.\n저장소 루트에서 npm run build:app 후 다시 빌드하세요.'
              : '게임을 불러오지 못했습니다. (HTTP ${response.statusCode})',
        );
      },
      // iOS: WebContent 프로세스가 (메모리 부족 등으로) 죽으면 흰 화면 → 다시 띄운다.
      onWebContentProcessDidTerminate: (c) => _reload(),
      // Android: 렌더러 프로세스 종료 → 같은 처리.
      onRenderProcessGone: (c, detail) => _reload(),
      onConsoleMessage: kDebugMode
          ? (c, msg) => debugPrint('[web:${msg.messageLevel}] ${msg.message}')
          : null,
    );
  }

  // ───────────────────────── UI
  @override
  Widget build(BuildContext context) {
    final url = _url;
    return PopScope(
      canPop: false,
      // Android 뒤로가기 = 게임 일시정지 토글 (앱이 꺼지지 않게)
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _eval(WebBridge.backButtonScript);
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        resizeToAvoidBottomInset: false,
        body: Stack(
          fit: StackFit.expand,
          children: [
            if (widget.enableWebView && url != null) _buildWebView(url),
            IgnorePointer(
              ignoring: _pageReady && _error == null,
              child: AnimatedOpacity(
                opacity: (_pageReady && _error == null) ? 0 : 1,
                duration: const Duration(milliseconds: 250),
                child: _error == null
                    ? const SplashView()
                    : _ErrorView(message: _error!, onRetry: _reload),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 로딩 중 스플래시: 검은 배경 + 앱 이름.
class SplashView extends StatelessWidget {
  const SplashView({super.key});

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Colors.black,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              kAppTitle,
              style: TextStyle(
                color: Colors.white,
                fontSize: 34,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.5,
              ),
            ),
            SizedBox(height: 22),
            SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: Colors.white54,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 15,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 20),
              OutlinedButton(
                onPressed: onRetry,
                style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
                child: const Text('다시 시도'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 상태바·내비게이션바 숨김(스와이프하면 잠깐 나왔다 다시 숨음).
Future<void> applyImmersiveMode() =>
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
