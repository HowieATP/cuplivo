import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';

var businessPrefs = BusinessPreferences.memoryForTests();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('startup assistant defaults to mostRecent with no pinned id', () async {
    businessPrefs = BusinessPreferences.memoryForTests(
      const <String, Object>{},
    );
    final settings = SettingsProvider(preferences: businessPrefs);
    await settings.loaded;

    expect(settings.startupAssistantMode, StartupAssistantMode.mostRecent);
    expect(settings.pinnedAssistantId, isNull);
  });

  test('persists pinned mode and pinned assistant id across loads', () async {
    businessPrefs = BusinessPreferences.memoryForTests(
      const <String, Object>{},
    );
    final settings = SettingsProvider(preferences: businessPrefs);
    await settings.loaded;

    await settings.setPinnedAssistantId('assistant-a');
    await settings.setStartupAssistantMode(StartupAssistantMode.pinned);

    final prefs = businessPrefs;
    expect(prefs.getString('pinned_assistant_id_v1'), 'assistant-a');
    expect(prefs.getString('startup_assistant_mode_v1'), 'pinned');

    final reloaded = SettingsProvider(preferences: businessPrefs);
    await reloaded.loaded;
    expect(reloaded.startupAssistantMode, StartupAssistantMode.pinned);
    expect(reloaded.pinnedAssistantId, 'assistant-a');
  });

  test('reverting to mostRecent keeps the pinned id', () async {
    businessPrefs = BusinessPreferences.memoryForTests(
      const <String, Object>{},
    );
    final settings = SettingsProvider(preferences: businessPrefs);
    await settings.loaded;

    await settings.setPinnedAssistantId('assistant-a');
    await settings.setStartupAssistantMode(StartupAssistantMode.pinned);
    await settings.setStartupAssistantMode(StartupAssistantMode.mostRecent);

    final prefs = businessPrefs;
    expect(prefs.getString('startup_assistant_mode_v1'), 'mostRecent');
    expect(prefs.getString('pinned_assistant_id_v1'), 'assistant-a');
  });

  test(
    'clears pin and reverts mode when the pinned assistant is deleted',
    () async {
      businessPrefs = BusinessPreferences.memoryForTests(const <String, Object>{
        'startup_assistant_mode_v1': 'pinned',
        'pinned_assistant_id_v1': 'assistant-a',
      });
      final settings = SettingsProvider(preferences: businessPrefs);
      await settings.loaded;

      await settings.clearPinnedAssistantIfPinned('assistant-a');

      expect(settings.pinnedAssistantId, isNull);
      expect(settings.startupAssistantMode, StartupAssistantMode.mostRecent);
      final prefs = businessPrefs;
      expect(prefs.getString('startup_assistant_mode_v1'), 'mostRecent');
      expect(prefs.getString('pinned_assistant_id_v1'), isNull);
    },
  );

  test('does not touch the pin when another assistant is deleted', () async {
    businessPrefs = BusinessPreferences.memoryForTests(const <String, Object>{
      'startup_assistant_mode_v1': 'pinned',
      'pinned_assistant_id_v1': 'assistant-a',
    });
    final settings = SettingsProvider(preferences: businessPrefs);
    await settings.loaded;

    await settings.clearPinnedAssistantIfPinned('assistant-b');

    expect(settings.pinnedAssistantId, 'assistant-a');
    expect(settings.startupAssistantMode, StartupAssistantMode.pinned);
    final prefs = businessPrefs;
    expect(prefs.getString('startup_assistant_mode_v1'), 'pinned');
    expect(prefs.getString('pinned_assistant_id_v1'), 'assistant-a');
  });

  test(
    'clearPinnedAssistant clears pin and reverts mode unconditionally',
    () async {
      businessPrefs = BusinessPreferences.memoryForTests(const <String, Object>{
        'startup_assistant_mode_v1': 'pinned',
        'pinned_assistant_id_v1': 'assistant-a',
      });
      final settings = SettingsProvider(preferences: businessPrefs);
      await settings.loaded;

      await settings.clearPinnedAssistant();

      expect(settings.pinnedAssistantId, isNull);
      expect(settings.startupAssistantMode, StartupAssistantMode.mostRecent);
      final prefs = businessPrefs;
      expect(prefs.getString('startup_assistant_mode_v1'), 'mostRecent');
      expect(prefs.getString('pinned_assistant_id_v1'), isNull);
    },
  );

  test('clearPinnedAssistant is a no-op when nothing is pinned', () async {
    businessPrefs = BusinessPreferences.memoryForTests(
      const <String, Object>{},
    );
    final settings = SettingsProvider(preferences: businessPrefs);
    await settings.loaded;

    await settings.clearPinnedAssistant();

    expect(settings.startupAssistantMode, StartupAssistantMode.mostRecent);
    expect(settings.pinnedAssistantId, isNull);
    final prefs = businessPrefs;
    expect(prefs.getString('startup_assistant_mode_v1'), isNull);
    expect(prefs.getString('pinned_assistant_id_v1'), isNull);
  });

  test('static prefs-only clear reverts mode when pinned matches', () async {
    businessPrefs = BusinessPreferences.memoryForTests(const <String, Object>{
      'startup_assistant_mode_v1': 'pinned',
      'pinned_assistant_id_v1': 'assistant-a',
    });

    await SettingsProvider.clearPinnedAssistantPrefsIfPinned(
      'assistant-a',
      businessPrefs,
    );

    final prefs = businessPrefs;
    expect(prefs.getString('startup_assistant_mode_v1'), 'mostRecent');
    expect(prefs.getString('pinned_assistant_id_v1'), isNull);
  });

  test('static prefs-only clear leaves the pin when another assistant is '
      'deleted', () async {
    businessPrefs = BusinessPreferences.memoryForTests(const <String, Object>{
      'startup_assistant_mode_v1': 'pinned',
      'pinned_assistant_id_v1': 'assistant-a',
    });

    await SettingsProvider.clearPinnedAssistantPrefsIfPinned(
      'assistant-b',
      businessPrefs,
    );

    final prefs = businessPrefs;
    expect(prefs.getString('startup_assistant_mode_v1'), 'pinned');
    expect(prefs.getString('pinned_assistant_id_v1'), 'assistant-a');
  });

  test('unknown persisted mode falls back to mostRecent', () async {
    businessPrefs = BusinessPreferences.memoryForTests(const <String, Object>{
      'startup_assistant_mode_v1': 'bogus-mode',
      'pinned_assistant_id_v1': 'assistant-a',
    });
    final settings = SettingsProvider(preferences: businessPrefs);
    await settings.loaded;

    expect(settings.startupAssistantMode, StartupAssistantMode.mostRecent);
    expect(settings.pinnedAssistantId, 'assistant-a');
  });
}
