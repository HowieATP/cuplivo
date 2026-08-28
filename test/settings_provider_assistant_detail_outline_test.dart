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

  group('SettingsProvider assistant detail outline toggle', () {
    test('defaults to disabled to preserve the current tab layout', () async {
      businessPrefs = BusinessPreferences.memoryForTests({});
      final settings = SettingsProvider(preferences: businessPrefs);

      await _waitForSettingsLoad();

      expect(settings.mobileAssistantDetailOutlineEnabled, isFalse);
    });

    test('loads persisted enabled value', () async {
      businessPrefs = BusinessPreferences.memoryForTests({
        'mobile_assistant_detail_outline_enabled_v1': true,
      });
      final settings = SettingsProvider(preferences: businessPrefs);

      await _waitForSettingsLoad();

      expect(settings.mobileAssistantDetailOutlineEnabled, isTrue);
    });

    test('persists mode changes to preferences', () async {
      businessPrefs = BusinessPreferences.memoryForTests({});
      final settings = SettingsProvider(preferences: businessPrefs);

      await _waitForSettingsLoad();
      await settings.setMobileAssistantDetailOutlineEnabled(true);

      expect(settings.mobileAssistantDetailOutlineEnabled, isTrue);
      final prefs = businessPrefs;
      expect(
        prefs.getBool('mobile_assistant_detail_outline_enabled_v1'),
        isTrue,
      );
    });
  });
}
