import 'dart:convert';

import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/instruction_injection.dart';
import 'learning_mode_store.dart';

class InstructionInjectionStore {
  InstructionInjectionStore(this._preferences)
    : _learningMode = LearningModeStore(_preferences);

  /// Per-isolate shared instance, bound to the [BusinessPreferences] facade
  /// passed on first use. Production code in an isolate always hands over the
  /// same startup-gate facade, so one shared instance serves every consumer
  /// and keeps the object-level caches coherent (a stale instance must not
  /// persist a resurrected snapshot). The alarm background isolate creates a
  /// fresh facade per invocation: the identity check fails there, so each
  /// invocation binds a fresh store with fresh caches.
  ///
  /// Never hold a store reference across a switch to a different facade in a
  /// long-lived isolate: the shared accessor rebinds to the new facade and
  /// the previously bound store's caches would diverge.
  static InstructionInjectionStore? _shared;
  static InstructionInjectionStore shared(BusinessPreferences preferences) {
    final current = _shared;
    if (current == null || !identical(current._preferences, preferences)) {
      return _shared = InstructionInjectionStore(preferences);
    }
    return current;
  }

  static const String _itemsKey = 'instruction_injections_v1';
  static const String _activeIdKey = 'instruction_injections_active_id_v1';
  static const String _activeIdsKey = 'instruction_injections_active_ids_v1';
  static const String _activeIdsByAssistantKey =
      'instruction_injections_active_ids_by_assistant_v1';
  static const String _defaultAssistantKey = '__global__';

  final BusinessPreferences _preferences;
  final LearningModeStore _learningMode;
  List<InstructionInjection>? _cache;
  String? _activeIdCache;
  Map<String, List<String>>? _activeIdsByAssistantCache;

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

  static Map<String, List<String>> _cloneActiveIdsMap(
    Map<String, List<String>> src,
  ) {
    return {for (final e in src.entries) e.key: List<String>.from(e.value)};
  }

  Future<List<InstructionInjection>> getAll() async {
    if (_cache != null) return List<InstructionInjection>.from(_cache!);
    final prefs = _preferences;
    final json = prefs.getString(_itemsKey);
    if (json == null || json.isEmpty) {
      // Seed with a default "Learning Mode" card using existing learning mode prompt/settings.
      final seeded = await _seedDefaultFromLearningMode(prefs);
      _cache = seeded;
      return List<InstructionInjection>.from(seeded);
    }
    try {
      final list = jsonDecode(json) as List;
      _cache = list
          .map(
            (e) => InstructionInjection.fromJson(
              (e as Map).cast<String, dynamic>(),
            ),
          )
          .toList(growable: true);
      return List<InstructionInjection>.from(_cache!);
    } catch (_) {
      _cache = const <InstructionInjection>[];
      return const <InstructionInjection>[];
    }
  }

  Future<List<InstructionInjection>> _seedDefaultFromLearningMode(
    BusinessPreferences prefs,
  ) async {
    // Use existing learning mode prompt and enabled flag to create a default card.
    String prompt;
    bool enabled;
    try {
      prompt = await _learningMode.getPrompt();
    } catch (_) {
      prompt = LearningModeStore.defaultPrompt;
    }
    try {
      enabled = await _learningMode.isEnabled();
    } catch (_) {
      enabled = false;
    }
    final id = const Uuid().v4();
    final item = InstructionInjection(id: id, title: '', prompt: prompt);
    final list = <InstructionInjection>[item];
    final encoded = jsonEncode(
      list.map((e) => e.toJson()).toList(growable: false),
    );
    await prefs.setString(_itemsKey, encoded);
    _cache = list;
    if (enabled) {
      final active = <String>[id];
      _activeIdCache = id;
      _activeIdsByAssistantCache = <String, List<String>>{
        _defaultAssistantKey: active,
      };
      await prefs.setString(_activeIdKey, id);
      try {
        await prefs.setString(_activeIdsKey, jsonEncode(active));
      } catch (_) {}
      try {
        await prefs.setString(
          _activeIdsByAssistantKey,
          jsonEncode(<String, List<String>>{_defaultAssistantKey: active}),
        );
      } catch (_) {}
    }
    return list;
  }

  Future<void> save(List<InstructionInjection> items) async {
    _cache = List<InstructionInjection>.from(items);
    final prefs = _preferences;
    final json = jsonEncode(
      items.map((e) => e.toJson()).toList(growable: false),
    );
    await prefs.setString(_itemsKey, json);
  }

  Future<void> add(InstructionInjection item) async {
    final all = await getAll();
    all.add(item);
    await save(all);
  }

  Future<void> addMany(List<InstructionInjection> items) async {
    if (items.isEmpty) return;
    final all = await getAll();
    all.addAll(items);
    await save(all);
  }

  Future<void> update(InstructionInjection item) async {
    final all = await getAll();
    final index = all.indexWhere((e) => e.id == item.id);
    if (index != -1) {
      all[index] = item;
      await save(all);
    }
  }

