import 'package:flutter/foundation.dart' show visibleForTesting;

import 'business_key_registry.dart';
import 'business_preferences_store.dart';

/// In-memory synchronous key-value view over business preferences persisted
/// in SQLite (`preference_rows`).
///
/// Drop-in replacement for `SharedPreferences` for business keys: read
/// getters are synchronous, `set*`/`remove` are async and serialized through
/// a write tail; the in-memory view is updated only after the store write
/// succeeds (a failed write leaves the cache untouched).
///
/// One instance is created by the startup gate and injected through the
/// provider tree. Background isolates (proactive care alarm) construct their
/// own instance via [BusinessPreferences.open] against the same table — that
/// is the only sanctioned second instance.
///
/// Single-writer rule: `preference_rows` MUST NOT be written anywhere except
/// through this facade (or the migration/restore engine, which then calls
/// `reload()`). Direct writes elsewhere make the cache silently stale.
///
/// `BusinessKeyRegistry.localOnly` / `.discarded` / `.entity` keys are
/// rejected on write (localOnly remains the exclusive territory of
/// SharedPreferences). `BusinessKeyRegistry.providerOrder` is business data
/// and accepted.
final class BusinessPreferences {
  /// Opens a facade over [store] (production: [SqliteBusinessStore]). The
  /// caller must [load] (or await the gate) before reading.
  factory BusinessPreferences.open(BusinessPreferencesStore store) =>
      BusinessPreferences._(store);

  BusinessPreferences._(this._store);

  /// Memory-backed instance for tests, already [load]ed.
  @visibleForTesting
  static BusinessPreferences memoryForTests([
    Map<String, Object> seed = const {},
  ]) {
    final store = MemoryBusinessStore();
    final now = DateTime.now().toUtc().microsecondsSinceEpoch;
    final prefs = BusinessPreferences.open(store);
    for (final entry in seed.entries) {
      final value = _normalizeMockValue(entry.value);
      prefs._values[entry.key] = _copyForStorage(value);
      prefs._updatedAt[entry.key] = now;
      store.write(entry.key, value, updatedAt: now);
    }
    prefs._isLoaded = true;
    return prefs;
  }

  /// Runtime fallback when the SQLite store is unusable (background alarm
  /// isolate pre-migration fire): opens an empty memory-backed facade so the
  /// headless flow degrades gracefully instead of crashing. Persisted state is
  /// not read — a pre-migration fire has no business rows by definition.
  static Future<BusinessPreferences> memoryFallback() async {
    final prefs = BusinessPreferences.open(MemoryBusinessStore());
    prefs._isLoaded = true;
    return prefs;
  }

  final BusinessPreferencesStore _store;
  Map<String, Object> _values = <String, Object>{};
  Map<String, int> _updatedAt = <String, int>{};

  /// Lazy root of the serialized write chain: created in the zone of the
  /// FIRST write (testWidgets fake-async zones must never chain onto a
  /// future created in another zone — completion callbacks would land on the
  /// real microtask queue and hang). Production writes all happen on the
  /// main isolate after the startup gate, so laziness changes nothing there.
  Future<void>? _writeTail;
  Future<void>? _loadFuture;
  bool _isLoaded = false;
  bool _writesBlockedForRestore = false;

  static Object _normalizeMockValue(Object value) {
    if (value is bool || value is int || value is double || value is String) {
      return value;
    }
    if (value is List && value.every((item) => item is String)) {
      return List<String>.unmodifiable(value.cast<String>());
    }
    throw ArgumentError.value(value, 'SharedPreferences mock value');
  }

  /// The backend store instance (used by data_sync's `SharedPreferencesAsync`
  /// snapshot/restore helpers to read the same values the cache holds).
  BusinessPreferencesStore get store => _store;

  /// Awaits the one-time load from the store into the in-memory view.
  Future<void> load() {
    if (_isLoaded) return Future<void>.value();
    final inFlight = _loadFuture;
    if (inFlight != null) return inFlight;
    final future = _loadFromStore();
    _loadFuture = future;
    return future;
  }

