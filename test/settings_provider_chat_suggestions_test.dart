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

  group('SettingsProvider chat suggestions', () {
    test('defaults suggestion model to disabled', () async {
      businessPrefs = BusinessPreferences.memoryForTests({});
      final settings = SettingsProvider(preferences: businessPrefs);

      await _waitForSettingsLoad();

      expect(settings.suggestionModelProvider, isNull);
      expect(settings.suggestionModelId, isNull);
      expect(settings.suggestionModelKey, isNull);
      expect(
        settings.suggestionPrompt,
        SettingsProvider.defaultSuggestionPrompt,
      );
    });

    test('persists selected suggestion model and prompt', () async {
      businessPrefs = BusinessPreferences.memoryForTests({});
      final settings = SettingsProvider(preferences: businessPrefs);

      await _waitForSettingsLoad();
      await settings.setSuggestionModel('OpenAI', 'gpt-test');
      await settings.setSuggestionPrompt('Custom {content} {locale}');

      expect(settings.suggestionModelProvider, 'OpenAI');
      expect(settings.suggestionModelId, 'gpt-test');
      expect(settings.suggestionModelKey, 'OpenAI::gpt-test');
      expect(settings.suggestionPrompt, 'Custom {content} {locale}');

      final prefs = businessPrefs;
      expect(prefs.getString('suggestion_model_v1'), 'OpenAI::gpt-test');
      expect(
        prefs.getString('suggestion_prompt_v1'),
        'Custom {content} {locale}',
      );
    });

    test('defaults suggestion tap to auto-send', () async {
      businessPrefs = BusinessPreferences.memoryForTests({});
      final settings = SettingsProvider(preferences: businessPrefs);

      await _waitForSettingsLoad();

      expect(settings.insertSuggestionOnTapOnly, isFalse);
    });

    test('loads and persists insert-only suggestion tap mode', () async {
      businessPrefs = BusinessPreferences.memoryForTests({
        'suggestion_insert_on_tap_only_v1': true,
      });
      final settings = SettingsProvider(preferences: businessPrefs);

      await _waitForSettingsLoad();

      expect(settings.insertSuggestionOnTapOnly, isTrue);

      await settings.setInsertSuggestionOnTapOnly(false);

      expect(settings.insertSuggestionOnTapOnly, isFalse);
      final prefs = businessPrefs;
      expect(prefs.getBool('suggestion_insert_on_tap_only_v1'), isFalse);
    });

    test(
      'clears suggestion model when provider selection is cleared',
      () async {
        businessPrefs = BusinessPreferences.memoryForTests({
          'suggestion_model_v1': 'OpenAI::gpt-test',
        });
        final settings = SettingsProvider(preferences: businessPrefs);

        await _waitForSettingsLoad();
        await settings.clearSelectionsForProvider('OpenAI');

        expect(settings.suggestionModelProvider, isNull);
        expect(settings.suggestionModelId, isNull);
        final prefs = businessPrefs;
        expect(prefs.getString('suggestion_model_v1'), isNull);
      },
    );
  });
}
