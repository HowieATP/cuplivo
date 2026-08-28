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

  group('SettingsProvider tool result summary toggle', () {
    test('defaults to disabled', () async {
      businessPrefs = BusinessPreferences.memoryForTests({});
      final settings = SettingsProvider(preferences: businessPrefs);

      await _waitForSettingsLoad();

      expect(settings.showToolResultSummary, isFalse);
    });

    test('loads persisted enabled value', () async {
      businessPrefs = BusinessPreferences.memoryForTests({
        'display_show_tool_result_summary_v1': true,
      });
      final settings = SettingsProvider(preferences: businessPrefs);

      await _waitForSettingsLoad();

      expect(settings.showToolResultSummary, isTrue);
    });

    test('persists mode changes to preferences', () async {
      businessPrefs = BusinessPreferences.memoryForTests({});
      final settings = SettingsProvider(preferences: businessPrefs);

      await _waitForSettingsLoad();
      await settings.setShowToolResultSummary(true);

      expect(settings.showToolResultSummary, isTrue);
      final prefs = businessPrefs;
      expect(prefs.getBool('display_show_tool_result_summary_v1'), isTrue);
    });
  });
}
