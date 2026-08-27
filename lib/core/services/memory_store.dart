import 'dart:async';
import 'dart:convert';

import 'package:Cuplivo/core/database/business_preferences.dart';

import '../models/assistant_memory.dart';

class MemoryStore {
  MemoryStore(this._preferences);

  /// Per-isolate shared instance, bound to the [BusinessPreferences] facade
  /// passed on first use. Production code in an isolate always hands over the
  /// same startup-gate facade, so one shared instance serves every consumer:
  /// the object-level cache stays coherent and the mutation lock guards all
  /// concurrent read-modify-write flows in the isolate. The alarm background
  /// isolate creates a fresh facade per invocation: the identity check fails
  /// there, so each invocation binds a fresh store with a fresh cache.
  ///
  /// Never hold a store reference across a switch to a different facade in a
  /// long-lived isolate: the shared accessor rebinds to the new facade and
  /// the previously bound store's caches would diverge.
  static MemoryStore? _shared;
  static MemoryStore shared(BusinessPreferences preferences) {
    final current = _shared;
    if (current == null || !identical(current._preferences, preferences)) {
      return _shared = MemoryStore(preferences);
    }
    return current;
  }

  static const String _memoriesKey = 'assistant_memories_v1';

  final BusinessPreferences _preferences;

  /// Mutex that serializes every read-modify-write mutation
  /// (add/update/delete) so concurrent tool calls cannot observe a stale
  /// snapshot and assign duplicate IDs or drop each other's changes.
  ///
  /// The lock is reset to null after each release so waiters never chain onto
  /// a future that outlives the call site's event loop zone.
  ///
  /// NOT reentrant: a locked action must never invoke another locked method,
  /// or it will wait forever on its own uncompleted completer.
  Completer<void>? _lock;

  List<AssistantMemory>? _cache;

  Future<T> _withLock<T>(Future<T> Function() action) async {
    while (_lock != null) {
      await _lock!.future;
    }
    final completer = Completer<void>();
    _lock = completer;
    try {
      return await action();
    } finally {
      _lock = null;
      completer.complete();
    }
  }

  Future<List<AssistantMemory>> _loadAllInternal() async {
    final raw = _preferences.getString(_memoriesKey);
    if (raw == null || raw.isEmpty) return <AssistantMemory>[];
    try {
      final arr = jsonDecode(raw) as List<dynamic>;
      return [
        for (final e in arr)
          if (e is Map<String, dynamic>)
            AssistantMemory.fromJson(e)
          else
            AssistantMemory.fromJson((e as Map).cast<String, dynamic>()),
      ];
    } catch (_) {
      return <AssistantMemory>[];
    }
  }

  Future<List<AssistantMemory>> getAll() async {
    _cache ??= await _loadAllInternal();
    return List<AssistantMemory>.of(_cache!);
  }

  /// Replaces the whole memory list under the mutation lock.
  ///
  /// The only way outside add/update/delete to rewrite the list (e.g. trash
  /// restore). With the per-isolate shared instance the lock serializes this
  /// against tool-call mutations, so an interleaved add does not observe a
  /// half-written snapshot.
  Future<void> saveAll(List<AssistantMemory> list) {
    return _withLock(() => _saveAllUnlocked(list));
  }

  Future<void> _saveAllUnlocked(List<AssistantMemory> list) async {
    _cache = List<AssistantMemory>.of(list);
    final json = jsonEncode(list.map((e) => e.toJson()).toList());
    await _preferences.setString(_memoriesKey, json);
  }

  Future<List<AssistantMemory>> getForAssistant(String assistantId) async {
    final all = await getAll();
    return all.where((m) => m.assistantId == assistantId).toList();
  }

  static int _nextId(List<AssistantMemory> list) {
    int maxId = 0;
    for (final m in list) {
      if (m.id > maxId) maxId = m.id;
    }
    return maxId + 1;
  }

  Future<AssistantMemory> add({
    required String assistantId,
    required String content,
  }) async {
    return _withLock(() async {
      final all = await getAll();
      final id = _nextId(all);
      final mem = AssistantMemory(
        id: id,
        assistantId: assistantId,
        content: content,
      );
      all.add(mem);
      await _saveAllUnlocked(all);
      return mem;
    });
  }

  Future<AssistantMemory?> update({
    required int id,
    required String content,
  }) async {
    return _withLock(() async {
      final all = await getAll();
      final idx = all.indexWhere((m) => m.id == id);
      if (idx == -1) return null;
      final updated = all[idx].copyWith(content: content);
      all[idx] = updated;
      await _saveAllUnlocked(all);
      return updated;
    });
  }

  Future<bool> delete({required int id}) async {
    return _withLock(() async {
      final all = await getAll();
      final before = all.length;
      all.removeWhere((m) => m.id == id);
      final changed = all.length != before;
      if (changed) await _saveAllUnlocked(all);
      return changed;
    });
  }

  Future<void> deleteForAssistant(String assistantId) async {
    await _withLock(() async {
      final all = await getAll();
      all.removeWhere((m) => m.assistantId == assistantId);
      await _saveAllUnlocked(all);
    });
  }
}