  Future<void> _loadFromStore() async {
    final entries = await _store.readAll();
    _values = <String, Object>{
      for (final entry in entries) entry.key: entry.value,
    };
    _updatedAt = <String, int>{
      for (final entry in entries) entry.key: entry.updatedAt,
    };
    _isLoaded = true;
  }

  /// Re-reads the store into the cache (after a restore/import/migration
  /// rewrote the table). Keeps reads coherent after any external bulk write.
  Future<void> reload() async {
    await _loadFromStore();
  }

  /// Drains accepted writes, runs [operation] while write calls fail, then
  /// unblocks. Used by live restore so late background writes cannot shadow
  /// restored values.
  Future<T> runWithRestoreWriteFence<T>(Future<T> Function() operation) async {
    if (_writesBlockedForRestore) {
      throw StateError('business_preferences_restore_fence');
    }
    _writesBlockedForRestore = true;
    try {
      await _writeTail;
      return await operation();
    } finally {
      _writesBlockedForRestore = false;
    }
  }

  /// Awaits every write accepted so far (desktop exit hooks use this so the
  /// serialized queue reaches SQLite before process exit).
  Future<void> flushPendingWrites() {
    final tail = _writeTail;
    if (tail == null) return Future<void>.value();
    return tail;
  }

  bool get isLoaded => _isLoaded;

  Object? get(String key) => _copyForRead(_values[key]);
  bool containsKey(String key) => _values.containsKey(key);
  Set<String> getKeys() => Set<String>.unmodifiable(_values.keys);

  /// Last-write timestamp (microseconds UTC) for [key], or null.
  int? updatedAtFor(String key) => _updatedAt[key];

  /// Key → updatedAt for every key currently cached (settings_meta.json).
  Map<String, int> updatedAtMap() => Map<String, int>.unmodifiable(_updatedAt);

  bool? getBool(String key) => _values[key] as bool?;
  int? getInt(String key) => _values[key] as int?;

  double? getDouble(String key) {
    final value = _values[key];
    if (value is double) return value;
    if (value is int) return value.toDouble();
    return null;
  }

  String? getString(String key) => _values[key] as String?;

  List<String>? getStringList(String key) {
    final value = _values[key];
    if (value == null) return null;
    return List<String>.of((value as List).cast<String>());
  }

  Future<bool> setBool(String key, bool value) => _set(key, value);
  Future<bool> setInt(String key, int value) => _set(key, value);
  Future<bool> setDouble(String key, double value) => _set(key, value);
  Future<bool> setString(String key, String value) => _set(key, value);
  Future<bool> setStringList(String key, List<String> value) =>
      _set(key, List<String>.unmodifiable(value));

  Future<bool> _set(String key, Object value) {
    _validateKey(key);
    final store = _store;
    return _serialize(() async {
      final updatedAt = DateTime.now().toUtc().microsecondsSinceEpoch;
      await store.write(key, value, updatedAt: updatedAt);
      _values[key] = _copyForStorage(value);
      _updatedAt[key] = updatedAt;
      return true;
    });
  }

  Future<bool> remove(String key) {
    _validateKey(key);
    final store = _store;
    return _serialize(() async {
      await store.remove(key);
      _values.remove(key);
      _updatedAt.remove(key);
      return true;
    });
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    if (_writesBlockedForRestore) {
      return Future<T>.error(StateError('business_preferences_restore_fence'));
    }
    final tail = _writeTail ??= Future<void>.value();
    final result = tail.then((_) => operation());
    _writeTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  static void _validateKey(String key) {
    final disposition = BusinessKeyRegistry.classify(key);
    if (disposition == BusinessKeyDisposition.localOnly ||
        disposition == BusinessKeyDisposition.discarded ||
        disposition == BusinessKeyDisposition.entity) {
      throw ArgumentError.value(key, 'key', 'Not a business preference');
    }
  }

  static Object _copyForStorage(Object value) {
    if (value is List) return List<String>.unmodifiable(value.cast<String>());
    return value;
  }

  static Object? _copyForRead(Object? value) {
    if (value is List) return List<String>.of(value.cast<String>());
    return value;
  }
}
