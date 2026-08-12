import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/providers/settings_provider.dart';

/// Polls until [condition] holds; SettingsProvider._load() runs async from
/// the constructor, so fixed sleeps would be flaky on slow CI.
Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for SettingsProvider condition');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(const {});
  });

  group('preferAndroidHighRefreshRate', () {
    test('defaults to true when the key is absent (fresh install)', () async {
      final settings = SettingsProvider();
      await _waitUntil(() => settings.preferAndroidHighRefreshRate);
      expect(settings.preferAndroidHighRefreshRate, isTrue);
    });

    test(
      'defaults to true when the key is absent (old backup restore)',
      () async {
        SharedPreferences.setMockInitialValues({
          'display_chat_font_scale_v1': 1.2,
        });
        final settings = SettingsProvider();
        await _waitUntil(() => settings.preferAndroidHighRefreshRate);
        expect(settings.preferAndroidHighRefreshRate, isTrue);
      },
    );

    test('persists the value and reloads it', () async {
      final settings = SettingsProvider();
      // Wait for load by observing a value only _load() can produce.
      await _waitUntil(() => settings.preferAndroidHighRefreshRate);
      await settings.setPreferAndroidHighRefreshRate(false);

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getBool('display_prefer_android_high_refresh_rate_v1'),
        isFalse,
      );

      final reloaded = SettingsProvider();
      await _waitUntil(() => reloaded.preferAndroidHighRefreshRate == false);
      expect(reloaded.preferAndroidHighRefreshRate, isFalse);
    });

    test('setter with an unchanged value does not notify', () async {
      SharedPreferences.setMockInitialValues({
        'display_prefer_android_high_refresh_rate_v1': false,
      });
      final settings = SettingsProvider();
      await _waitUntil(() => settings.preferAndroidHighRefreshRate == false);
      var notifications = 0;
      settings.addListener(() => notifications++);

      await settings.setPreferAndroidHighRefreshRate(false);

      expect(notifications, 0);
    });

    test('setter notifies when the value actually changes', () async {
      SharedPreferences.setMockInitialValues({
        'display_prefer_android_high_refresh_rate_v1': false,
      });
      final settings = SettingsProvider();
      await _waitUntil(() => settings.preferAndroidHighRefreshRate == false);
      var notifications = 0;
      settings.addListener(() => notifications++);

      await settings.setPreferAndroidHighRefreshRate(true);

      expect(notifications, 1);
      expect(settings.preferAndroidHighRefreshRate, isTrue);
    });
  });

  group('mobileBlurEffectsEnabled', () {
    test('defaults to false when the key is absent', () async {
      final settings = SettingsProvider();
      await _waitUntil(() => settings.mobileBlurEffectsEnabled == false);
      expect(settings.mobileBlurEffectsEnabled, isFalse);
    });

    test('persists the value and reloads it', () async {
      final settings = SettingsProvider();
      await _waitUntil(() => settings.mobileBlurEffectsEnabled == false);
      await settings.setMobileBlurEffectsEnabled(true);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('display_mobile_blur_effects_v1'), isTrue);

      final reloaded = SettingsProvider();
      await _waitUntil(() => reloaded.mobileBlurEffectsEnabled);
      expect(reloaded.mobileBlurEffectsEnabled, isTrue);
    });

    test('setter with an unchanged value does not notify', () async {
      SharedPreferences.setMockInitialValues({
        'display_mobile_blur_effects_v1': true,
      });
      final settings = SettingsProvider();
      await _waitUntil(() => settings.mobileBlurEffectsEnabled);
      var notifications = 0;
      settings.addListener(() => notifications++);

      await settings.setMobileBlurEffectsEnabled(true);

      expect(notifications, 0);
    });

    test('setter notifies when the value actually changes', () async {
      SharedPreferences.setMockInitialValues({
        'display_mobile_blur_effects_v1': true,
      });
      final settings = SettingsProvider();
      await _waitUntil(() => settings.mobileBlurEffectsEnabled);
      var notifications = 0;
      settings.addListener(() => notifications++);

      await settings.setMobileBlurEffectsEnabled(false);

      expect(notifications, 1);
      expect(settings.mobileBlurEffectsEnabled, isFalse);
    });
  });
}
