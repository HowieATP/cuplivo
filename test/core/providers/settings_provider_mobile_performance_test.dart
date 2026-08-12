import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/providers/settings_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(const {});
  });

  group('preferAndroidHighRefreshRate', () {
    test('defaults to true when the key is absent (fresh install)', () async {
      final settings = SettingsProvider();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(settings.preferAndroidHighRefreshRate, isTrue);
    });

    test(
      'defaults to true when the key is absent (old backup restore)',
      () async {
        SharedPreferences.setMockInitialValues({
          'display_chat_font_scale_v1': 1.2,
        });
        final settings = SettingsProvider();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(settings.preferAndroidHighRefreshRate, isTrue);
      },
    );

    test('persists the value and reloads it', () async {
      final settings = SettingsProvider();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await settings.setPreferAndroidHighRefreshRate(false);

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getBool('display_prefer_android_high_refresh_rate_v1'),
        isFalse,
      );

      final reloaded = SettingsProvider();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(reloaded.preferAndroidHighRefreshRate, isFalse);
    });

    test('setter with an unchanged value does not notify', () async {
      final settings = SettingsProvider();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      var notifications = 0;
      settings.addListener(() => notifications++);

      await settings.setPreferAndroidHighRefreshRate(true);

      expect(notifications, 0);
    });
  });

  group('mobileBlurEffectsEnabled', () {
    test('defaults to false when the key is absent', () async {
      final settings = SettingsProvider();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(settings.mobileBlurEffectsEnabled, isFalse);
    });

    test('persists the value and reloads it', () async {
      final settings = SettingsProvider();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await settings.setMobileBlurEffectsEnabled(true);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('display_mobile_blur_effects_v1'), isTrue);

      final reloaded = SettingsProvider();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(reloaded.mobileBlurEffectsEnabled, isTrue);
    });

    test('setter with an unchanged value does not notify', () async {
      final settings = SettingsProvider();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      var notifications = 0;
      settings.addListener(() => notifications++);

      await settings.setMobileBlurEffectsEnabled(false);

      expect(notifications, 0);
    });
  });
}