  Future<void> delete(String id) async {
    final all = await getAll();
    all.removeWhere((e) => e.id == id);
    await save(all);
    final prefs = _preferences;
    if (_activeIdCache == id) {
      _activeIdCache = null;
      await prefs.remove(_activeIdKey);
    }
    // Remove from per-assistant active maps
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
      if (removed) {
        await _persistActiveIdsMap(next);
      }
    } catch (_) {}
  }

  Future<void> clear() async {
    _cache = const <InstructionInjection>[];
    _activeIdCache = null;
    _activeIdsByAssistantCache = const <String, List<String>>{};
    final prefs = _preferences;
    await prefs.remove(_itemsKey);
    await prefs.remove(_activeIdKey);
    await prefs.remove(_activeIdsKey);
    await prefs.remove(_activeIdsByAssistantKey);
  }

  Future<void> reorder({required int oldIndex, required int newIndex}) async {
    final list = await getAll();
    if (oldIndex < 0 || oldIndex >= list.length) return;
    if (newIndex < 0 || newIndex >= list.length) return;
    final item = list.removeAt(oldIndex);
    list.insert(newIndex, item);
    await save(list);
  }

  Future<String?> getActiveId({String? assistantId}) async {
    final ids = await getActiveIds(assistantId: assistantId);
    if (ids.isEmpty) return null;
    return ids.first;
  }

  Future<void> setActiveId(String? id, {String? assistantId}) async {
    if (id == null || id.isEmpty) {
      await setActiveIds(const <String>[], assistantId: assistantId);
      return;
    }
    await setActiveIds(<String>[id], assistantId: assistantId);
  }

  Future<List<String>> getActiveIds({String? assistantId}) async {
    final map = await _loadActiveIdsMap();
    final key = assistantKey(assistantId);
    if (map.containsKey(key)) {
      return List<String>.from(map[key]!);
    }
    final fallback = map[_defaultAssistantKey];
    if (fallback != null) return List<String>.from(fallback);
    return const <String>[];
  }

  Future<Map<String, List<String>>> getActiveIdsByAssistant() async {
    final map = await _loadActiveIdsMap();
    return _cloneActiveIdsMap(map);
  }

  Future<void> setActiveIds(List<String> ids, {String? assistantId}) async {
    final key = assistantKey(assistantId);
    final clean = _cleanIds(ids);
    final map = await _loadActiveIdsMap();
    map[key] = clean;
    await _persistActiveIdsMap(map);
  }

  Future<void> setActiveIdsMap(Map<String, List<String>> map) async {
    final next = <String, List<String>>{};
    map.forEach((key, value) {
      next[key] = _cleanIds(value).toList(growable: false);
    });
    await _persistActiveIdsMap(next);
  }

  Future<InstructionInjection?> getActive({String? assistantId}) async {
    final list = await getActives(assistantId: assistantId);
    if (list.isEmpty) return null;
    return list.first;
  }

  Future<List<InstructionInjection>> getActives({String? assistantId}) async {
    final ids = await getActiveIds(assistantId: assistantId);
    if (ids.isEmpty) return const <InstructionInjection>[];
    final all = await getAll();
    if (all.isEmpty) return const <InstructionInjection>[];
    final map = <String, InstructionInjection>{for (final e in all) e.id: e};
    final result = <InstructionInjection>[];
    for (final id in ids) {
      final item = map[id];
      if (item != null) result.add(item);
    }
    return result;
  }

  Future<Map<String, List<String>>> _loadActiveIdsMap() async {
    if (_activeIdsByAssistantCache != null) {
      return _cloneActiveIdsMap(_activeIdsByAssistantCache!);
    }
    final prefs = _preferences;
    final raw = prefs.getString(_activeIdsByAssistantKey);
    Map<String, List<String>> map = <String, List<String>>{};
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw) as Map;
        decoded.forEach((key, value) {
          final list = (value is List) ? value : const [];
          map[key.toString()] = _cleanIds(list);
        });
      } catch (_) {
        map = <String, List<String>>{};
      }
    }
    if (map.isEmpty) {
      // Migrate from legacy global keys
      try {
        final legacy = await _loadLegacyActiveIds(prefs);
        if (legacy.isNotEmpty) {
          map[_defaultAssistantKey] = legacy;
        }
      } catch (_) {}
    }
    _activeIdsByAssistantCache = map;
    return _cloneActiveIdsMap(map);
  }

  Future<List<String>> _loadLegacyActiveIds(BusinessPreferences prefs) async {
    final json = prefs.getString(_activeIdsKey);
    if (json != null && json.isNotEmpty) {
      try {
        final list = (jsonDecode(json) as List)
            .map((e) => e.toString())
            .toList();
        return _cleanIds(list);
      } catch (_) {}
    }
    final legacy = prefs.getString(_activeIdKey);
    if (legacy != null && legacy.isNotEmpty) {
      return _cleanIds(<String>[legacy]);
    }
    return const <String>[];
  }

  Future<void> _persistActiveIdsMap(Map<String, List<String>> map) async {
    _activeIdsByAssistantCache = _cloneActiveIdsMap(map);
    final prefs = _preferences;
    try {
      await prefs.setString(_activeIdsByAssistantKey, jsonEncode(map));
    } catch (_) {}
    final defaultList = map[_defaultAssistantKey] ?? const <String>[];
    _activeIdCache = defaultList.isNotEmpty ? defaultList.first : null;
    if (defaultList.isEmpty) {
      await prefs.remove(_activeIdKey);
      await prefs.remove(_activeIdsKey);
    } else {
      await prefs.setString(_activeIdKey, defaultList.first);
      try {
        await prefs.setString(_activeIdsKey, jsonEncode(defaultList));
      } catch (_) {}
    }
  }
}
