import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/game_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 세로 기본(Info.plist / 첫 항목) + 가로 허용. 거꾸로 세로는 제외.
  await SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.portraitUp,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  await applyImmersiveMode();
  runApp(const Lane1App());
}

class Lane1App extends StatelessWidget {
  const Lane1App({super.key, this.enableWebView = true});

  /// 위젯 테스트에서 false (테스트 호스트엔 WebView 구현이 없음).
  final bool enableWebView;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: kAppTitle,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.black,
      ),
      home: GamePage(enableWebView: enableWebView),
    );
  }
}
