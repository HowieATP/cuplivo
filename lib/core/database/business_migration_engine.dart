import 'dart:developer' as developer;

import 'package:shared_preferences/shared_preferences.dart';

import 'business_key_registry.dart';
import 'business_repository.dart';

/// Legacy (SharedPreferences) source abstraction for the one-shot migration.
abstract interface class LegacyBusinessPreferences {
  Future<Map<String, Object?>> snapshot();

  Future<void> remove(String key);
}

final class SharedPreferencesLegacyBusinessPreferences
    implements LegacyBusinessPreferences {
  SharedPreferencesLegacyBusinessPreferences(this._preferences);

  final SharedPreferences _preferences;

  static Future<SharedPreferencesLegacyBusinessPreferences> open() async =>
      SharedPreferencesLegacyBusinessPreferences(
        await SharedPreferences.getInstance(),
      );

  @override
  Future<Map<String, Object?>> snapshot() async => {
    for (final key in _preferences.getKeys()) key: _preferences.get(key),
  };

  @override
  Future<void> remove(String key) async {
    if (_preferences.containsKey(key) && !await _preferences.remove(key)) {
      throw StateError('business_migration_cleanup:$key');
    }
  }
}

enum BusinessMigrationResult {
  migrated,
  freshInstall,
  alreadyComplete,
  cleanedAfterReceipt,
  deferredCleanup,
}

/// One-shot SharedPreferences → `preference_rows` migration (issue #123).
///
/// Contract: the legacy data is only deleted from SharedPreferences AFTER a
/// receipt exists AND a WAL FULL checkpoint (durability barrier) succeeds.
/// Failure of the write transaction or the round-trip validation rolls back
/// everything and keeps the legacy source intact — the next launch retries.
final class BusinessMigrationEngine {
  BusinessMigrationEngine({
    required this.repository,
    required this.legacyPreferences,
    this.checkpointOverride,
  });

  final BusinessRepository repository;
  final LegacyBusinessPreferences legacyPreferences;
  final Future<bool> Function()? checkpointOverride;

  Future<BusinessMigrationResult> run() async {
    final legacy = await legacyPreferences.snapshot();
    final cleanupKeys = _cleanupKeys(legacy.keys);

    if (await repository.hasMigrationReceipt()) {
      if (cleanupKeys.isEmpty) return BusinessMigrationResult.alreadyComplete;
      if (!await _durabilityBarrierAchieved()) {
        return BusinessMigrationResult.deferredCleanup;
      }
      await _cleanup(cleanupKeys);
      return BusinessMigrationResult.cleanedAfterReceipt;
    }

    final hasBusinessData = cleanupKeys.isNotEmpty;

    await repository.replaceAll({
      for (final key in cleanupKeys)
        key: _entryForEncoding(
          key,
          legacy[key],
          DateTime.now().toUtc().microsecondsSinceEpoch,
        ),
    }, updatedAt: DateTime.now().toUtc().microsecondsSinceEpoch);
    await repository.writeMigrationReceipt();

    if (await _durabilityBarrierAchieved()) {
      await _cleanup(cleanupKeys);
    }

    return hasBusinessData
        ? BusinessMigrationResult.migrated
        : BusinessMigrationResult.freshInstall;
  }

  static BusinessPreferenceEntry _entryForEncoding(
    String key,
    Object? value,
    int updatedAt,
  ) {
    final normalized = _normalizeLegacyValue(value);
    return BusinessPreferenceEntry(
      key: key,
      value: normalized,
      updatedAt: updatedAt,
    );
  }

  static Object _normalizeLegacyValue(Object? value) {
    final Object normalized;
    if (value is bool) {
      normalized = value;
    } else if (value is int) {
      normalized = value;
    } else if (value is double) {
      normalized = value;
    } else if (value is String) {
      normalized = value;
    } else if (value is List && value.every((item) => item is String)) {
      normalized = List<String>.unmodifiable(value.cast<String>());
    } else if (value == null) {
      normalized = '';
    } else {
      // Any other shape cannot round-trip through preference_rows; surface
      // it so the migration fails loudly rather than silently dropping it.
      throw ArgumentError('unsupported legacy preference value type');
    }
    return normalized;
  }

  /// Keys eligible for migration/cleanup: everything except localOnly,
  /// discarded and entity (assistants_v1 has its own typed table + wire path
  /// in data_sync; ocr_enabled_v1 stays because assistant_provider still
  /// consumes it from SharedPreferences during its own one-shot migration).
  static Set<String> _cleanupKeys(Iterable<String> keys) => {
    for (final key in keys)
      if (BusinessKeyRegistry.classify(key) ==
              BusinessKeyDisposition.preference ||
          BusinessKeyRegistry.classify(key) ==
              BusinessKeyDisposition.unknownPreference ||
          BusinessKeyRegistry.classify(key) ==
              BusinessKeyDisposition.providerOrder)
        key,
  };

  Future<bool> _durabilityBarrierAchieved() async {
    try {
      return await (checkpointOverride ?? repository.checkpoint)();
    } catch (error, stackTrace) {
      developer.log(
        'Business migration durability barrier failed; deferring legacy cleanup.',
        name: 'Cuplivo.business.migration',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  Future<void> _cleanup(Set<String> keys) async {
    final ordered = keys.toList()..sort();
    for (final key in ordered) {
      await legacyPreferences.remove(key);
    }
  }
}
