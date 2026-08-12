import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/models/chat_input_data.dart';
import 'package:Cuplivo/core/services/backup/data_sync.dart' as backup_sync;
import 'package:Cuplivo/core/services/backup/double_pref_keys.dart'
    show doublePrefKeys;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SharedPreferencesAsync backup filter', () {
    test('snapshot excludes local-only keys', () async {
      SharedPreferences.setMockInitialValues({
        'display_chat_font_scale_v1': 1.3,
        'display_auto_scroll_enabled_v1': false,
        'desktop_hotkeys_commands_v1': [
          'close_window=cmd+w',
          'open_settings=cmd+comma',
        ],
        'desktop_hotkeys_enabled_v1': ['close_window=1', 'open_settings=1'],
        'codex_oauth_v1': '{"accessToken":"at","refreshToken":"rt"}',
      });

      final prefs = await backup_sync.SharedPreferencesAsync.instance;
      final snapshot = await prefs.snapshot();

      expect(snapshot.containsKey('display_chat_font_scale_v1'), isFalse);
      expect(snapshot.containsKey('desktop_hotkeys_commands_v1'), isFalse);
      expect(snapshot.containsKey('desktop_hotkeys_enabled_v1'), isFalse);
      expect(snapshot.containsKey('codex_oauth_v1'), isFalse);
      expect(snapshot['display_auto_scroll_enabled_v1'], isFalse);
    });

    test(
      'restore ignores chat font scale but restores synced settings',
      () async {
        SharedPreferences.setMockInitialValues({
          'display_chat_font_scale_v1': 1.15,
        });

        final prefs = await backup_sync.SharedPreferencesAsync.instance;
        await prefs.restore({
          'display_chat_font_scale_v1': 1.4,
          'display_auto_scroll_enabled_v1': false,
        });

        final rawPrefs = await SharedPreferences.getInstance();
        expect(rawPrefs.getDouble('display_chat_font_scale_v1'), 1.15);
        expect(rawPrefs.getBool('display_auto_scroll_enabled_v1'), isFalse);
      },
    );

    test('restoreSingle ignores old backup chat font scale entries', () async {
      SharedPreferences.setMockInitialValues({
        'display_chat_font_scale_v1': 0.95,
      });

      final prefs = await backup_sync.SharedPreferencesAsync.instance;
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

      final prefs = await backup_sync.SharedPreferencesAsync.instance;
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

      final prefs = await backup_sync.SharedPreferencesAsync.instance;
      await prefs.restore({
        'codex_oauth_v1': '{"accessToken":"new"}',
        'display_auto_scroll_enabled_v1': true,
      });

      final rawPrefs = await SharedPreferences.getInstance();
      expect(rawPrefs.getString('codex_oauth_v1'), '{"accessToken":"old"}');
      expect(rawPrefs.getBool('display_auto_scroll_enabled_v1'), isTrue);
    });

    test('restoreSingle ignores codex oauth credential entries', () async {
      SharedPreferences.setMockInitialValues({
        'codex_oauth_v1': '{"accessToken":"old"}',
      });

      final prefs = await backup_sync.SharedPreferencesAsync.instance;
      await prefs.restoreSingle('codex_oauth_v1', '{"accessToken":"new"}');

      final rawPrefs = await SharedPreferences.getInstance();
      expect(rawPrefs.getString('codex_oauth_v1'), '{"accessToken":"old"}');
    });

    test('snapshot excludes the chat input draft key', () async {
      SharedPreferences.setMockInitialValues({
        chatInputDraftPrefsKey: '{"text":"unsent"}',
        'display_auto_scroll_enabled_v1': true,
      });

      final prefs = await backup_sync.SharedPreferencesAsync.instance;
      final snapshot = await prefs.snapshot();

      expect(snapshot.containsKey(chatInputDraftPrefsKey), isFalse);
      expect(snapshot['display_auto_scroll_enabled_v1'], isTrue);
    });

    test('restore ignores the chat input draft key', () async {
      SharedPreferences.setMockInitialValues({
        chatInputDraftPrefsKey: '{"text":"local draft"}',
      });

      final prefs = await backup_sync.SharedPreferencesAsync.instance;
      await prefs.restore({
        chatInputDraftPrefsKey: '{"text":"remote stale draft"}',
        'display_auto_scroll_enabled_v1': true,
      });

      final rawPrefs = await SharedPreferences.getInstance();
      expect(
        rawPrefs.getString(chatInputDraftPrefsKey),
        '{"text":"local draft"}',
      );
      expect(rawPrefs.getBool('display_auto_scroll_enabled_v1'), isTrue);
    });

    test(
      'restore normalizes int-injected double-typed keys to double',
      () async {
        SharedPreferences.setMockInitialValues(const {
          'display_auto_scroll_enabled_v1': false,
        });

        final prefs = await backup_sync.SharedPreferencesAsync.instance;
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

        final rawPrefs = await SharedPreferences.getInstance();
        for (final key in doublePrefKeys) {
          expect(rawPrefs.getDouble(key), isA<double>());
        }
        expect(rawPrefs.getDouble('tts_speech_rate_v1'), 1.0);
        expect(rawPrefs.getDouble('tts_pitch_v1'), 1.0);
        expect(
          rawPrefs.getDouble('display_chat_background_mask_strength_v1'),
          0.0,
        );
        expect(
          rawPrefs.getDouble('display_chat_input_background_opacity_light_v1'),
          0.5,
        );
        expect(
          rawPrefs.getDouble('display_chat_input_background_opacity_dark_v1'),
          -1.0,
        );
        expect(rawPrefs.getDouble('desktop_sidebar_width_v1'), 1.0);
        expect(rawPrefs.getDouble('desktop_right_sidebar_width_v1'), 2.0);
        // Non-double-typed int keys keep their int type.
        expect(rawPrefs.getInt('some_regular_int_key_v1'), 42);
      },
    );

    test(
      'restoreSingle normalizes int-injected double-typed keys to double',
      () async {
        SharedPreferences.setMockInitialValues(const {
          'display_auto_scroll_enabled_v1': false,
        });

        final prefs = await backup_sync.SharedPreferencesAsync.instance;
        for (final key in doublePrefKeys) {
          await prefs.restoreSingle(key, 1);
        }
        await prefs.restoreSingle('some_regular_int_key_v1', 42);

        final rawPrefs = await SharedPreferences.getInstance();
        for (final key in doublePrefKeys) {
          expect(rawPrefs.getDouble(key), 1.0);
        }
        expect(rawPrefs.getInt('some_regular_int_key_v1'), 42);
      },
    );
  });
}
