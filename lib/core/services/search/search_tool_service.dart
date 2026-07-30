import 'dart:convert';
import 'package:uuid/uuid.dart';
import '../../models/api_keys.dart';
import '../api_key_manager.dart';
import 'search_service.dart';
import '../../providers/settings_provider.dart';

class SearchToolService {
  static const String toolName = 'search_web';
  static const String toolDescription =
      '''Search the web for up-to-date information via the user's configured search engine. Returns results with title, URL, snippet, "index" (1-based rank) and "id" (6-char citation id). An optional "answer" summary may be included. Refer to the system prompt for when to use this tool and how to format inline citations.

When to use: (1) explicit request to search from the user; (2) the LATEST news/data such as exchange rate, pricing and availability; (3) changes to NEW versions of libraries / applications or any other content that are released after your knowledge cutoff; (4) time-sensitive fact check.

When NOT to use: (1) explicit request to disable searching; (2) YOUR self-identity, capabilities or YOUR opinion; (3) reasoning / calculation / common sense that is too trivial to warrant a search; (4) personal information or context that are already exposed in chat history or memory.

Citation Format: `Details [citation](index:id)`. Citations MUST follow th​e relevant fact immediat​ely, placed after the pu​nctuation. Never pile them all up at the end. Good example: The document shows that the feature requires 3.0+ version. [citation](1:d4e5f6) The steps are as follows: ... [citation](3:a1b2c3).

Best Practice: (1) Use keywords rather than a complete sentence for `query`; (2) Retry searching with different keywords if the first search doesn't find relevant information. If the search results ar​e consistently filled wi​th noise/irrelevant cont​ent, report to the user if possible; (3) Fetch relevant links after searching if relevant tools are available; (4) Prefer organizing information into fluent paragraphs to repeating titles and links unless specially requested; (5) If the `answer` field (AI abstract) exists, you can refer to it.''';

  static final RegExp _schemeRe = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:');

  static String _normalizeUrl(String raw) {
    var u = raw.trim();
    if (u.isEmpty) return u;

    // Strip surrounding quotes if the backend returns a JSON-ish value.
    if ((u.startsWith('"') && u.endsWith('"')) ||
        (u.startsWith("'") && u.endsWith("'"))) {
      u = u.substring(1, u.length - 1).trim();
    }
    if (u.isEmpty) return u;

    // Protocol-relative URL (e.g. //example.com/path)
    if (u.startsWith('//')) return 'https:$u';

    // No scheme => default to https.
    if (!_schemeRe.hasMatch(u)) return 'https://$u';
    return u;
  }

  static Map<String, dynamic> getToolDefinition() {
    return {
      'type': 'function',
      'function': {
        'name': toolName,
        'description': toolDescription,
        'parameters': {
          'type': 'object',
          'properties': {
            'query': {
              'type': 'string',
              'description': 'The search query to look up online',
            },
          },
          'required': ['query'],
        },
      },
    };
  }

  static Future<String> executeSearch(
    String query,
    SettingsProvider settings,
  ) async {
    final services = settings.searchServices;
    if (services.isEmpty) {
      return jsonEncode({'error': 'No search services configured'});
    }

    final selectedIndex = settings.searchServiceSelected.clamp(
      0,
      services.length - 1,
    );
    final serviceOptions = services[selectedIndex];
    final service = SearchService.getService(serviceOptions);
    final manager = ApiKeyManager();

    // Keyless services (BingLocal, DuckDuckGo, SearXNG) — call directly.
    if (serviceOptions.apiKeys.isEmpty) {
      return _searchDirect(query, settings, service, serviceOptions);
    }

    // Keyed services: rotate keys on failure, retry transparently.
    final config = serviceOptions.keyManagement ?? const KeyManagementConfig();
    final result = await _searchWithRotation(
      query,
      settings,
      service,
      serviceOptions,
      manager,
      config,
    );

    // Persist updated key status/usage and roundRobinIndex back to settings.
    await _persistKeyUpdates(
      settings,
      selectedIndex,
      serviceOptions,
      manager,
      config,
    );

    return result;
  }

  /// Direct search for keyless services.
  static Future<String> _searchDirect(
    String query,
    SettingsProvider settings,
    SearchService service,
    SearchServiceOptions serviceOptions,
  ) async {
    final result = await _trySearch(query, settings, service, serviceOptions);
    if (result != null) return result;
    return jsonEncode({'error': 'Search failed'});
  }

