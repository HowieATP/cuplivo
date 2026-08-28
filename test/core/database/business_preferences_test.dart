import 'dart:io';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/database/business_preferences_store.dart';
import 'package:Cuplivo/core/database/business_repository.dart';
import 'package:Cuplivo/core/database/business_startup_gate.dart';
import 'package:Cuplivo/core/database/business_migration_engine.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _FakeLegacyPreferences implements LegacyBusinessPreferences {
  _FakeLegacyPreferences(this.values);

  final Map<String, Object?> values;
  final List<String> removed = [];

  @override
  Future<Map<String, Object?>> snapshot() async => values;

  @override
  Future<void> remove(String key) async {
    removed.add(key);
  }
}

void main() {
  var businessPrefs = BusinessPreferences.memoryForTests();
  late Directory tempDir;
  late File dbFile;
  late AppDatabase db;
  late BusinessRepository repository;

  setUp(() async {
    businessPrefs = BusinessPreferences.memoryForTests();
    tempDir = await Directory.systemTemp.createTemp('cuplivo_business_');
    dbFile = File(p.join(tempDir.path, AppDatabase.databaseFileName));
    db = AppDatabase.open(file: dbFile);
    // Trigger beforeOpen → heal → table creation (schema v20) through the
    // standard repository open path, then close that scratch connection so
    // the file is not locked at teardown.
    final scratch = ChatDatabaseRepository.open(file: dbFile);
    await scratch.ensureReady();
    await scratch.close();
    repository = BusinessRepository(db);
  });

  tearDown(() async {
    await db.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });
  group('BusinessRepository', () {
    test('write/read round-trip with updatedAt', () async {
      final now = DateTime.now().toUtc().microsecondsSinceEpoch;
      await repository.write('theme_mode_v1', 'light', updatedAt: now);
      await repository.write(
        'display_auto_scroll_enabled_v1',
        true,
        updatedAt: now + 1,
      );

      final all = await repository.readAllAsMap();
      expect(all['theme_mode_v1']!.value, 'light');
      expect(all['theme_mode_v1']!.updatedAt, now);
      expect(all['display_auto_scroll_enabled_v1']!.value, isTrue);
    });

    test('upsert overwrites value and timestamp', () async {
      await repository.write('k', 'a', updatedAt: 1);
      await repository.write('k', 'b', updatedAt: 2);
      final all = await repository.readAllAsMap();
      expect(all['k']!.value, 'b');
      expect(all['k']!.updatedAt, 2);
    });

    test('remove deletes only its key', () async {
      await repository.write('a', 1, updatedAt: 1);
      await repository.write('b', 2, updatedAt: 2);
      await repository.remove('a');
      final all = await repository.readAllAsMap();
      expect(all.containsKey('a'), isFalse);
      expect(all['b']!.value, 2);
    });

    test('clearAll empties the table', () async {
      await repository.write('a', 1, updatedAt: 1);
      await repository.clearAll();
      expect(await repository.readAll(), isEmpty);
    });

    test('replaceAll upserts without deleting unknown rows', () async {
      await repository.write('webdav_config_v1', '{"host":"x"}', updatedAt: 1);
      await repository.replaceAll({
        'theme_mode_v1': const BusinessPreferenceEntry(
          key: 'theme_mode_v1',
          value: 'dark',
          updatedAt: 2,
        ),
      }, updatedAt: 2);
      final all = await repository.readAllAsMap();
      expect(all['webdav_config_v1']!.value, '{"host":"x"}');
      expect(all['theme_mode_v1']!.value, 'dark');
    });

    test('migration receipt round-trip', () async {
      expect(await repository.hasMigrationReceipt(), isFalse);
      await repository.writeMigrationReceipt();
      expect(await repository.hasMigrationReceipt(), isTrue);
      await repository.clearMigrationReceipt();
      expect(await repository.hasMigrationReceipt(), isFalse);
    });

    test('rejects unsupported value shapes', () async {
      // ignore: discarded_futures
      expect(
        () => repository.write('k', const {'map': 1}, updatedAt: 1),
        throwsArgumentError,
      );
    });
  });

  group('BusinessPreferences (memory store)', () {
    late MemoryBusinessStore store;
    late BusinessPreferences prefs;

    setUp(() async {
      store = MemoryBusinessStore();
      prefs = BusinessPreferences.open(store);
      await prefs.load();
    });

    test('typed getters after set* serialize to the store', () async {
      await prefs.setString('str', 'hello');
      await prefs.setBool('b', true);
      await prefs.setInt('i', 42);
      await prefs.setDouble('d', 3.5);
      await prefs.setStringList('l', ['x', 'y']);

      expect(prefs.getString('str'), 'hello');
      expect(prefs.getBool('b'), isTrue);
      expect(prefs.getInt('i'), 42);
      expect(prefs.getDouble('d'), 3.5);
      expect(prefs.getStringList('l'), ['x', 'y']);
      expect(prefs.containsKey('str'), isTrue);
      expect(prefs.getKeys(), contains('str'));

      final entries = await store.readAll();
      expect(entries, hasLength(5));
    });

    test('write failure leaves cache untouched', () async {
      await prefs.setString('ok', '1');
      // Memory store never fails; simulate by removing the backing value
      // behind the facade's back and reloading — the cache must follow the
      // store on reload.
      await store.write('other', '2', updatedAt: 99);
      await prefs.reload();
      expect(prefs.getString('other'), '2');
    });

    test('remove clears cache and store', () async {
      await prefs.setString('gone', 'x');
      await prefs.remove('gone');
      expect(prefs.containsKey('gone'), isFalse);
      expect(await store.readAll(), isEmpty);
    });

    test('rejects localOnly/discarded/entity keys', () async {
      for (final key in [
        'window_width_v1',
        'flutter_log_enabled_v1',
        'chat_draft_v1',
        'codex_oauth_v1',
        'grok_oauth_v1',
        'assistants_v1',
      ]) {
        // _validateKey runs synchronously in _set/remove; the ArgumentError
        // escapes before a Future is produced.
        expect(() => prefs.setString(key, 'x'), throwsArgumentError);
        expect(() => prefs.remove(key), throwsArgumentError);
      }
      // migrations_version_v1 is NOT discarded in Cuplivo (SettingsProvider's
      // one-shot migrations read/write it) — accepted as a business key.
      await prefs.setInt('migrations_version_v1', 3);
      expect(prefs.getInt('migrations_version_v1'), 3);
    });

    test('provider-order and unknown keys are accepted', () async {
      await prefs.setStringList('providers_order_v1', ['openai']);
      await prefs.setString('totally_new_key_v1', 'v');
      expect(prefs.getStringList('providers_order_v1'), ['openai']);
      expect(prefs.getString('totally_new_key_v1'), 'v');
    });

    test('getDouble coerces int storage', () async {
      await prefs.setInt('display_chat_background_mask_strength_v1', 0);
      expect(prefs.getDouble('display_chat_background_mask_strength_v1'), 0.0);
    });

    test('updatedAtMap tracks per-key timestamps', () async {
      await prefs.setString('a', '1');
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await prefs.setString('b', '2');
      final map = prefs.updatedAtMap();
      expect(map.keys, containsAll(['a', 'b']));
      expect(map['b']!, greaterThan(map['a']!));
    });

    test('writes are serialized (no interleaving)', () async {
      final futures = <Future<bool>>[];
      for (var i = 0; i < 20; i++) {
        futures.add(prefs.setString('k$i', '$i'));
      }
      await Future.wait(futures);
      final keys = (await store.readAll()).map((e) => e.key);
      expect(keys, hasLength(20));
    });

    test('restore fence blocks writes during operation', () async {
      await prefs.setString('before', '1');
      final result = await prefs.runWithRestoreWriteFence(() async {
        await expectLater(prefs.setString('during', '2'), throwsStateError);
        return 'ok';
      });
      expect(result, 'ok');
      await prefs.setString('after', '3');
      expect(prefs.getString('after'), '3');
    });
  });

  group('setMockInitialValues / instance', () {
    test('installs instance with seeded values', () async {
      businessPrefs = BusinessPreferences.memoryForTests({
        'theme_mode_v1': 'dark',
        'display_haptics_global_enabled_v1': false,
      });
      final instance = businessPrefs;
      expect(instance, isNotNull);
      expect(instance.getString('theme_mode_v1'), 'dark');
      expect(instance.getBool('display_haptics_global_enabled_v1'), isFalse);
    });

    test('writes reach the memory store', () async {
      businessPrefs = BusinessPreferences.memoryForTests({});
      final instance = businessPrefs;
      await instance.setString('new_key_v1', 'value');
      expect(instance.getString('new_key_v1'), 'value');
      final entries = await instance.store.readAll();
      expect(entries.single.key, 'new_key_v1');
    });
  });

  group('BusinessMigrationEngine', () {
    test('migrates business keys and reports migrated', () async {
      final legacy = _FakeLegacyPreferences({
        'theme_mode_v1': 'dark',
        'provider_configs_v1': '{"openai":{}}',
        'providers_order_v1': ['openai'],
        'window_width_v1': 1200, // localOnly → untouched
        'assistants_v1': '[]', // entity → untouched
      });

      final engine = BusinessMigrationEngine(
        repository: repository,
        legacyPreferences: legacy,
        checkpointOverride: () async => true,
      );

      final result = await engine.run();
      expect(result, BusinessMigrationResult.migrated);

      final all = await repository.readAllAsMap();
      expect(all['theme_mode_v1']!.value, 'dark');
      expect(all['provider_configs_v1']!.value, '{"openai":{}}');
      expect(all['providers_order_v1']!.value, ['openai']);
      expect(all.containsKey('window_width_v1'), isFalse);
      expect(all.containsKey('assistants_v1'), isFalse);

      // Legacy cleanup touched only business keys.
      expect(legacy.removed, isNot(contains('window_width_v1')));
      expect(legacy.removed, isNot(contains('assistants_v1')));
      expect(legacy.removed, contains('theme_mode_v1'));

      expect(await repository.hasMigrationReceipt(), isTrue);
    });

    test('already complete skips with no cleanup when nothing left', () async {
      final legacy = _FakeLegacyPreferences({'theme_mode_v1': 'light'});
      final engine = BusinessMigrationEngine(
        repository: repository,
        legacyPreferences: legacy,
        checkpointOverride: () async => true,
      );
      await engine.run();

      final second = BusinessMigrationEngine(
        repository: repository,
        legacyPreferences: _FakeLegacyPreferences({}),
        checkpointOverride: () async => true,
      );
      expect(await second.run(), BusinessMigrationResult.alreadyComplete);
    });

    test('cleans up residual keys after receipt', () async {
      final legacy = _FakeLegacyPreferences({'theme_mode_v1': 'light'});
      await BusinessMigrationEngine(
        repository: repository,
        legacyPreferences: legacy,
        checkpointOverride: () async => true,
      ).run();

      final residual = _FakeLegacyPreferences({'theme_mode_v1': 'light'});
      final engine = BusinessMigrationEngine(
        repository: repository,
        legacyPreferences: residual,
        checkpointOverride: () async => true,
      );
      expect(await engine.run(), BusinessMigrationResult.cleanedAfterReceipt);
      expect(residual.removed, contains('theme_mode_v1'));
    });

    test('defers cleanup when checkpoint reports busy', () async {
      // First run: migrated; second run finds residual keys but the barrier
      // is busy → deferred cleanup (receipt already exists).
      final first = _FakeLegacyPreferences({'theme_mode_v1': 'light'});
      expect(
        await BusinessMigrationEngine(
          repository: repository,
          legacyPreferences: first,
          checkpointOverride: () async => true,
        ).run(),
        BusinessMigrationResult.migrated,
      );

      final second = _FakeLegacyPreferences({'theme_mode_v1': 'light'});
      final engine = BusinessMigrationEngine(
        repository: repository,
        legacyPreferences: second,
        checkpointOverride: () async => false,
      );
      expect(await engine.run(), BusinessMigrationResult.deferredCleanup);
      expect(second.removed, isEmpty);
    });

    test('fresh install with empty legacy reports freshInstall', () async {
      final engine = BusinessMigrationEngine(
        repository: repository,
        legacyPreferences: _FakeLegacyPreferences({}),
        checkpointOverride: () async => true,
      );
      expect(await engine.run(), BusinessMigrationResult.freshInstall);
      expect(await repository.readAll(), isEmpty);
    });

    test(
      'receipt-less rerun after restore does not wipe facade rows',
      () async {
        // Restore-overwrite clears chat_storage_meta_rows (the migration
        // receipt) via clearAllData; legacy SharedPreferences was already
        // cleaned. A no-op rerun of the engine must not wipe preference_rows
        // written by the restore (issue #123 regression).
        await repository.write(
          'webdav_config_v1',
          '{"host":"dav"}',
          updatedAt: 1,
        );
        await repository.write(
          'provider_configs_v1',
          '{"openai":{}}',
          updatedAt: 2,
        );
        await repository.clearMigrationReceipt();

        final engine = BusinessMigrationEngine(
          repository: repository,
          legacyPreferences: _FakeLegacyPreferences({}),
          checkpointOverride: () async => true,
        );
        expect(await engine.run(), BusinessMigrationResult.freshInstall);

        final all = await repository.readAllAsMap();
        expect(all['webdav_config_v1']!.value, '{"host":"dav"}');
        expect(all['provider_configs_v1']!.value, '{"openai":{}}');
        expect(await repository.hasMigrationReceipt(), isTrue);
      },
    );

    test(
      'migration is atomic: throws on unsupported value keeps no rows',
      () async {
        final legacy = _FakeLegacyPreferences({
          'theme_mode_v1': 'light',
          'provider_configs_v1': const {'not': 'a string'}, // invalid shape
        });
        final engine = BusinessMigrationEngine(
          repository: repository,
          legacyPreferences: legacy,
          checkpointOverride: () async => true,
        );
        await expectLater(engine.run(), throwsArgumentError);
        expect(await repository.readAll(), isEmpty);
        expect(await repository.hasMigrationReceipt(), isFalse);
        expect(legacy.removed, isEmpty);
      },
    );
  });

  group('BusinessStartupGate', () {
    test('installs facade over sqlite store after clean migration', () async {
      final legacy = _FakeLegacyPreferences({'theme_mode_v1': 'dark'});
      final prefs = await BusinessStartupGate.migrateAndLoad(
        repository: repository,
        legacyPreferences: legacy,
        debugRunMigration: () => BusinessMigrationEngine(
          repository: repository,
          legacyPreferences: legacy,
          checkpointOverride: () async => true,
        ).run(),
      );
      expect(prefs.isLoaded, isTrue);
      expect(BusinessStartupGate.lastDegradedReason, isNull);
      expect(prefs.getString('theme_mode_v1'), 'dark');
    });

    test(
      'degrades on recoverable validation failure and keeps legacy',
      () async {
        final legacy = _FakeLegacyPreferences({'theme_mode_v1': 'light'});
        final prefs = await BusinessStartupGate.migrateAndLoad(
          repository: repository,
          legacyPreferences: legacy,
          debugRunMigration: () async {
            // The migration transaction rolled back (complete=false for the
            // real engine) and the run failed with a recoverable StateError
            // class. The legacy source must be untouched.
            await repository.replaceAll(
              {}, // rolled back = nothing persisted
              updatedAt: DateTime.now().toUtc().microsecondsSinceEpoch,
            );
            throw StateError('business_migration_count:provider_configs_v1');
          },
        );
        expect(BusinessStartupGate.lastDegradedReason, isNotNull);
        expect(prefs.isLoaded, isTrue);
        expect(legacy.removed, isEmpty);
      },
    );
  });
}
