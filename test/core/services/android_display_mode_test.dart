import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/services/android_display_mode.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('app.display_mode');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('AndroidDisplayMode.setHighRefreshRate', () {
    test('sends the enabled flag and parses the platform response', () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return <Object?, Object?>{
              'supported': true,
              'enabled': true,
              'refreshRate': 120.0,
              'modeId': 3,
            };
          });

      final result = await AndroidDisplayMode.setHighRefreshRate(true);

      expect(calls, hasLength(1));
      expect(calls.single.method, 'setHighRefreshRate');
      expect(calls.single.arguments, {'enabled': true});
      expect(result, isNotNull);
      expect(result!.supported, isTrue);
      expect(result.enabled, isTrue);
      expect(result.refreshRate, 120.0);
      expect(result.modeId, 3);
    });

    test('disabling returns the system-default mode flags', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            return <Object?, Object?>{
              'supported': true,
              'enabled': false,
              'refreshRate': 60.0,
              'modeId': 1,
            };
          });

      final result = await AndroidDisplayMode.setHighRefreshRate(false);

      expect(result, isNotNull);
      expect(result!.supported, isTrue);
      expect(result.enabled, isFalse);
      expect(result.refreshRate, 60.0);
      expect(result.modeId, 1);
    });

    test('reports unsupported displays without throwing', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            return <Object?, Object?>{
              'supported': false,
              'enabled': false,
              'refreshRate': null,
              'modeId': null,
            };
          });

      final result = await AndroidDisplayMode.setHighRefreshRate(true);

      expect(result, isNotNull);
      expect(result!.supported, isFalse);
      expect(result.enabled, isFalse);
      expect(result.refreshRate, isNull);
      expect(result.modeId, isNull);
    });

    test('propagates platform failures so callers can log them', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (call) async => throw PlatformException(
              code: 'display_mode_failed',
              message: 'no matching mode',
            ),
          );

      await expectLater(
        AndroidDisplayMode.setHighRefreshRate(true),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'display_mode_failed',
          ),
        ),
      );
    });

    test('surfaces missing channels as MissingPluginException', () async {
      // No mock handler registered: the channel is absent on non-Android.
      await expectLater(
        AndroidDisplayMode.setHighRefreshRate(true),
        throwsA(isA<MissingPluginException>()),
      );
    });
  });
}
