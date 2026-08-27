import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/providers/settings_provider.dart';

Future<void> _waitForSettingsLoad() async {
  for (var i = 0; i < 25; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SettingsProvider keep screen on during generation', () {
    test('defaults to enabled', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsProvider();

      await _waitForSettingsLoad();

      expect(settings.keepScreenOnDuringGeneration, isTrue);
    });

    test('loads persisted disabled value', () async {
      SharedPreferences.setMockInitialValues({
        'keep_screen_on_during_generation_v1': false,
      });
      final settings = SettingsProvider();

      await _waitForSettingsLoad();

      expect(settings.keepScreenOnDuringGeneration, isFalse);
    });

    test('persists mode changes to preferences', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsProvider();

      await _waitForSettingsLoad();
      await settings.setKeepScreenOnDuringGeneration(false);

      expect(settings.keepScreenOnDuringGeneration, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('keep_screen_on_during_generation_v1'), isFalse);
    });
  });
}
