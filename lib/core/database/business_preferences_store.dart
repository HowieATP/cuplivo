import 'dart:async';

import 'dart:convert';

import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'business_repository.dart';

/// Storage backend abstraction for [BusinessPreferences].
///
/// Implementations:
/// - [SqliteBusinessStore] — production main isolate: `preference_rows` via
///   [BusinessRepository] (Drift).
/// - [RawSqliteBusinessStore] — background isolates (proactive-care alarm):
///   the same table via direct `sqlite3` on the shared DB file, no Drift.
/// - [MemoryBusinessStore] — tests: pure Dart map, no SQLite. Also the
///   backend behind `BusinessPreferences.memoryForTests`.
abstract interface class BusinessPreferencesStore {
  Future<List<BusinessPreferenceEntry>> readAll();

  Future<void> write(String key, Object value, {required int updatedAt});

  Future<void> remove(String key);

  Future<void> clear();
}

final class SqliteBusinessStore implements BusinessPreferencesStore {
  SqliteBusinessStore(this._repository);

  final BusinessRepository _repository;

  @override
  Future<List<BusinessPreferenceEntry>> readAll() => _repository.readAll();

  @override
  Future<void> write(String key, Object value, {required int updatedAt}) =>
      _repository.write(key, value, updatedAt: updatedAt);

  @override
  Future<void> remove(String key) => _repository.remove(key);

  @override
  Future<void> clear() => _repository.clearAll();
}

/// Direct-`sqlite3` store over the SAME `preference_rows` table, used by
/// background isolates that cannot ride the Drift connection (e.g. the
/// killed-process proactive-care alarm). WAL + busy_timeout mirror the Drift
/// executor's PRAGMAs; a SQLite transaction on the same file may briefly
/// block, but writes are rare and serialized by the facade write tail.
final class RawSqliteBusinessStore implements BusinessPreferencesStore {
  RawSqliteBusinessStore(this._database);

  final sqlite.Database _database;

  static const _upsertSql =
      'INSERT INTO preference_rows (key, value, updated_at) VALUES (?, ?, ?) '
      'ON CONFLICT(key) DO UPDATE SET value = excluded.value, '
      'updated_at = excluded.updated_at;';
  static const _readAllSql =
      'SELECT key, value, updated_at FROM preference_rows ORDER BY key;';

  @override
  Future<List<BusinessPreferenceEntry>> readAll() async {
    final rows = _database.select(_readAllSql);
    return List<BusinessPreferenceEntry>.unmodifiable(
      rows.map(
        (row) => BusinessPreferenceEntry(
          key: row['key'] as String,
          value: _decodeValue(row['value'] as String, row['key'] as String),
          updatedAt: row['updated_at'] as int,
        ),
      ),
    );
  }

  @override
  Future<void> write(String key, Object value, {required int updatedAt}) async {
    if (key.isEmpty) throw ArgumentError.value(key, 'key');
    final normalized = _normalizeValue(value);
    _database.execute(_upsertSql, [key, jsonEncode(normalized), updatedAt]);
  }

  @override
  Future<void> remove(String key) async {
    if (key.isEmpty) return;
    _database.execute('DELETE FROM preference_rows WHERE key = ?;', [key]);
  }

  @override
  Future<void> clear() async {
    _database.execute('DELETE FROM preference_rows;');
  }

  static Object _normalizeValue(Object value) {
    if (value is bool || value is int || value is double || value is String) {
      return value;
    }
    if (value is List && value.every((item) => item is String)) {
      return List<String>.unmodifiable(value.cast<String>());
    }
    throw ArgumentError('unsupported preference value type');
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
      return _normalizeValue(decoded);
    } on ArgumentError {
      throw StateError('business_preference_value:$key');
    }
  }
}

final class MemoryBusinessStore implements BusinessPreferencesStore {
  MemoryBusinessStore([Map<String, BusinessPreferenceEntry>? seed])
    : _entries = <String, BusinessPreferenceEntry>{...?seed};

  Map<String, BusinessPreferenceEntry> _entries;
  int _counter = 0;

  @override
  Future<List<BusinessPreferenceEntry>> readAll() async =>
      List<BusinessPreferenceEntry>.unmodifiable(_entries.values);

  @override
  Future<void> write(String key, Object value, {required int updatedAt}) async {
    _entries[key] = BusinessPreferenceEntry(
      key: key,
      value: value,
      updatedAt: updatedAt,
    );
  }

  @override
  Future<void> remove(String key) async {
    _entries.remove(key);
  }

  @override
  Future<void> clear() async {
    _entries = <String, BusinessPreferenceEntry>{};
  }

  /// Seeds a key without plumbing an explicit timestamp (tests that only
  /// need the value asserted on read).
  Future<void> seed(String key, Object value, {int? updatedAt}) =>
      write(key, value, updatedAt: updatedAt ?? ++_counter);
}
