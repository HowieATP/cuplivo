import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('startup assistant defaults to mostRecent with no pinned id', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    final settings = SettingsProvider();
    await settings.loaded;

    expect(settings.startupAssistantMode, StartupAssistantMode.mostRecent);
    expect(settings.pinnedAssistantId, isNull);
  });

  test('persists pinned mode and pinned assistant id across loads', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    final settings = SettingsProvider();
    await settings.loaded;

    await settings.setPinnedAssistantId('assistant-a');
    await settings.setStartupAssistantMode(StartupAssistantMode.pinned);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('pinned_assistant_id_v1'), 'assistant-a');
    expect(prefs.getString('startup_assistant_mode_v1'), 'pinned');

    final reloaded = SettingsProvider();
    await reloaded.loaded;
    expect(reloaded.startupAssistantMode, StartupAssistantMode.pinned);
    expect(reloaded.pinnedAssistantId, 'assistant-a');
  });

  test('reverting to mostRecent keeps the pinned id', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    final settings = SettingsProvider();
    await settings.loaded;

    await settings.setPinnedAssistantId('assistant-a');
    await settings.setStartupAssistantMode(StartupAssistantMode.pinned);
    await settings.setStartupAssistantMode(StartupAssistantMode.mostRecent);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('startup_assistant_mode_v1'), 'mostRecent');
    expect(prefs.getString('pinned_assistant_id_v1'), 'assistant-a');
  });

  test(
    'clears pin and reverts mode when the pinned assistant is deleted',
    () async {
      SharedPreferences.setMockInitialValues(const <String, Object>{
        'startup_assistant_mode_v1': 'pinned',
        'pinned_assistant_id_v1': 'assistant-a',
      });
      final settings = SettingsProvider();
      await settings.loaded;

      await settings.clearPinnedAssistantIfPinned('assistant-a');

      expect(settings.pinnedAssistantId, isNull);
      expect(settings.startupAssistantMode, StartupAssistantMode.mostRecent);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('startup_assistant_mode_v1'), 'mostRecent');
      expect(prefs.getString('pinned_assistant_id_v1'), isNull);
    },
  );

  test('does not touch the pin when another assistant is deleted', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{
      'startup_assistant_mode_v1': 'pinned',
      'pinned_assistant_id_v1': 'assistant-a',
    });
    final settings = SettingsProvider();
    await settings.loaded;

    await settings.clearPinnedAssistantIfPinned('assistant-b');

    expect(settings.pinnedAssistantId, 'assistant-a');
    expect(settings.startupAssistantMode, StartupAssistantMode.pinned);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('startup_assistant_mode_v1'), 'pinned');
    expect(prefs.getString('pinned_assistant_id_v1'), 'assistant-a');
  });

  test(
    'clearPinnedAssistant clears pin and reverts mode unconditionally',
    () async {
      SharedPreferences.setMockInitialValues(const <String, Object>{
        'startup_assistant_mode_v1': 'pinned',
        'pinned_assistant_id_v1': 'assistant-a',
      });
      final settings = SettingsProvider();
      await settings.loaded;

      await settings.clearPinnedAssistant();

      expect(settings.pinnedAssistantId, isNull);
      expect(settings.startupAssistantMode, StartupAssistantMode.mostRecent);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('startup_assistant_mode_v1'), 'mostRecent');
      expect(prefs.getString('pinned_assistant_id_v1'), isNull);
    },
  );

  test('clearPinnedAssistant is a no-op when nothing is pinned', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    final settings = SettingsProvider();
    await settings.loaded;

    await settings.clearPinnedAssistant();

    expect(settings.startupAssistantMode, StartupAssistantMode.mostRecent);
    expect(settings.pinnedAssistantId, isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('startup_assistant_mode_v1'), isNull);
    expect(prefs.getString('pinned_assistant_id_v1'), isNull);
  });

  test('static prefs-only clear reverts mode when pinned matches', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{
      'startup_assistant_mode_v1': 'pinned',
      'pinned_assistant_id_v1': 'assistant-a',
    });

    await SettingsProvider.clearPinnedAssistantPrefsIfPinned('assistant-a');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('startup_assistant_mode_v1'), 'mostRecent');
    expect(prefs.getString('pinned_assistant_id_v1'), isNull);
  });

  test('static prefs-only clear leaves the pin when another assistant is '
      'deleted', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{
      'startup_assistant_mode_v1': 'pinned',
      'pinned_assistant_id_v1': 'assistant-a',
    });

    await SettingsProvider.clearPinnedAssistantPrefsIfPinned('assistant-b');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('startup_assistant_mode_v1'), 'pinned');
    expect(prefs.getString('pinned_assistant_id_v1'), 'assistant-a');
  });

  test('unknown persisted mode falls back to mostRecent', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{
      'startup_assistant_mode_v1': 'bogus-mode',
      'pinned_assistant_id_v1': 'assistant-a',
    });
    final settings = SettingsProvider();
    await settings.loaded;

    expect(settings.startupAssistantMode, StartupAssistantMode.mostRecent);
    expect(settings.pinnedAssistantId, 'assistant-a');
  });
}
