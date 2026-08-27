import 'package:flutter_test/flutter_test.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';

import 'package:Cuplivo/core/providers/settings_provider.dart';

Future<void> _waitForSettingsLoad() async {
  for (var i = 0; i < 25; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  var businessPrefs = BusinessPreferences.memoryForTests();
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SettingsProvider OCR prompt', () {
    test('defaults to the built-in OCR prompt when unset', () async {
      businessPrefs = BusinessPreferences.memoryForTests({});
      final settings = SettingsProvider(preferences: businessPrefs);

      await _waitForSettingsLoad();

      expect(settings.ocrPrompt, SettingsProvider.defaultOcrPrompt);
    });

    test('persists an explicitly empty OCR prompt', () async {
      businessPrefs = BusinessPreferences.memoryForTests({});
      final settings = SettingsProvider(preferences: businessPrefs);

      await _waitForSettingsLoad();
      await settings.setOcrPrompt('   ');

      expect(settings.ocrPrompt, isEmpty);
      final prefs = businessPrefs;
      expect(prefs.getString('ocr_prompt_v1'), isEmpty);
    });

    test(
      'reloads an explicitly empty OCR prompt instead of the default',
      () async {
        businessPrefs = BusinessPreferences.memoryForTests({
          'ocr_prompt_v1': '',
        });
        final settings = SettingsProvider(preferences: businessPrefs);

        await _waitForSettingsLoad();

        expect(settings.ocrPrompt, isEmpty);
      },
    );

    test('reset restores the built-in OCR prompt', () async {
      businessPrefs = BusinessPreferences.memoryForTests({'ocr_prompt_v1': ''});
      final settings = SettingsProvider(preferences: businessPrefs);

      await _waitForSettingsLoad();
      await settings.resetOcrPrompt();

      expect(settings.ocrPrompt, SettingsProvider.defaultOcrPrompt);
      final prefs = businessPrefs;
      expect(
        prefs.getString('ocr_prompt_v1'),
        SettingsProvider.defaultOcrPrompt,
      );
    });
  });
}
