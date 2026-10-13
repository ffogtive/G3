// 앱 위젯 스모크 테스트.
//
// WebView 는 테스트 호스트(Linux/macOS VM)에 플랫폼 구현이 없어 생성 자체가
// 불가능하므로 enableWebView: false 로 껍데기(스플래시·라우팅)만 검증한다.
// 실제 게임 서빙 경로는 test/local_asset_server_test.dart 에서 실 소켓으로 검증.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lane1_chamgyoyuk/main.dart';
import 'package:lane1_chamgyoyuk/src/game_page.dart';

void main() {
  testWidgets('앱이 빌드되고 스플래시(검은 배경 + 앱 이름)가 보인다', (tester) async {
    await tester.pumpWidget(const Lane1App(enableWebView: false));

    expect(find.byType(GamePage), findsOneWidget);
    expect(find.byType(SplashView), findsOneWidget);
    expect(find.text('1차선 참교육'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    expect(scaffold.backgroundColor, Colors.black);
  });
}
