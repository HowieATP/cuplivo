import 'dart:convert';

import 'package:Cuplivo/core/models/api_keys.dart';
import 'package:Cuplivo/core/services/search/providers/doubao_search_service.dart';
import 'package:Cuplivo/core/services/search/providers/firecrawl_search_service.dart';
import 'package:Cuplivo/core/services/search/providers/stepfun_search_service.dart';
import 'package:Cuplivo/core/services/search/providers/tinyfish_search_service.dart';
import 'package:Cuplivo/core/services/search/search_service.dart';
import 'package:Cuplivo/utils/brand_assets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('Doubao search service', () {
    test('serializes options and resolves factory/icon mapping', () {
      final options = DoubaoOptions(
        id: 'doubao-1',
        apiKeys: [ApiKeyConfig.create('doubao-test')],
      );

      final restored = SearchServiceOptions.fromJson(options.toJson());

      expect(restored, isA<DoubaoOptions>());
      expect(restored.id, 'doubao-1');
      expect(restored.apiKey, 'doubao-test');
      expect(SearchService.getService(restored), isA<DoubaoSearchService>());
      expect(
        BrandAssets.assetForName('doubao'),
        'assets/icons/doubao-color.svg',
      );
    });

    test('posts web search request and parses WebResults', () async {
      http.Request? captured;
      final service = DoubaoSearchService(
        client: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode({
              'ResponseMetadata': {},
              'Result': {
                'WebResults': [
                  {
                    'Title': 'Doubao docs',
                    'Url': 'https://example.com/doubao',
                    'Summary': 'A web search API.',
                  },
                  {
                    'Title': 'Ignored by count',
                    'Url': 'https://example.com/ignored',
                    'Content': 'ignored',
                  },
                ],
              },
            }),
            200,
          );
        }),
      );

      final result = await service.search(
        query: 'doubao',
        commonOptions: const SearchCommonOptions(resultSize: 1, timeout: 1000),
        serviceOptions: DoubaoOptions(
          id: 'doubao-1',
          apiKeys: [ApiKeyConfig.create('doubao-test')],
        ),
      );

      expect(captured?.url.toString(), DoubaoSearchService.endpoint);
      expect(captured?.headers['Authorization'], 'Bearer doubao-test');
      expect(jsonDecode(captured!.body), {
        'Query': 'doubao',
        'SearchType': 'web',
        'Count': 1,
        'Filter': {'NeedUrl': true},
      });
      expect(result.items, hasLength(1));
      expect(result.items.single.title, 'Doubao docs');
      expect(result.items.single.url, 'https://example.com/doubao');
      expect(result.items.single.text, 'A web search API.');
    });

    test('throws on response metadata error', () async {
      final service = DoubaoSearchService(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'ResponseMetadata': {
                'Error': {'Code': 'InvalidParameter', 'Message': 'bad query'},
              },
            }),
            200,
          ),
        ),
      );

      expect(
        () => service.search(
          query: 'doubao',
          commonOptions: const SearchCommonOptions(timeout: 1000),
          serviceOptions: DoubaoOptions(
            id: 'doubao-1',
            apiKeys: [ApiKeyConfig.create('doubao-test')],
          ),
        ),
        throwsA(
          isA<Exception>().having(
            (error) => error.toString(),
            'message',
            contains('bad query'),
          ),
        ),
      );
    });

    test('throws before request when API key is empty', () async {
      var called = false;
      final service = DoubaoSearchService(
        client: MockClient((_) async {
          called = true;
          return http.Response('{}', 200);
        }),
      );

      expect(
        () => service.search(
          query: 'doubao',
          commonOptions: const SearchCommonOptions(timeout: 1000),
          serviceOptions: DoubaoOptions(id: 'doubao-1', apiKeys: []),
        ),
        throwsA(
          isA<Exception>().having(
            (error) => error.toString(),
            'message',
            contains('Doubao API key is required'),
          ),
        ),
      );
      expect(called, isFalse);
    });
  });

  group('Firecrawl search service', () {
    test('serializes options and resolves factory/icon mapping', () {
      final options = FirecrawlOptions(
        id: 'firecrawl-1',
        apiKeys: [ApiKeyConfig.create('fc-test')],
        country: 'US',
        location: 'New York',
      );

      final restored = SearchServiceOptions.fromJson(options.toJson());

      expect(restored, isA<FirecrawlOptions>());
      expect(restored.id, 'firecrawl-1');
      expect(restored.apiKey, 'fc-test');
      expect((restored as FirecrawlOptions).country, 'US');
      expect(restored.location, 'New York');
      expect(SearchService.getService(restored), isA<FirecrawlSearchService>());
      expect(
        BrandAssets.assetForName('firecrawl'),
        'assets/icons/firecrawl-color.svg',
      );
    });

    test('posts search request and parses web + news results', () async {
      http.Request? captured;
      final service = FirecrawlSearchService(
        client: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode({
              'data': {
                'web': [
                  {
                    'title': 'Firecrawl docs',
                    'url': 'https://example.com/firecrawl',
                    'description': 'Scrape and search the web.',
                  },
                  {
                    'title': 'Ignored by resultSize',
                    'url': 'https://example.com/ignored',
                    'snippet': 'ignored',
                  },
                ],
                'news': [
                  {
                    'title': 'News item',
                    'url': 'https://example.com/news',
                    'markdown': 'news body',
                  },
                ],
              },
            }),
            200,
          );
        }),
      );

      final result = await service.search(
        query: 'firecrawl',
        commonOptions: const SearchCommonOptions(resultSize: 1, timeout: 1000),
        serviceOptions: FirecrawlOptions(
          id: 'firecrawl-1',
          apiKeys: [ApiKeyConfig.create('fc-test')],
          sources: const ['web', 'news'],
          country: 'US',
          location: 'New York',
        ),
      );

      expect(captured?.url.toString(), FirecrawlOptions.defaultUrl);
      expect(captured?.headers['Authorization'], 'Bearer fc-test');
      final body = jsonDecode(captured!.body) as Map<String, dynamic>;
      expect(body['query'], 'firecrawl');
      expect(body['limit'], 1);
      expect(body['sources'], [
        {'type': 'web'},
        {'type': 'news'},
      ]);
      expect(body['country'], 'US');
      expect(body['location'], 'New York');
      expect(result.items, hasLength(1));
      expect(result.items.single.title, 'Firecrawl docs');
      expect(result.items.single.url, 'https://example.com/firecrawl');
      expect(result.items.single.text, 'Scrape and search the web.');
    });

    test('sends no Authorization header when the API key is empty', () async {
      http.Request? captured;
      final service = FirecrawlSearchService(
        client: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode({
              'data': {'web': []},
            }),
            200,
          );
        }),
      );

      final result = await service.search(
        query: 'firecrawl',
        commonOptions: const SearchCommonOptions(timeout: 1000),
        serviceOptions: FirecrawlOptions(id: 'firecrawl-1', apiKeys: []),
      );

      expect(captured?.headers.containsKey('Authorization'), isFalse);
      expect(result.items, isEmpty);
    });

    test('throws on non-200 response', () async {
      final service = FirecrawlSearchService(
        client: MockClient((_) async => http.Response('rate limited', 429)),
      );

      expect(
        () => service.search(
          query: 'firecrawl',
          commonOptions: const SearchCommonOptions(timeout: 1000),
          serviceOptions: FirecrawlOptions(
            id: 'firecrawl-1',
            apiKeys: [ApiKeyConfig.create('fc-test')],
          ),
        ),
        throwsA(
          isA<Exception>().having(
            (error) => error.toString(),
            'message',
            contains('Firecrawl search failed'),
          ),
        ),
      );
    });

    test('throws a descriptive error on a v1-shaped response', () async {
      final service = FirecrawlSearchService(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode([
              {'title': 'legacy', 'url': 'https://example.com/legacy'},
            ]),
            200,
          ),
        ),
      );

      expect(
        () => service.search(
          query: 'firecrawl',
          commonOptions: const SearchCommonOptions(timeout: 1000),
          serviceOptions: FirecrawlOptions(
            id: 'firecrawl-1',
            apiKeys: [ApiKeyConfig.create('fc-test')],
            url: 'https://api.firecrawl.dev/search',
          ),
        ),
        throwsA(
          isA<Exception>().having(
            (error) => error.toString(),
            'message',
            allOf(
              contains('Firecrawl search failed'),
              contains('v1'),
              contains('v2'),
            ),
          ),
        ),
      );
    });
  });

  group('StepFun search service', () {
    test('serializes options and resolves factory/icon mapping', () {
      final options = StepFunOptions(
        id: 'stepfun-1',
        apiKeys: [ApiKeyConfig.create('sf-test')],
        category: 'research',
      );

      final restored = SearchServiceOptions.fromJson(options.toJson());

      expect(restored, isA<StepFunOptions>());
      expect(restored.id, 'stepfun-1');
      expect(restored.apiKey, 'sf-test');
      expect((restored as StepFunOptions).category, 'research');
      expect(SearchService.getService(restored), isA<StepFunSearchService>());
      expect(
        BrandAssets.assetForName('stepfun'),
        'assets/icons/stepfun-color.svg',
      );
    });

    test('posts query and parses results', () async {
      http.Request? captured;
      final service = StepFunSearchService(
        client: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode({
              'results': [
                {
                  'title': 'StepFun docs',
                  'url': 'https://example.com/stepfun',
                  'snippet': 'A search API.',
                },
                {
                  'title': 'Ignored by n',
                  'url': 'https://example.com/ignored',
                  'content': 'ignored',
                },
              ],
            }),
            200,
          );
        }),
      );

      final result = await service.search(
        query: 'stepfun',
        commonOptions: const SearchCommonOptions(resultSize: 1, timeout: 1000),
        serviceOptions: StepFunOptions(
          id: 'stepfun-1',
          apiKeys: [ApiKeyConfig.create('sf-test')],
          category: 'research',
        ),
      );

      expect(captured?.url.toString(), StepFunOptions.defaultUrl);
      expect(captured?.headers['Authorization'], 'Bearer sf-test');
      expect(jsonDecode(captured!.body), {
        'query': 'stepfun',
        'n': 1,
        'category': 'research',
      });
      expect(result.items, hasLength(1));
      expect(result.items.single.title, 'StepFun docs');
      expect(result.items.single.url, 'https://example.com/stepfun');
      expect(result.items.single.text, 'A search API.');
    });

    test('throws before request when API key is empty', () async {
      var called = false;
      final service = StepFunSearchService(
        client: MockClient((_) async {
          called = true;
          return http.Response('{}', 200);
        }),
      );

      expect(
        () => service.search(
          query: 'stepfun',
          commonOptions: const SearchCommonOptions(timeout: 1000),
          serviceOptions: StepFunOptions(id: 'stepfun-1', apiKeys: []),
        ),
        throwsA(
          isA<Exception>().having(
            (error) => error.toString(),
            'message',
            contains('StepFun API key is required'),
          ),
        ),
      );
      expect(called, isFalse);
    });
  });

  group('TinyFish search service', () {
    test('serializes options and resolves factory/icon mapping', () {
      final options = TinyFishOptions(
        id: 'tinyfish-1',
        apiKeys: [ApiKeyConfig.create('tf-test')],
        location: 'US',
        language: 'en',
        includeDomains: 'example.com',
        excludeDomains: 'bad.example',
      );

      final restored = SearchServiceOptions.fromJson(options.toJson());

      expect(restored, isA<TinyFishOptions>());
      expect(restored.id, 'tinyfish-1');
      expect(restored.apiKey, 'tf-test');
      final tf = restored as TinyFishOptions;
      expect(tf.location, 'US');
      expect(tf.language, 'en');
      expect(tf.includeDomains, 'example.com');
      expect(tf.excludeDomains, 'bad.example');
      expect(SearchService.getService(restored), isA<TinyFishSearchService>());
      expect(
        BrandAssets.assetForName('tinyfish'),
        'assets/icons/tinyfish-color.svg',
      );
    });

    test('builds query params and parses results', () async {
      http.Request? captured;
      final service = TinyFishSearchService(
        client: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode({
              'results': [
                {
                  'title': 'TinyFish docs',
                  'url': 'https://example.com/tinyfish',
                  'snippet': 'A search API.',
                },
              ],
            }),
            200,
          );
        }),
      );

      final result = await service.search(
        query: 'tinyfish',
        commonOptions: const SearchCommonOptions(timeout: 1000),
        serviceOptions: TinyFishOptions(
          id: 'tinyfish-1',
          apiKeys: [ApiKeyConfig.create('tf-test')],
          location: 'US',
          language: 'en',
          includeDomains: 'example.com',
          excludeDomains: 'bad.example',
        ),
      );

      expect(captured?.method, 'GET');
      expect(captured?.url.queryParameters, {
        'query': 'tinyfish',
        'location': 'US',
        'language': 'en',
        'include_domains': 'example.com',
        'exclude_domains': 'bad.example',
      });
      expect(captured?.headers['X-API-Key'], 'tf-test');
      expect(result.items, hasLength(1));
      expect(result.items.single.title, 'TinyFish docs');
      expect(result.items.single.url, 'https://example.com/tinyfish');
      expect(result.items.single.text, 'A search API.');
    });

    test('omits empty optional query params', () async {
      http.Request? captured;
      final service = TinyFishSearchService(
        client: MockClient((request) async {
          captured = request;
          return http.Response(jsonEncode({'results': []}), 200);
        }),
      );

      final result = await service.search(
        query: 'tinyfish',
        commonOptions: const SearchCommonOptions(timeout: 1000),
        serviceOptions: TinyFishOptions(
          id: 'tinyfish-1',
          apiKeys: [ApiKeyConfig.create('tf-test')],
        ),
      );

      expect(captured?.url.queryParameters, {'query': 'tinyfish'});
      expect(result.items, isEmpty);
    });

    test('throws before request when API key is empty', () async {
      var called = false;
      final service = TinyFishSearchService(
        client: MockClient((_) async {
          called = true;
          return http.Response('{}', 200);
        }),
      );

      expect(
        () => service.search(
          query: 'tinyfish',
          commonOptions: const SearchCommonOptions(timeout: 1000),
          serviceOptions: TinyFishOptions(id: 'tinyfish-1', apiKeys: []),
        ),
        throwsA(
          isA<Exception>().having(
            (error) => error.toString(),
            'message',
            contains('TinyFish API key is required'),
          ),
        ),
      );
      expect(called, isFalse);
    });
  });
}
