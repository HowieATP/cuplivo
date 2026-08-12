import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/backup/data_sync.dart' as backup_sync;
import 'package:Cuplivo/core/services/backup/double_pref_keys.dart'
    show doublePrefKeys;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Poisoned ints mirroring kelivo-helper-migrated RikkaHub backups.
  // provider_configs_v1 settles the v3 migration so the v4 marker can
  // advance (the v4 normalization only finalizes once v3 is settled).
  Map<String, Object> poisonedPrefs() => {
    'provider_configs_v1': '{}',
    for (final key in doublePrefKeys) key: 1,
  };

  Future<void> waitForMigration(int expectedVersion) async {
    final prefs = await SharedPreferences.getInstance();
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (prefs.getInt('migrations_version_v1') != expectedVersion) {
      if (DateTime.now().isAfter(deadline)) {
        fail('Timed out waiting for migrations_version_v1 == $expectedVersion');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  /// Waits until `_load()` has progressed past the migration block
  /// (`app_locale_v1` is written later in the same method), proving the
  /// assertions below are not vacuous.
  Future<void> waitForLoadPastMigration() async {
    final prefs = await SharedPreferences.getInstance();
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (prefs.getString('app_locale_v1') != 'system') {
      if (DateTime.now().isAfter(deadline)) {
        fail('Timed out waiting for SettingsProvider._load to complete');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test(
    'v4 migration normalizes int-injected double keys and exports as double',
    () async {
      SharedPreferences.setMockInitialValues(poisonedPrefs());

      SettingsProvider();

      await waitForMigration(4);

      final prefs = await SharedPreferences.getInstance();
      for (final key in doublePrefKeys) {
        expect(prefs.getDouble(key), 1.0);
      }

      // Cuplivo exports now carry clean doubles, not poisoned ints.
      final snapshot = await (await backup_sync.SharedPreferencesAsync.instance)
          .snapshot();
      expect(snapshot['tts_speech_rate_v1'], 1.0);
      expect(snapshot['display_chat_background_mask_strength_v1'], 1.0);
    },
  );

  test(
    'v4 migration leaves existing doubles alone and skips missing keys',
    () async {
      SharedPreferences.setMockInitialValues({
        'provider_configs_v1': '{}',
        'tts_speech_rate_v1': 0.75,
        'display_chat_background_mask_strength_v1': 0.4,
      });

      SettingsProvider();

      await waitForMigration(4);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('tts_speech_rate_v1'), 0.75);
      expect(prefs.getDouble('display_chat_background_mask_strength_v1'), 0.4);
      expect(prefs.containsKey('tts_pitch_v1'), isFalse);
    },
  );

  test(
    'v4 migration is one-shot and does not rewrite after version 4',
    () async {
      SharedPreferences.setMockInitialValues({
        'migrations_version_v1': 4,
        ...poisonedPrefs(),
      });

      SettingsProvider();

      // Deterministic: wait until _load ran past the migration block, so the
      // assertions prove the version-4 guard, not a not-yet-run _load.
      await waitForLoadPastMigration();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('migrations_version_v1'), 4);
      for (final key in doublePrefKeys) {
        expect(prefs.get(key), isA<int>());
      }
    },
  );
}
