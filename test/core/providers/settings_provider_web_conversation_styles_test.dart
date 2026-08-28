import 'dart:convert';

import 'package:Cuplivo/core/models/web_conversation_style.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/backup/data_sync.dart' as backup;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

WebConversationStyle makeStyle(String id, {String? name, double radius = 12}) {
  return WebConversationStyle.fromRaw({
    'kind': webConversationStyleKind,
    'schemaVersion': 1,
    'id': id,
    'name': name ?? id,
    'common': {
      'userBubble': {'cornerRadius': radius},
    },
    'light': <String, dynamic>{},
    'dark': <String, dynamic>{},
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
  });

  test(
    'imports without activation and restores active style after restart',
    () async {
      final settings = SettingsProvider();
      await settings.loaded;

      await settings.importWebConversationStyles([makeStyle('one')]);
      expect(settings.activeWebConversationStyle, isNull);
      await settings.setActiveWebConversationStyle('one');
      expect(settings.activeWebConversationStyle?.id, 'one');

      final reloaded = SettingsProvider();
      await reloaded.loaded;
      expect(reloaded.activeWebConversationStyle?.id, 'one');
      expect(reloaded.webConversationStyleLibrary.entries, hasLength(1));
    },
  );

  test(
    'updating active ID preserves activation and deleting it selects default',
    () async {
      final settings = SettingsProvider();
      await settings.loaded;
      await settings.importWebConversationStyles([makeStyle('one')]);
      await settings.setActiveWebConversationStyle('one');

      await settings.importWebConversationStyles([
        makeStyle('one', name: 'Updated', radius: 24),
      ]);
      expect(settings.activeWebConversationStyle?.name, 'Updated');
      expect(
        settings.activeWebConversationStyle?.resolveAppearance(isDark: false),
        {
          'userBubble': {'cornerRadius': 24.0},
        },
      );

      await settings.deleteWebConversationStyle('one');
      expect(settings.activeWebConversationStyle, isNull);
      expect(settings.webConversationStyleLibrary.entries, isEmpty);
    },
  );

  test(
    'style library participates in backup and LAN preference round-trip',
    () async {
      final settings = SettingsProvider();
      await settings.loaded;
      await settings.importWebConversationStyles([makeStyle('synced')]);
      await settings.setActiveWebConversationStyle('synced');
      await settings.setExperimentalWebViewRendering(true);

      final snapshot = await (await backup.SharedPreferencesAsync.instance)
          .snapshot();
      expect(snapshot, contains(webConversationStyleLibraryPreferenceKey));
      expect(snapshot, isNot(contains('experimental_webview_rendering_v1')));
      final encoded =
          snapshot[webConversationStyleLibraryPreferenceKey] as String;
      expect(WebConversationStyleLibrary.decode(encoded).activeId, 'synced');

      SharedPreferences.setMockInitialValues(const <String, Object>{});
      await (await backup.SharedPreferencesAsync.instance).restore({
        webConversationStyleLibraryPreferenceKey: encoded,
      });
      final restoredPrefs = await SharedPreferences.getInstance();
      expect(
        jsonDecode(
          restoredPrefs.getString(webConversationStyleLibraryPreferenceKey)!,
        ),
        jsonDecode(encoded),
      );
      final restored = SettingsProvider();
      await restored.loaded;
      expect(restored.activeWebConversationStyle?.id, 'synced');
    },
  );
}
