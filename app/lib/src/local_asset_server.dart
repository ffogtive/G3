import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 앱 번들 에셋(`assets/web/…`)을 `http://localhost:<port>/assets/web/…` 로 서빙하는
/// 루프백 전용 HTTP 서버.
///
/// flutter_inappwebview 의 `InAppLocalhostServer` 대신 직접 구현한 이유:
///  - 그쪽은 포트 바인딩 실패 시 `start()` 의 Future 가 영원히 끝나지 않는다
///    (에러를 zone 에서 삼킴) → 대체 포트 로직을 붙일 수 없다.
///  - 모든 요청마다 헤더를 print 하고, 캐시 헤더를 줄 수 없다.
///
/// 포트 = localStorage(세이브) origin 이다. `http://localhost:28080` 과
/// `http://localhost:28081` 은 서로 다른 저장소이므로 **출시 후 [kPreferredPort] 를
/// 바꾸면 기존 세이브가 안 보인다.** 대체 포트는 충돌 시 그 세션만 쓰는 비상구.
class LocalAssetServer {
  LocalAssetServer({
    this.preferredPort = kPreferredPort,
    this.fallbackPortCount = 2,
    AssetBundle? bundle,
  }) : _bundle = bundle ?? rootBundle;

  /// 고정 포트. 1024–32767 사이(안드로이드/리눅스 임시 포트 대역 32768+ 회피),
  /// 흔한 개발 포트(8080, 3000 …)와 겹치지 않게 골랐다.
  static const int kPreferredPort = 28080;

  /// 서빙 허용 경로 접두사(에셋 키 기준). 번들의 다른 에셋은 노출하지 않는다.
  static const String kWebRoot = 'assets/web/';

  /// 게임 진입 HTML 의 경로.
  static const String kIndexPath = '/${kWebRoot}index.html';

  /// 헬스 체크 경로 (iOS 가 백그라운드에서 리슨 소켓을 회수했는지 확인용).
  static const String kHealthPath = '/__health';

  final int preferredPort;
  final int fallbackPortCount;
  final AssetBundle _bundle;

  HttpServer? _server;

  bool get isRunning => _server != null;

  /// 바인딩된 포트. [start] 전에는 null.
  int? get port => _server?.port;

  /// 대체 포트(preferredPort+1 …)로 떨어졌는지. true 면 이번 세션은 세이브가 분리된다.
  bool get usingFallbackPort => port != null && port != preferredPort;

  /// 게임 진입 URL. [start] 이후에만 유효.
  Uri get indexUri {
    final p = port;
    if (p == null) throw StateError('LocalAssetServer not started');
    return Uri.parse('http://localhost:$p$kIndexPath');
  }

