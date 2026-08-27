import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/models/chat_input_data.dart';
import 'package:Cuplivo/core/services/backup/data_sync.dart' as backup_sync;
import 'package:Cuplivo/core/services/backup/double_pref_keys.dart'
    show doublePrefKeys;

void main() {
  var businessPrefs = BusinessPreferences.memoryForTests();
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SharedPreferencesAsync backup filter', () {
    test('snapshot excludes local-only keys', () async {
      businessPrefs = BusinessPreferences.memoryForTests({
        'display_auto_scroll_enabled_v1': false,
      });

      final prefs = backup_sync.SharedPreferencesAsync(businessPrefs);
      final snapshot = await prefs.snapshot();

      expect(snapshot['display_auto_scroll_enabled_v1'], isFalse);
      for (final localOnlyKey in <String>[
        'display_chat_font_scale_v1',
        'desktop_hotkeys_commands_v1',
        'desktop_hotkeys_enabled_v1',
        'codex_oauth_v1',
        chatInputDraftPrefsKey,
        'workspaces_dir_v1',
      ]) {
        expect(
          snapshot.containsKey(localOnlyKey),
          isFalse,
          reason: '$localOnlyKey must never enter backups',
        );
      }
    });

    test(
      'restore ignores chat font scale but restores synced settings',
      () async {
        SharedPreferences.setMockInitialValues({
          'display_chat_font_scale_v1': 1.15,
        });

        final prefs = backup_sync.SharedPreferencesAsync(businessPrefs);
        await prefs.restore({
          'display_chat_font_scale_v1': 1.4,
          'display_auto_scroll_enabled_v1': false,
        });

        final rawPrefs = await SharedPreferences.getInstance();
        expect(rawPrefs.getDouble('display_chat_font_scale_v1'), 1.15);
        expect(
          businessPrefs.getBool('display_auto_scroll_enabled_v1'),
          isFalse,
        );
      },
    );

    test('restoreSingle ignores old backup chat font scale entries', () async {
      SharedPreferences.setMockInitialValues({
        'display_chat_font_scale_v1': 0.95,
      });

      final prefs = backup_sync.SharedPreferencesAsync(businessPrefs);
      await prefs.restoreSingle('display_chat_font_scale_v1', 1.5);

      final rawPrefs = await SharedPreferences.getInstance();
      expect(rawPrefs.getDouble('display_chat_font_scale_v1'), 0.95);
    });

    test('restore ignores platform-specific desktop hotkey entries', () async {
      SharedPreferences.setMockInitialValues({
        'desktop_hotkeys_commands_v1': [
          'close_window=ctrl+w',
          'open_settings=ctrl+comma',
        ],
        'desktop_hotkeys_enabled_v1': ['close_window=1', 'open_settings=0'],
      });

      final prefs = backup_sync.SharedPreferencesAsync(businessPrefs);
      await prefs.restore({
        'desktop_hotkeys_commands_v1': [
          'close_window=cmd+w',
          'open_settings=cmd+comma',
        ],
        'desktop_hotkeys_enabled_v1': ['close_window=1', 'open_settings=1'],
      });

      final rawPrefs = await SharedPreferences.getInstance();
      expect(rawPrefs.getStringList('desktop_hotkeys_commands_v1'), [
        'close_window=ctrl+w',
        'open_settings=ctrl+comma',
      ]);
      expect(rawPrefs.getStringList('desktop_hotkeys_enabled_v1'), [
        'close_window=1',
        'open_settings=0',
      ]);
    });

    test('restore ignores codex oauth credential entries', () async {
      SharedPreferences.setMockInitialValues({
        'codex_oauth_v1': '{"accessToken":"old"}',
      });

      final prefs = backup_sync.SharedPreferencesAsync(businessPrefs);
      await prefs.restore({
        'codex_oauth_v1': '{"accessToken":"new"}',
        'display_auto_scroll_enabled_v1': true,
      });

      final rawPrefs = await SharedPreferences.getInstance();
      expect(rawPrefs.getString('codex_oauth_v1'), '{"accessToken":"old"}');
      expect(businessPrefs.getBool('display_auto_scroll_enabled_v1'), isTrue);
    });

    test('restoreSingle ignores codex oauth credential entries', () async {
      SharedPreferences.setMockInitialValues({
        'codex_oauth_v1': '{"accessToken":"old"}',
      });

      final prefs = backup_sync.SharedPreferencesAsync(businessPrefs);
      await prefs.restoreSingle('codex_oauth_v1', '{"accessToken":"new"}');

      final rawPrefs = await SharedPreferences.getInstance();
      expect(rawPrefs.getString('codex_oauth_v1'), '{"accessToken":"old"}');
    });

    test('snapshot excludes the chat input draft key', () async {
      businessPrefs = BusinessPreferences.memoryForTests({
        'display_auto_scroll_enabled_v1': true,
      });

      final prefs = backup_sync.SharedPreferencesAsync(businessPrefs);
      final snapshot = await prefs.snapshot();

      expect(snapshot.containsKey(chatInputDraftPrefsKey), isFalse);
      expect(snapshot['display_auto_scroll_enabled_v1'], isTrue);
    });

    test('restore ignores the chat input draft key', () async {
      SharedPreferences.setMockInitialValues({
        chatInputDraftPrefsKey: '{"text":"local draft"}',
      });

      final prefs = backup_sync.SharedPreferencesAsync(businessPrefs);
      await prefs.restore({
        chatInputDraftPrefsKey: '{"text":"remote stale draft"}',
        'display_auto_scroll_enabled_v1': true,
      });

      final rawPrefs = await SharedPreferences.getInstance();
      expect(
        rawPrefs.getString(chatInputDraftPrefsKey),
        '{"text":"local draft"}',
      );
      expect(businessPrefs.getBool('display_auto_scroll_enabled_v1'), isTrue);
    });

    test(
      'restore normalizes int-injected double-typed keys to double',
      () async {
        businessPrefs = BusinessPreferences.memoryForTests({
          'display_auto_scroll_enabled_v1': false,
        });

        final prefs = backup_sync.SharedPreferencesAsync(businessPrefs);
        await prefs.restore({
          // Poisoned ints from kelivo-helper-migrated RikkaHub backups.
          for (final key in doublePrefKeys) key: 1,
          // Boundary ints must normalize too.
          'display_chat_background_mask_strength_v1': 0,
          'display_chat_input_background_opacity_dark_v1': -1,
          // Already-double values pass through unchanged.
          'display_chat_input_background_opacity_light_v1': 0.5,
          'desktop_right_sidebar_width_v1': 2.0,
          'some_regular_int_key_v1': 42,
        });

        for (final key in doublePrefKeys) {
          expect(businessPrefs.getDouble(key), isA<double>(), reason: key);
        }
        expect(businessPrefs.getDouble('tts_speech_rate_v1'), 1.0);
        expect(businessPrefs.getDouble('tts_pitch_v1'), 1.0);
        expect(
          businessPrefs.getDouble('display_chat_background_mask_strength_v1'),
          0.0,
        );
        expect(
          businessPrefs.getDouble(
            'display_chat_input_background_opacity_light_v1',
          ),
          0.5,
        );
        expect(
          businessPrefs.getDouble(
            'display_chat_input_background_opacity_dark_v1',
          ),
          -1.0,
        );
        expect(businessPrefs.getDouble('desktop_sidebar_width_v1'), 1.0);
        expect(businessPrefs.getDouble('desktop_right_sidebar_width_v1'), 2.0);
        // Non-double-typed int keys keep their int type.
        expect(businessPrefs.getInt('some_regular_int_key_v1'), 42);
      },
    );

    test(
      'restoreSingle normalizes int-injected double-typed keys to double',
      () async {
        businessPrefs = BusinessPreferences.memoryForTests({
          'display_auto_scroll_enabled_v1': false,
        });

        final prefs = backup_sync.SharedPreferencesAsync(businessPrefs);
        for (final key in doublePrefKeys) {
          await prefs.restoreSingle(key, 1);
        }
        await prefs.restoreSingle('some_regular_int_key_v1', 42);

        for (final key in doublePrefKeys) {
          expect(businessPrefs.getDouble(key), 1.0, reason: key);
        }
        expect(businessPrefs.getInt('some_regular_int_key_v1'), 42);
      },
    );
  });
}
