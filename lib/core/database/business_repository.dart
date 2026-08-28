import 'dart:convert';

import 'package:drift/drift.dart';

import 'app_database.dart';

/// A single stored preference value with its last-write timestamp.
final class BusinessPreferenceEntry {
  const BusinessPreferenceEntry({
    required this.key,
    required this.value,
    required this.updatedAt,
  });

  final String key;

  /// Typed Dart value: bool, int, double, String or List of strings.
  final Object value;

  /// Microseconds since epoch (UTC) of the last write.
  final int updatedAt;
}

/// Key-value CRUD over `preference_rows` (issue #123).
///
/// The single writer of the table is [BusinessPreferences]; [BusinessRepository]
/// exposes the raw storage operations the facade composes (snapshot,
/// transactional replace, receipt for the one-shot migration).
final class BusinessRepository {
  BusinessRepository(this._database);

  static const migrationReceiptKey = 'business_migration_complete_v1';

  final AppDatabase _database;

  bool sharesDatabaseIdentity(Object identity) =>
      identical(_database, identity);

  Future<List<BusinessPreferenceEntry>> readAll() async {
    final rows = await _database
        .customSelect(
          'SELECT key, value, updated_at FROM preference_rows ORDER BY key;',
          readsFrom: {_database.preferenceRows},
        )
        .get();
    return List<BusinessPreferenceEntry>.unmodifiable(
      rows.map(
        (row) => BusinessPreferenceEntry(
          key: row.read<String>('key'),
          value: _decodeValue(
            row.read<String>('value'),
            row.read<String>('key'),
          ),
          updatedAt: row.read<int>('updated_at'),
        ),
      ),
    );
  }

  Future<Map<String, BusinessPreferenceEntry>> readAllAsMap() async {
    final entries = await readAll();
    return <String, BusinessPreferenceEntry>{
      for (final entry in entries) entry.key: entry,
    };
  }

  Future<void> write(String key, Object value, {required int updatedAt}) async {
    if (key.isEmpty) throw ArgumentError.value(key, 'key');
    final normalized = _normalizeValue(value, key);
    await _database.customStatement(
      'INSERT INTO preference_rows (key, value, updated_at) VALUES (?, ?, ?) '
      'ON CONFLICT(key) DO UPDATE SET value = excluded.value, '
      'updated_at = excluded.updated_at;',
      <Object?>[key, jsonEncode(normalized), updatedAt],
    );
  }

  Future<void> remove(String key) async {
    if (key.isEmpty) return;
    await _database.customStatement(
      'DELETE FROM preference_rows WHERE key = ?;',
      <Object?>[key],
    );
  }

  Future<void> clearAll() =>
      _database.customStatement('DELETE FROM preference_rows;');

  /// Upserts [entries] without touching any existing row.
  ///
  /// The migration engine only knows legacy SharedPreferences keys, so it
  /// must never destroy rows written through the facade: a receipt-less
  /// relaunch after a restore overwrite (which clears `chatStorageMetaRows`
  /// via `clearAllData`) would otherwise wipe the whole table and insert
  /// nothing, resetting every preference.
  Future<void> replaceAll(
    Map<String, BusinessPreferenceEntry> entries, {
    required int updatedAt,
  }) => _database.transaction(() async {
    for (final entry in entries.values) {
      await write(entry.key, entry.value, updatedAt: updatedAt);
    }
  });

  /// Returns false when `PRAGMA wal_checkpoint(FULL)` reports `busy != 0`.
  Future<bool> checkpoint() async {
    final row = await _database
        .customSelect('PRAGMA wal_checkpoint(FULL);')
        .getSingle();
    return row.read<int>('busy') == 0;
  }

  Future<bool> hasMigrationReceipt() async {
    final row = await _database
        .customSelect(
          'SELECT value FROM chat_storage_meta_rows WHERE key = ?;',
          variables: const [Variable<String>(migrationReceiptKey)],
          readsFrom: {_database.chatStorageMetaRows},
        )
        .getSingleOrNull();
    if (row == null) return false;
    return row.read<String>('value') == 'true';
  }

  Future<void> writeMigrationReceipt() => _database.transaction(
    () => _database.customStatement(
      'INSERT INTO chat_storage_meta_rows (key, value) VALUES (?, ?) '
      'ON CONFLICT(key) DO UPDATE SET value = excluded.value;',
      <Object?>[migrationReceiptKey, 'true'],
    ),
  );

  Future<void> clearMigrationReceipt() => _database.customStatement(
    'DELETE FROM chat_storage_meta_rows WHERE key = ?;',
    <Object?>[migrationReceiptKey],
  );

  static Object _normalizeValue(Object value, String key) {
    if (value is bool || value is int || value is double || value is String) {
      return value;
    }
    if (value is List && value.every((item) => item is String)) {
      return List<String>.unmodifiable(value.cast<String>());
    }
    throw ArgumentError.value(value, key);
  }

  static Object _decodeValue(String encoded, String key) {
    final Object? decoded;
    try {
      decoded = jsonDecode(encoded);
    } on FormatException {
      throw StateError('business_preference_value:$key');
    }
    if (decoded == null) throw StateError('business_preference_value:$key');
    try {
      return _normalizeValue(decoded, key);
    } on ArgumentError {
      throw StateError('business_preference_value:$key');
    }
  }
}