  /// Rotates keys on failure, retries transparently, and writes updated key
  /// status/usage back to [serviceOptions.apiKeys] in-place.
  ///
  /// Note: there is currently no UI for strategy / auto-disable / cooldown
  /// settings, so [keys] is captured once and is stale across retries. This is
  /// acceptable because roundRobin (the implicit default) tolerates stale keys
  /// thanks to the in-memory index map. If strategy/cooldown UI is added later,
  /// the stale‑keys problem must be fixed (write updated configs back into the
  /// list before calling selectFromKeys on subsequent attempts).
  static Future<String> _searchWithRotation(
    String query,
    SettingsProvider settings,
    SearchService service,
    SearchServiceOptions serviceOptions,
    ApiKeyManager manager,
    KeyManagementConfig config,
  ) async {
    final keys = serviceOptions.apiKeys.where((k) => k.isEnabled).toList();
    if (keys.isEmpty) {
      return _searchDirect(query, settings, service, serviceOptions);
    }

    for (var attempt = 0; attempt < keys.length; attempt++) {
      final selection = manager.selectFromKeys(keys, config, serviceOptions.id);
      if (selection.key == null) break;

      final result = await _trySearch(
        query,
        settings,
        service,
        serviceOptions,
        apiKeyOverride: selection.key!.key,
      );
      if (result != null) {
        final updated = manager.updateKeyStatusFromConfig(
          config,
          selection.key!,
          true,
        );
        _replaceApiKey(serviceOptions.apiKeys, updated);
        return result;
      }

      final updated = manager.updateKeyStatusFromConfig(
        config,
        selection.key!,
        false,
        error: 'search_failed',
      );
      _replaceApiKey(serviceOptions.apiKeys, updated);
    }
    return jsonEncode({'error': 'All search keys failed'});
  }

  /// Replaces an [ApiKeyConfig] in [list] by matching [id].
  static void _replaceApiKey(List<ApiKeyConfig> list, ApiKeyConfig updated) {
    final idx = list.indexWhere((k) => k.id == updated.id);
    if (idx >= 0) list[idx] = updated;
  }

  /// Persists updated key status/usage and roundRobinIndex back to settings.
  ///
  /// Currently only roundRobinIndex is persisted because strategy/cooldown/
  /// auto‑disable are not exposed via UI — roundRobin is the de‑facto default,
  /// so writing back the index is sufficient. If strategy/cooldown UI is added
  /// later, also write back disabled/error key statuses so they survive restart.
  static Future<void> _persistKeyUpdates(
    SettingsProvider settings,
    int selectedIndex,
    SearchServiceOptions serviceOptions,
    ApiKeyManager manager,
    KeyManagementConfig config,
  ) async {
    // Single-key configs: rotation has no effect on future selection, skip write.
    if (serviceOptions.apiKeys.length <= 1) return;
    final roundRobinIndex = manager.getRoundRobinIndex(serviceOptions.id);
    final services = List<SearchServiceOptions>.from(settings.searchServices);

    if (roundRobinIndex != null &&
        config.strategy == LoadBalanceStrategy.roundRobin) {
      final updatedConfig = config.copyWith(roundRobinIndex: roundRobinIndex);
      final json = serviceOptions.toJson();
      json['keyManagement'] = updatedConfig.toJson();
      services[selectedIndex] = SearchServiceOptions.fromJson(json);
    }

    await settings.setSearchServices(services);
  }

  /// Returns the encoded result on success, or null on failure.
  static Future<String?> _trySearch(
    String query,
    SettingsProvider settings,
    SearchService service,
    SearchServiceOptions serviceOptions, {
    String? apiKeyOverride,
  }) async {
    try {
      final result = await service.search(
        query: query,
        commonOptions: settings.searchCommonOptions,
        serviceOptions: serviceOptions,
        apiKeyOverride: apiKeyOverride,
      );

      final itemsWithIds = result.items.asMap().entries.map((entry) {
        final item = entry.value;
        return SearchResultItem(
          title: item.title,
          url: _normalizeUrl(item.url),
          text: item.text,
          id: const Uuid().v4().substring(0, 6),
          index: entry.key + 1,
        );
      }).toList();

      return jsonEncode({
        if (result.answer != null) 'answer': result.answer,
        'items': itemsWithIds.map((item) => item.toJson()).toList(),
      });
    } catch (e) {
      return null;
    }
  }
}
