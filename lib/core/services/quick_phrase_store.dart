import 'dart:convert';

import 'package:Cuplivo/core/database/business_preferences.dart';

import '../models/quick_phrase.dart';

class QuickPhraseStore {
  QuickPhraseStore(this._preferences);

  /// Per-isolate shared instance, bound to the [BusinessPreferences] facade
  /// passed on first use. Production code in an isolate always hands over the
  /// same startup-gate facade, so one shared instance serves every consumer
  /// and keeps the object-level cache coherent (a stale instance must not
  /// persist a resurrected snapshot). The alarm background isolate creates a
  /// fresh facade per invocation: the identity check fails there, so each
  /// invocation binds a fresh store with a fresh cache.
  ///
  /// Never hold a store reference across a switch to a different facade in a
  /// long-lived isolate: the shared accessor rebinds to the new facade and
  /// the previously bound store's cache would diverge.
  static QuickPhraseStore? _shared;
  static QuickPhraseStore shared(BusinessPreferences preferences) {
    final current = _shared;
    if (current == null || !identical(current._preferences, preferences)) {
      return _shared = QuickPhraseStore(preferences);
    }
    return current;
  }

  static const String _phrasesKey = 'quick_phrases_v1';
  final BusinessPreferences _preferences;
  List<QuickPhrase>? _cache;

  Future<List<QuickPhrase>> getAll() async {
    if (_cache != null) return List.of(_cache!);
    final json = _preferences.getString(_phrasesKey);
    if (json == null || json.isEmpty) {
      _cache = [];
      return [];
    }
    try {
      final list = jsonDecode(json) as List;
      _cache = list
          .map((e) => QuickPhrase.fromJson(e as Map<String, dynamic>))
          .toList();
      return List.of(_cache!);
    } catch (_) {
      _cache = [];
      return [];
    }
  }

  Future<List<QuickPhrase>> getGlobal() async {
    final all = await getAll();
    return all.where((p) => p.isGlobal).toList();
  }

  Future<List<QuickPhrase>> getForAssistant(String assistantId) async {
    final all = await getAll();
    return all
        .where((p) => !p.isGlobal && p.assistantId == assistantId)
        .toList();
  }

  Future<void> save(List<QuickPhrase> phrases) async {
    _cache = phrases;
    final json = jsonEncode(phrases.map((p) => p.toJson()).toList());
    await _preferences.setString(_phrasesKey, json);
  }

  Future<void> add(QuickPhrase phrase) async {
    final all = await getAll();
    all.add(phrase);
    await save(all);
  }

  Future<void> update(QuickPhrase phrase) async {
    final all = await getAll();
    final index = all.indexWhere((p) => p.id == phrase.id);
    if (index != -1) {
      all[index] = phrase;
      await save(all);
    }
  }

  Future<void> delete(String id) async {
    final all = await getAll();
    all.removeWhere((p) => p.id == id);
    await save(all);
  }

  Future<void> clear() async {
    _cache = [];
    await _preferences.remove(_phrasesKey);
  }
}
