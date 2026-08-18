import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/world_book.dart';

class WorldBookStore {
  static const String _itemsKey = 'world_books_v1';
  static const String _activeIdsByAssistantKey =
      'world_books_active_ids_by_assistant_v1';
  static const String _collapsedBooksKey = 'world_books_collapsed_v1';
  static const String _defaultAssistantKey = '__global__';

  static List<WorldBook>? _cache;
  static Map<String, List<String>>? _activeIdsByAssistantCache;
  static Map<String, bool>? _collapsedBooksCache;

  static String assistantKey(String? assistantId) {
    final id = (assistantId ?? '').trim();
    return id.isEmpty ? _defaultAssistantKey : id;
  }

  static List<String> _cleanIds(Iterable<dynamic> ids) {
    return ids
        .map((e) => e.toString().trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList(growable: false);
  }

  static List<WorldBook> _decodeItems(String? raw) {
    if (raw == null || raw.isEmpty) return const <WorldBook>[];
    final list = jsonDecode(raw) as List;
    return list
        .whereType<Map>()
        .map((e) => WorldBook.fromJson(e.cast<String, dynamic>()))
        .toList(growable: true);
  }

  static Map<String, List<String>> _decodeActiveIdsMap(String? raw) {
    final map = <String, List<String>>{};
    if (raw == null || raw.isEmpty) return map;
    final decoded = jsonDecode(raw) as Map;
    decoded.forEach((key, value) {
      final list = (value is List) ? value : const [];
      map[key.toString()] = _cleanIds(list);
    });
    return map;
  }

  static List<String> _activeIdsForAssistant(
    Map<String, List<String>> map,
    String? assistantId,
  ) {
    final key = assistantKey(assistantId);
    if (map.containsKey(key)) return List<String>.from(map[key]!);
    final fallback = map[_defaultAssistantKey];
    return fallback == null ? const <String>[] : List<String>.from(fallback);
  }

  static Map<String, List<String>> _cloneActiveIdsMap(
    Map<String, List<String>> src,
  ) {
    return {for (final e in src.entries) e.key: List<String>.from(e.value)};
  }

  static Map<String, bool> _cloneCollapsedBooksMap(Map<String, bool> src) {
    return {for (final e in src.entries) e.key: e.value};
  }

  static Future<List<WorldBook>> getAll() async {
    if (_cache != null) return List<WorldBook>.from(_cache!);
    final prefs = await SharedPreferences.getInstance();
    try {
      _cache = _decodeItems(prefs.getString(_itemsKey));
      return List<WorldBook>.from(_cache!);
    } catch (_) {
      _cache = const <WorldBook>[];
      return const <WorldBook>[];
    }
  }

  static Future<void> save(List<WorldBook> items) async {
    _cache = List<WorldBook>.from(items);
    final prefs = await SharedPreferences.getInstance();
    final json = jsonEncode(
      items.map((e) => e.toJson()).toList(growable: false),
    );
    await prefs.setString(_itemsKey, json);
  }

  static Future<void> add(WorldBook item) async {
    final all = await getAll();
    all.add(item);
    await save(all);
  }

  static Future<void> update(WorldBook item) async {
    final all = await getAll();
    final index = all.indexWhere((e) => e.id == item.id);
    if (index != -1) {
      all[index] = item;
      await save(all);
    }
  }

  static Future<void> delete(String id) async {
    final all = await getAll();
    all.removeWhere((e) => e.id == id);
    await save(all);

    // Remove from active map
    try {
      final map = await _loadActiveIdsMap();
      bool removed = false;
      final next = <String, List<String>>{};
      for (final entry in map.entries) {
        final filtered = entry.value
            .where((e) => e != id)
            .toList(growable: false);
        if (filtered.length != entry.value.length) removed = true;
        next[entry.key] = filtered;
      }
      if (removed) await _persistActiveIdsMap(next);
    } catch (_) {}

    try {
      final collapsed = await _loadCollapsedBooksMap();
      if (collapsed.remove(id) != null) {
        await _persistCollapsedBooksMap(collapsed);
      }
    } catch (_) {}
  }

  static Future<void> clear() async {
    _cache = const <WorldBook>[];
    _activeIdsByAssistantCache = const <String, List<String>>{};
    _collapsedBooksCache = const <String, bool>{};
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_itemsKey);
    await prefs.remove(_activeIdsByAssistantKey);
    await prefs.remove(_collapsedBooksKey);
  }

