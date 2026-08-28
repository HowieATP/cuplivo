import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';

Future<void> _waitForSettingsLoad() async {
  for (var i = 0; i < 25; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

var businessPrefs = BusinessPreferences.memoryForTests();
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SettingsProvider keep screen on during generation', () {
    test('defaults to enabled', () async {
      businessPrefs = BusinessPreferences.memoryForTests();
      final settings = SettingsProvider(preferences: businessPrefs);

      await _waitForSettingsLoad();

      expect(settings.keepScreenOnDuringGeneration, isTrue);
    });

    test('loads persisted disabled value', () async {
      businessPrefs = BusinessPreferences.memoryForTests({
        'keep_screen_on_during_generation_v1': false,
      });
      final settings = SettingsProvider(preferences: businessPrefs);

      await _waitForSettingsLoad();

      expect(settings.keepScreenOnDuringGeneration, isFalse);
    });

    test('persists mode changes to preferences', () async {
      businessPrefs = BusinessPreferences.memoryForTests();
      final settings = SettingsProvider(preferences: businessPrefs);

      await _waitForSettingsLoad();
      await settings.setKeepScreenOnDuringGeneration(false);

      expect(settings.keepScreenOnDuringGeneration, isFalse);
      expect(
        businessPrefs.getBool('keep_screen_on_during_generation_v1'),
        isFalse,
      );
    });
  });
}
