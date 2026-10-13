import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lane1_chamgyoyuk/src/local_asset_server.dart';

/// 실 소켓으로 로컬 서버에 GET.
Future<(int, String, ContentType?)> _get(int port, String path) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse('http://127.0.0.1:$port$path'));
    req.followRedirects = false;
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    return (res.statusCode, body, res.headers.contentType);
  } finally {
    client.close(force: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // TestWidgetsFlutterBinding 은 HttpClient 를 400 만 돌려주는 목으로 바꾼다 → 실 소켓 사용.
  setUpAll(() => HttpOverrides.global = null);

  group('assetKeyForPath', () {
    test('웹 루트 안의 경로만 허용', () {
      expect(
        LocalAssetServer.assetKeyForPath('/assets/web/index.html'),
        'assets/web/index.html',
      );
      expect(
        LocalAssetServer.assetKeyForPath('/assets/web/'),
        'assets/web/index.html',
      );
      expect(
        LocalAssetServer.assetKeyForPath('/assets/web/a%20b.png'),
        'assets/web/a b.png',
      );
    });
    test('웹 루트 밖 / 상위 경로 / 깨진 인코딩은 거부', () {
      expect(LocalAssetServer.assetKeyForPath('/pubspec.yaml'), isNull);
      expect(LocalAssetServer.assetKeyForPath('/AssetManifest.bin'), isNull);
      expect(
        LocalAssetServer.assetKeyForPath('/assets/web/../../pubspec.yaml'),
        isNull,
      );
      expect(LocalAssetServer.assetKeyForPath('/assets/web/%2e%2e/x'), isNull);
      expect(LocalAssetServer.assetKeyForPath('/assets/web/%E0%A4%A'), isNull);
    });
  });

  test('contentTypeFor', () {
    expect(
      LocalAssetServer.contentTypeFor('a/index.html').mimeType,
      'text/html',
    );
    expect(LocalAssetServer.contentTypeFor('a/index.html').charset, 'utf-8');
    expect(
      LocalAssetServer.contentTypeFor('a/x.js').mimeType,
      'text/javascript',
    );
    expect(
      LocalAssetServer.contentTypeFor('a/x.WASM').mimeType,
      'application/wasm',
    );
    expect(
      LocalAssetServer.contentTypeFor('a/noext').mimeType,
      'application/octet-stream',
    );
  });

  group('실 서버 (번들된 assets/web/index.html)', () {
    // 고정 포트를 다른 프로세스가 쓰고 있어도 테스트가 깨지지 않게 테스트 전용 포트대 사용.
    const testPort = 28180;
    late LocalAssetServer server;

    setUp(() => server = LocalAssetServer(preferredPort: testPort));
    tearDown(() => server.close());

    test('게임 HTML 을 text/html 로 서빙', () async {
      final port = await server.start();
      expect(port, testPort);
      expect(server.usingFallbackPort, isFalse);
      expect(
        server.indexUri.toString(),
        'http://localhost:$testPort/assets/web/index.html',
      );

      final (status, body, type) = await _get(port, '/assets/web/index.html');
      expect(status, HttpStatus.ok);
      expect(type?.mimeType, 'text/html');
      expect(body, contains('<canvas id="game"'));
      expect(body, contains('1차선 참교육'));
    });

    test('루트는 index 로 리다이렉트, 없는 파일·밖 경로는 404, 헬스 체크 200', () async {
      final port = await server.start();
      expect((await _get(port, '/')).$1, HttpStatus.found);
      expect((await _get(port, '/assets/web/nope.js')).$1, HttpStatus.notFound);
      expect(
        (await _get(port, '/assets/web/../../pubspec.yaml')).$1,
        HttpStatus.notFound,
      );
      expect(
        (await _get(port, LocalAssetServer.kHealthPath)).$1,
        HttpStatus.ok,
      );
      expect(await server.isHealthy(), isTrue);
    });

    test('고정 포트가 사용 중이면 다음 포트로 대체', () async {
      final blocker = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        testPort,
      );
      try {
        final port = await server.start();
        expect(port, testPort + 1);
        expect(server.usingFallbackPort, isTrue);
        expect((await _get(port, '/assets/web/index.html')).$1, HttpStatus.ok);
      } finally {
        await blocker.close();
      }
    });

    test('죽은 서버는 ensureRunning 이 같은 포트로 되살린다', () async {
      await server.start();
      await server.close();
      expect(server.isRunning, isFalse);
      expect(await server.isHealthy(), isFalse);
      expect(await server.ensureRunning(), isFalse);
      expect(server.port, testPort);
      expect(await server.isHealthy(), isTrue);
    });

    test('대체 포트로 떠 있던 서버는 재시작해도 그 포트를 유지 (origin·세이브 보존)', () async {
      final blocker = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        testPort,
      );
      final int fallback;
      try {
        fallback = await server.start();
        expect(fallback, testPort + 1);
      } finally {
        await blocker.close(); // 이제 preferred 포트가 비었다
      }
      await server.close();
      expect(await server.ensureRunning(), isFalse);
      expect(server.port, fallback);
    });
  });
}
