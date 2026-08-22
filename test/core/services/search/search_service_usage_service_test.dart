import 'package:Cuplivo/core/models/api_keys.dart';
import 'package:Cuplivo/core/services/search/search_service.dart';
import 'package:Cuplivo/core/services/search/search_service_usage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('SearchServiceUsageService', () {
    test('queries Tavily usage and calculates remaining credits', () async {
      final client = MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.toString(), 'https://api.tavily.com/usage');
        expect(request.headers['Authorization'], 'Bearer tvly-test');
        return http.Response('''
          {
            "key": {"usage": 150, "limit": 1000},
            "account": {"current_plan": "Bootstrap"}
          }
          ''', 200);
      });

      final usage = await SearchServiceUsageService.fetch(
        TavilyOptions(
          id: 'tavily',
          apiKeys: [ApiKeyConfig.create('tvly-test')],
        ),
        client: client,
      );

      expect(usage.remaining, 850);
      expect(usage.used, 150);
      expect(usage.limit, 1000);
    });

    test('uses account totals when the Tavily key has no limit', () async {
      final client = MockClient((_) async {
        return http.Response('''
          {
            "key": {"usage": 42, "limit": null},
            "account": {
              "current_plan": "Researcher",
              "plan_usage": 75,
              "plan_limit": 1000,
              "paygo_usage": 0,
              "paygo_limit": null
            }
          }
          ''', 200);
      });

      final usage = await SearchServiceUsageService.fetch(
        TavilyOptions(
          id: 'tavily',
          apiKeys: [ApiKeyConfig.create('tvly-test')],
        ),
        client: client,
      );

      expect(usage.remaining, 925);
      expect(usage.used, 75);
      expect(usage.limit, 1000);
    });

    test('derives Tavily usage path from a custom search URL', () async {
      final client = MockClient((request) async {
        expect(request.url.toString(), 'https://proxy.example/api/usage');
        return http.Response(
          '{"key":{"usage":2,"limit":10},"account":{}}',
          200,
        );
      });

      final usage = await SearchServiceUsageService.fetch(
        TavilyOptions(
          id: 'tavily',
          apiKeys: [ApiKeyConfig.create('key')],
          url: 'https://proxy.example/api/search?source=kelivo',
        ),
        client: client,
      );

      expect(usage.remaining, 8);
    });

    test('queries LinkUp credit balance', () async {
      final client = MockClient((request) async {
        expect(
          request.url.toString(),
          'https://api.linkup.so/v1/credits/balance',
        );
        expect(request.headers['Authorization'], 'Bearer linkup-test');
        return http.Response('{"balance":123.456}', 200);
      });

      final usage = await SearchServiceUsageService.fetch(
        LinkUpOptions(
          id: 'linkup',
          apiKeys: [ApiKeyConfig.create('linkup-test')],
        ),
        client: client,
      );

      expect(usage.remaining, 123.456);
      expect(usage.used, isNull);
      expect(usage.limit, isNull);
    });

    test('retries a transient Tavily TLS handshake failure', () async {
      var attempts = 0;
      final client = MockClient((_) async {
        attempts++;
        if (attempts == 1) {
          throw http.ClientException(
            'HandshakeException: Connection terminated during handshake',
          );
        }
        return http.Response(
          '{"account":{"plan_usage":25,"plan_limit":100}}',
          200,
        );
      });

      final usage = await SearchServiceUsageService.fetch(
        TavilyOptions(
          id: 'tavily',
          apiKeys: [ApiKeyConfig.create('tvly-test')],
        ),
        client: client,
      );

      expect(attempts, 2);
      expect(usage.remaining, 75);
    });

    test('does not expose provider response bodies on HTTP failure', () async {
      final client = MockClient(
        (_) async => http.Response('{"secret":"details"}', 401),
      );

      expect(
        () => SearchServiceUsageService.fetch(
          LinkUpOptions(
            id: 'linkup',
            apiKeys: [ApiKeyConfig.create('bad-key')],
          ),
          client: client,
        ),
        throwsA(
          isA<SearchServiceUsageException>().having(
            (error) => error.toString(),
            'message',
            allOf(contains('HTTP 401'), isNot(contains('secret'))),
          ),
        ),
      );
    });

    test('cachedUsage returns the result of a previous fetch', () async {
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        return http.Response(
          '{"account":{"plan_usage":100,"plan_limit":500}}',
          200,
        );
      });

      final options = TavilyOptions(
        id: 'cache-hit',
        apiKeys: [ApiKeyConfig.create('tvly-cache')],
      );
      await SearchServiceUsageService.fetch(options, client: client);
      expect(calls, 1);

      final cached = SearchServiceUsageService.cachedUsage(options);
      expect(cached, isNotNull);
      expect(cached!.remaining, 400);
      expect(calls, 1, reason: 'cachedUsage must not hit the network');
    });

    test('cachedUsage keys on id, credential, and endpoint', () async {
      final client = MockClient(
        (_) async => http.Response(
          '{"account":{"plan_usage":10,"plan_limit":100}}',
          200,
        ),
      );
      await SearchServiceUsageService.fetch(
        TavilyOptions(id: 'cache-a', apiKeys: [ApiKeyConfig.create('k1')]),
        client: client,
      );

      expect(
        SearchServiceUsageService.cachedUsage(
          TavilyOptions(id: 'cache-b', apiKeys: [ApiKeyConfig.create('k1')]),
        ),
        isNull,
        reason: 'a different service id must miss the cache',
      );
      expect(
        SearchServiceUsageService.cachedUsage(
          TavilyOptions(id: 'cache-a', apiKeys: [ApiKeyConfig.create('k2')]),
        ),
        isNull,
        reason: 'a different credential must miss the cache',
      );
      expect(
        SearchServiceUsageService.cachedUsage(
          TavilyOptions(id: 'cache-a', apiKeys: [ApiKeyConfig.create('k1')]),
        ),
        isNotNull,
      );
    });

    test(
      'cachedUsage and hasCredential reject unsupported providers',
      () async {
        final options = ExaOptions(
          id: 'exa',
          apiKeys: [ApiKeyConfig.create('k')],
        );
        expect(SearchServiceUsageService.cachedUsage(options), isNull);
        expect(SearchServiceUsageService.hasCredential(options), isFalse);
      },
    );

    test(
      'hasCredential requires a non-empty key for supported providers',
      () async {
        expect(
          SearchServiceUsageService.hasCredential(
            TavilyOptions(id: 't', apiKeys: [ApiKeyConfig.create(' k ')]),
          ),
          isTrue,
        );
        expect(
          SearchServiceUsageService.hasCredential(
            LinkUpOptions(id: 'l', apiKeys: [ApiKeyConfig.create('lk')]),
          ),
          isTrue,
        );
        expect(
          SearchServiceUsageService.hasCredential(
            TavilyOptions(id: 't', apiKeys: [ApiKeyConfig.create('')]),
          ),
          isFalse,
        );
        expect(
          SearchServiceUsageService.hasCredential(LinkUpOptions(id: 'l')),
          isFalse,
        );
      },
    );

    test('cache evicts all entries when it exceeds 50', () async {
      final client = MockClient(
        (_) async =>
            http.Response('{"account":{"plan_usage":1,"plan_limit":10}}', 200),
      );
      for (var i = 0; i < 51; i++) {
        await SearchServiceUsageService.fetch(
          TavilyOptions(
            id: 'evict-$i',
            apiKeys: [ApiKeyConfig.create('evict-key')],
          ),
          client: client,
        );
      }

      expect(
        SearchServiceUsageService.cachedUsage(
          TavilyOptions(
            id: 'evict-0',
            apiKeys: [ApiKeyConfig.create('evict-key')],
          ),
        ),
        isNull,
        reason: 'the oldest entries must be evicted',
      );
      expect(
        SearchServiceUsageService.cachedUsage(
          TavilyOptions(
            id: 'evict-50',
            apiKeys: [ApiKeyConfig.create('evict-key')],
          ),
        ),
        isNotNull,
      );
    });
  });
}
