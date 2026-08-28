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

  group('SettingsProvider desktop message navigation buttons mode', () {
    test('defaults to scroll visibility', () async {
      businessPrefs = BusinessPreferences.memoryForTests({});
      final settings = SettingsProvider(preferences: businessPrefs);

      await _waitForSettingsLoad();

      expect(
        settings.desktopMessageNavButtonsMode,
        DesktopMessageNavButtonsMode.scroll,
      );
    });

    test('loads every persisted mode value', () async {
      const cases = <String, DesktopMessageNavButtonsMode>{
        'always': DesktopMessageNavButtonsMode.always,
        'scroll': DesktopMessageNavButtonsMode.scroll,
        'hover': DesktopMessageNavButtonsMode.hover,
        'scrollAndHover': DesktopMessageNavButtonsMode.scrollAndHover,
        'never': DesktopMessageNavButtonsMode.never,
      };

      for (final entry in cases.entries) {
        businessPrefs = BusinessPreferences.memoryForTests({
          'display_desktop_message_nav_buttons_mode_v1': entry.key,
        });
        final settings = SettingsProvider(preferences: businessPrefs);

        await _waitForSettingsLoad();

        expect(settings.desktopMessageNavButtonsMode, entry.value);
      }
    });

    test(
      'maps legacy disabled toggle to never when new key is absent',
      () async {
        businessPrefs = BusinessPreferences.memoryForTests({
          'display_show_message_nav_v1': false,
        });
        final settings = SettingsProvider(preferences: businessPrefs);

        await _waitForSettingsLoad();

        expect(
          settings.desktopMessageNavButtonsMode,
          DesktopMessageNavButtonsMode.never,
        );
      },
    );

    test('persists mode changes to preferences', () async {
      businessPrefs = BusinessPreferences.memoryForTests({});
      final settings = SettingsProvider(preferences: businessPrefs);

      await _waitForSettingsLoad();
      await settings.setDesktopMessageNavButtonsMode(
        DesktopMessageNavButtonsMode.scrollAndHover,
      );

      expect(
        settings.desktopMessageNavButtonsMode,
        DesktopMessageNavButtonsMode.scrollAndHover,
      );
      final prefs = businessPrefs;
      expect(
        prefs.getString('display_desktop_message_nav_buttons_mode_v1'),
        'scrollAndHover',
      );
    });
  });
}
