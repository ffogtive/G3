import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lane1_chamgyoyuk/src/web_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <MethodCall>[];
  setUp(() {
    calls.clear();
    WebBridge.resetHapticThrottle();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          calls.add(call);
          return null;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null),
  );

  Future<String?> haptic(List<dynamic> args) async {
    WebBridge.resetHapticThrottle();
    calls.clear();
    await WebBridge.onHaptic(args);
    return calls.isEmpty
        ? null
        : '${calls.single.method}:${calls.single.arguments}';
  }

  test('haptic 종류 → HapticFeedback 매핑', () async {
    expect(
      await haptic(['light']),
      'HapticFeedback.vibrate:HapticFeedbackType.lightImpact',
    );
    expect(
      await haptic(['MEDIUM']),
      'HapticFeedback.vibrate:HapticFeedbackType.mediumImpact',
    );
    expect(
      await haptic(['heavy']),
      'HapticFeedback.vibrate:HapticFeedbackType.heavyImpact',
    );
    expect(
      await haptic(['selection']),
      'HapticFeedback.vibrate:HapticFeedbackType.selectionClick',
    );
    expect(await haptic(['vibrate']), 'HapticFeedback.vibrate:null');
    expect(
      await haptic([]),
      'HapticFeedback.vibrate:HapticFeedbackType.lightImpact',
    );
    expect(
      await haptic(['??']),
      'HapticFeedback.vibrate:HapticFeedbackType.lightImpact',
    );
  });

  test('30ms 안 연속 호출은 무시', () async {
    expect(await WebBridge.onHaptic(['heavy']), isTrue);
    expect(await WebBridge.onHaptic(['heavy']), isFalse);
    expect(calls.length, 1);
  });

  test('appFlagScript 는 문자열을 안전하게 이스케이프', () {
    final s = WebBridge.appFlagScript(platform: "i'os", version: r'0.1\0');
    expect(s, contains(r"platform: 'i\'os'"));
    expect(s, contains(r"version: '0.1\\0'"));
  });
}