  static Future<void> reorder({
    required int oldIndex,
    required int newIndex,
  }) async {
    final list = await getAll();
    if (list.isEmpty) return;
    if (oldIndex < 0 || oldIndex >= list.length) return;
    if (newIndex < 0 || newIndex >= list.length) return;
    final item = list.removeAt(oldIndex);
    list.insert(newIndex, item);
    await save(list);
  }

  static Future<List<String>> getActiveIds({String? assistantId}) async {
    final map = await _loadActiveIdsMap();
    return _activeIdsForAssistant(map, assistantId);
  }

  /// Reads the world-book selection from persistent storage without using
  /// this isolate's static or SharedPreferences caches.
  ///
  /// Android alarm callbacks can reuse one background isolate across multiple
  /// invocations. Reloading here ensures edits made by the foreground isolate
  /// after an earlier alarm are visible to the next headless request.
  static Future<({List<WorldBook> books, List<String> activeBookIds})>
  loadFreshForAssistant({String? assistantId}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final books = _decodeItems(prefs.getString(_itemsKey));
    final activeIdsMap = _decodeActiveIdsMap(
      prefs.getString(_activeIdsByAssistantKey),
    );
    return (
      books: books,
      activeBookIds: _activeIdsForAssistant(activeIdsMap, assistantId),
    );
  }

  static Future<Map<String, List<String>>> getActiveIdsByAssistant() async {
    final map = await _loadActiveIdsMap();
    return _cloneActiveIdsMap(map);
  }

  static Future<void> setActiveIds(
    List<String> ids, {
    String? assistantId,
  }) async {
    final key = assistantKey(assistantId);
    final clean = _cleanIds(ids);
    final map = await _loadActiveIdsMap();
    map[key] = clean;
    await _persistActiveIdsMap(map);
  }

  static Future<void> setActiveIdsMap(Map<String, List<String>> map) async {
    final next = <String, List<String>>{};
    map.forEach((key, value) {
      next[key] = _cleanIds(value).toList(growable: false);
    });
    await _persistActiveIdsMap(next);
  }

  static Future<Map<String, bool>> getCollapsedBooksMap() async {
    final map = await _loadCollapsedBooksMap();
    return _cloneCollapsedBooksMap(map);
  }

  static Future<void> setCollapsed(String bookId, bool collapsed) async {
    final id = bookId.trim();
    if (id.isEmpty) return;
    final map = await _loadCollapsedBooksMap();
    map[id] = collapsed;
    await _persistCollapsedBooksMap(map);
  }

  static Future<void> setCollapsedMap(Map<String, bool> map) async {
    final next = <String, bool>{};
    map.forEach((key, value) {
      final id = key.trim();
      if (id.isEmpty) return;
      next[id] = value;
    });
    await _persistCollapsedBooksMap(next);
  }

  static Future<Map<String, List<String>>> _loadActiveIdsMap() async {
    if (_activeIdsByAssistantCache != null) {
      return _cloneActiveIdsMap(_activeIdsByAssistantCache!);
    }
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_activeIdsByAssistantKey);
    Map<String, List<String>> map;
    try {
      map = _decodeActiveIdsMap(raw);
    } catch (_) {
      map = <String, List<String>>{};
    }
    _activeIdsByAssistantCache = map;
    return _cloneActiveIdsMap(map);
  }

  static Future<Map<String, bool>> _loadCollapsedBooksMap() async {
    if (_collapsedBooksCache != null) {
      return _cloneCollapsedBooksMap(_collapsedBooksCache!);
    }
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_collapsedBooksKey);
    Map<String, bool> map = <String, bool>{};
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw) as Map;
        decoded.forEach((key, value) {
          final id = key.toString().trim();
          if (id.isEmpty) return;
          final collapsed = value is bool ? value : value.toString() == 'true';
          map[id] = collapsed;
        });
      } catch (_) {
        map = <String, bool>{};
      }
    }
    _collapsedBooksCache = map;
    return _cloneCollapsedBooksMap(map);
  }

  static Future<void> _persistActiveIdsMap(
    Map<String, List<String>> map,
  ) async {
    _activeIdsByAssistantCache = _cloneActiveIdsMap(map);
    final prefs = await SharedPreferences.getInstance();
    try {
      await prefs.setString(_activeIdsByAssistantKey, jsonEncode(map));
    } catch (_) {}
  }

  static Future<void> _persistCollapsedBooksMap(Map<String, bool> map) async {
    _collapsedBooksCache = _cloneCollapsedBooksMap(map);
    final prefs = await SharedPreferences.getInstance();
    try {
      await prefs.setString(_collapsedBooksKey, jsonEncode(map));
    } catch (_) {}
  }
}