  /// 서버 시작. 고정 포트 → 대체 포트들 → OS 임의 포트 순으로 시도.
  /// 이미 떠 있으면 그대로 반환.
  Future<int> start() async {
    final running = _server;
    if (running != null) return running.port;

    final candidates = <int>[
      for (var i = 0; i <= fallbackPortCount; i++) preferredPort + i,
      0, // 최후의 수단: OS 가 고른 포트 (세이브 분리됨)
    ];
    Object? lastError;
    for (final p in candidates) {
      try {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, p);
        server.autoCompress = false; // 로컬 루프백: 압축은 CPU 낭비
        _server = server;
        server.listen(
          _handle,
          onError: (Object e) => _log('server error: $e'),
          onDone: () {
            if (identical(_server, server)) _server = null;
          },
          cancelOnError: false,
        );
        if (p != preferredPort) {
          _log(
            'port $preferredPort busy → using ${server.port} (save data separated this session)',
          );
        }
        return server.port;
      } on SocketException catch (e) {
        lastError = e;
      }
    }
    throw StateError('LocalAssetServer: no port available ($lastError)');
  }

  /// 서버가 실제로 응답하는지 확인하고, 죽어 있으면 같은 포트 우선으로 재시작.
  /// iOS 는 앱이 일시 중단된 사이 리슨 소켓을 회수할 수 있다.
  Future<void> ensureRunning() async {
    if (await isHealthy()) return;
    await close();
    await start();
  }

  /// 루프백으로 [kHealthPath] 를 요청해 200 이 오는지 확인.
  Future<bool> isHealthy({
    Duration timeout = const Duration(seconds: 1),
  }) async {
    final p = port;
    if (p == null) return false;
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final req = await client
          .getUrl(Uri.parse('http://127.0.0.1:$p$kHealthPath'))
          .timeout(timeout);
      final res = await req.close().timeout(timeout);
      await res.drain<void>();
      return res.statusCode == HttpStatus.ok;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> close() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      res.headers
        ..set(HttpHeaders.cacheControlHeader, 'no-store')
        ..set('X-Content-Type-Options', 'nosniff');

      if (req.method != 'GET' && req.method != 'HEAD') {
        res.statusCode = HttpStatus.methodNotAllowed;
        return;
      }
      final path = req.uri.path;
      if (path == kHealthPath) {
        res.headers.contentType = ContentType.text;
        res.write('ok');
        return;
      }
      if (path == '/' || path.isEmpty) {
        res
          ..statusCode = HttpStatus.found
          ..headers.set(HttpHeaders.locationHeader, kIndexPath);
        return;
      }

      final key = assetKeyForPath(path);
      if (key == null) {
        res.statusCode = HttpStatus.notFound;
        return;
      }
      final Uint8List body;
      try {
        final data = await _bundle.load(key);
        body = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      } catch (_) {
        res.statusCode = HttpStatus.notFound;
        return;
      }
      res.headers
        ..contentType = contentTypeFor(key)
        ..contentLength = body.length;
      if (req.method == 'GET') res.add(body);
    } catch (e) {
      _log('request failed ${req.uri}: $e');
      try {
        res.statusCode = HttpStatus.internalServerError;
      } catch (_) {
        /* 헤더 이미 전송됨 */
      }
    } finally {
      try {
        await res.close();
      } catch (_) {
        /* 클라이언트가 먼저 끊음 */
      }
    }
  }

  /// URL 경로 → 에셋 키. [kWebRoot] 밖이거나 `..` 가 섞이면 null.
  @visibleForTesting
  static String? assetKeyForPath(String urlPath) {
    String decoded;
    try {
      decoded = Uri.decodeFull(urlPath);
    } catch (_) {
      return null;
    }
    var key = decoded.startsWith('/') ? decoded.substring(1) : decoded;
    if (key.endsWith('/')) key = '${key}index.html';
    if (!key.startsWith(kWebRoot)) return null;
    final segments = key.split('/');
    if (segments.any((s) => s == '..' || s == '.' || s.contains('\\'))) {
      return null;
    }
    return key;
  }

  static const Map<String, String> _mime = {
    'html': 'text/html; charset=utf-8',
    'htm': 'text/html; charset=utf-8',
    'js': 'text/javascript; charset=utf-8',
    'mjs': 'text/javascript; charset=utf-8',
    'css': 'text/css; charset=utf-8',
    'json': 'application/json; charset=utf-8',
    'txt': 'text/plain; charset=utf-8',
    'svg': 'image/svg+xml',
    'png': 'image/png',
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'webp': 'image/webp',
    'gif': 'image/gif',
    'ico': 'image/x-icon',
    'mp3': 'audio/mpeg',
    'm4a': 'audio/mp4',
    'aac': 'audio/aac',
    'ogg': 'audio/ogg',
    'wav': 'audio/wav',
    'mp4': 'video/mp4',
    'woff': 'font/woff',
    'woff2': 'font/woff2',
    'ttf': 'font/ttf',
    'otf': 'font/otf',
    'wasm': 'application/wasm',
    'glb': 'model/gltf-binary',
    'gltf': 'model/gltf+json',
    'bin': 'application/octet-stream',
  };

  @visibleForTesting
  static ContentType contentTypeFor(String key) {
    final dot = key.lastIndexOf('.');
    final ext = dot < 0 ? '' : key.substring(dot + 1).toLowerCase();
    return ContentType.parse(_mime[ext] ?? 'application/octet-stream');
  }

  static void _log(String msg) {
    if (kDebugMode) debugPrint('[LocalAssetServer] $msg');
  }
}
