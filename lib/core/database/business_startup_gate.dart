import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

import 'business_migration_engine.dart';
import 'business_preferences.dart';
import 'business_preferences_store.dart';
import 'business_repository.dart';

/// Completes the one-time SharedPreferences → SQLite business migration
/// before the widget tree exposes any provider.
///
/// Runs in `main()` BEFORE `runApp` so no consumer ever observes an empty
/// business cache while legacy data still exists (the async gap). A
/// recoverable migration failure degrades to defaults but keeps the legacy
/// source — a fixed future build retries.
final class BusinessStartupGate {
  BusinessStartupGate._();

  /// Non-null when the last [migrateAndLoad] degraded a recoverable
  /// validation failure instead of migrating cleanly.
  static String? lastDegradedReason;

  static bool _isRecoverableMigrationFailure(Object error) =>
      error is StateError &&
      (error.message == 'business_migration_export_mismatch' ||
          error.message.startsWith('business_migration_count:') ||
          error.message.startsWith('business_preference_value:') ||
          error.message.startsWith('business_migration_cleanup:'));

  static Future<BusinessPreferences> migrateAndLoad({
    required BusinessRepository repository,
    required LegacyBusinessPreferences legacyPreferences,
    @visibleForTesting
    Future<BusinessMigrationResult> Function()? debugRunMigration,
  }) async {
    lastDegradedReason = null;
    try {
      await (debugRunMigration ??
          BusinessMigrationEngine(
            repository: repository,
            legacyPreferences: legacyPreferences,
          ).run)();
    } catch (error, stackTrace) {
      if (!_isRecoverableMigrationFailure(error)) rethrow;
      lastDegradedReason = (error as StateError).message;
      developer.log(
        'Business migration degraded; entering with defaults and retaining '
        'legacy data for a future retry.',
        name: 'Cuplivo.business.migration',
        error: error,
        stackTrace: stackTrace,
      );
      // The SQLite transaction rolled back for validation-class failures, so
      // the legacy store still holds the data; the facade opens empty.
      final preferences = BusinessPreferences.open(
        SqliteBusinessStore(repository),
      );
      await preferences.load();
      return preferences;
    }
    final preferences = BusinessPreferences.open(
      SqliteBusinessStore(repository),
    );
    await preferences.load();
    return preferences;
  }
}
