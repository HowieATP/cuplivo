import 'dart:convert';

import 'package:Cuplivo/core/models/api_keys.dart';
import 'package:Cuplivo/core/services/search/providers/exa_search_service.dart';
import 'package:Cuplivo/core/services/search/providers/jina_search_service.dart';
import 'package:Cuplivo/core/services/search/providers/linkup_search_service.dart';
import 'package:Cuplivo/core/services/search/providers/ollama_search_service.dart';
import 'package:Cuplivo/core/services/search/providers/perplexity_search_service.dart';
import 'package:Cuplivo/core/services/search/providers/serper_search_service.dart';
import 'package:Cuplivo/core/services/search/providers/tavily_search_service.dart';
import 'package:Cuplivo/core/services/search/providers/zhipu_search_service.dart';
import 'package:Cuplivo/core/services/search/search_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

typedef _RequestCheck = void Function(http.Request request);

class _FetchCase {
  final String name;
  final SearchService service;
  final SearchServiceOptions options;
  final String responseBody;
  final String expectedContent;
  final _RequestCheck checkRequest;

  const _FetchCase({
    required this.name,
    required this.service,
    required this.options,
    required this.responseBody,
    required this.expectedContent,
    required this.checkRequest,
  });
}

void main() {
  const common = SearchCommonOptions(timeout: 1000);
  final target = Uri.parse('https://example.com/article?x=1');

  final cases = <_FetchCase>[
    _FetchCase(
      name: 'Tavily',
      service: TavilySearchService(),
      options: TavilyOptions(
        id: 'tavily',
        url: 'https://gateway.test/tavily/search/?token=abc',
        apiKeys: [ApiKeyConfig.create('configured-key')],
      ),
      responseBody: jsonEncode({
        'results': [
          {'url': target.toString(), 'raw_content': '# Tavily content'},
        ],
      }),
      expectedContent: '# Tavily content',
      checkRequest: (request) {
        expect(
          request.url.toString(),
          'https://gateway.test/tavily/extract/?token=abc',
        );
        expect(request.method, 'POST');
        expect(request.headers['Authorization'], 'Bearer override-key');
        expect(jsonDecode(request.body), {
          'urls': [target.toString()],
          'format': 'markdown',
        });
      },
    ),
    _FetchCase(
      name: 'Exa',
      service: ExaSearchService(),
      options: ExaOptions(
        id: 'exa',
        url: 'https://gateway.test/exa/search?tenant=one',
        apiKeys: [ApiKeyConfig.create('configured-key')],
      ),
      responseBody: jsonEncode({
        'results': [
          {
            'url': target.toString(),
            'title': 'Exa title',
            'text': 'Exa content',
          },
        ],
      }),
      expectedContent: 'Exa content',
      checkRequest: (request) {
        expect(
          request.url.toString(),
          'https://gateway.test/exa/contents?tenant=one',
        );
        expect(request.headers['x-api-key'], 'override-key');
        expect(jsonDecode(request.body), {
          'urls': [target.toString()],
          'text': true,
        });
      },
    ),
    _FetchCase(
      name: 'Zhipu',
      service: ZhipuSearchService(),
      options: ZhipuOptions(
        id: 'zhipu',
        apiKeys: [ApiKeyConfig.create('configured-key')],
      ),
      responseBody: jsonEncode({
        'reader_result': {
          'url': target.toString(),
          'title': 'Zhipu title',
          'content': 'Zhipu content',
        },
      }),
      expectedContent: 'Zhipu content',
      checkRequest: (request) {
        expect(
          request.url.toString(),
          'https://open.bigmodel.cn/api/paas/v4/reader',
        );
        expect(request.headers['Authorization'], 'Bearer override-key');
        expect(jsonDecode(request.body), {
          'url': target.toString(),
          'return_format': 'markdown',
        });
      },
    ),
    _FetchCase(
      name: 'LinkUp',
      service: LinkUpSearchService(),
      options: LinkUpOptions(
        id: 'linkup',
        apiKeys: [ApiKeyConfig.create('configured-key')],
      ),
      responseBody: jsonEncode({'markdown': 'LinkUp content'}),
      expectedContent: 'LinkUp content',
      checkRequest: (request) {
        expect(request.url.toString(), 'https://api.linkup.so/v1/fetch');
        expect(request.headers['Authorization'], 'Bearer override-key');
        expect(jsonDecode(request.body), {
          'url': target.toString(),
          'extractImages': false,
          'includeRawContent': false,
          'includeRawHtml': false,
          'renderJs': false,
        });
      },
    ),
    _FetchCase(
      name: 'Ollama',
      service: OllamaSearchService(),
      options: OllamaOptions(
        id: 'ollama',
        apiKeys: [ApiKeyConfig.create('configured-key')],
      ),
      responseBody: jsonEncode({
        'title': 'Ollama title',
        'content': 'Ollama content',
      }),
      expectedContent: 'Ollama content',
      checkRequest: (request) {
        expect(request.url.toString(), 'https://ollama.com/api/web_fetch');
        expect(request.headers['Authorization'], 'Bearer override-key');
        expect(jsonDecode(request.body), {'url': target.toString()});
      },
    ),
    _FetchCase(
      name: 'Jina',
      service: JinaSearchService(),
      options: JinaOptions(
        id: 'jina',
        apiKeys: [ApiKeyConfig.create('configured-key')],
      ),
      responseBody: jsonEncode({
        'data': {
          'url': target.toString(),
          'title': 'Jina title',
          'content': 'Jina content',
        },
      }),
      expectedContent: 'Jina content',
      checkRequest: (request) {
        expect(
          request.url.toString(),
          'https://r.jina.ai/https://example.com/article?x=1',
        );
        expect(request.method, 'GET');
        expect(request.headers['Authorization'], 'Bearer override-key');
        expect(request.headers['Accept'], 'application/json');
      },
    ),
    _FetchCase(
      name: 'Serper',
      service: SerperSearchService(),
      options: SerperOptions(
        id: 'serper',
        apiKeys: [ApiKeyConfig.create('configured-key')],
      ),
      responseBody: jsonEncode({
        'markdown': 'Serper content',
        'metadata': {'title': 'Serper title', 'url': target.toString()},
      }),
      expectedContent: 'Serper content',
      checkRequest: (request) {
        expect(request.url.toString(), 'https://scrape.serper.dev');
        expect(request.headers['X-API-KEY'], 'override-key');
        expect(jsonDecode(request.body), {
          'url': target.toString(),
          'includeMarkdown': true,
        });
      },
    ),
    _FetchCase(
      name: 'Perplexity',
      service: PerplexitySearchService(),
      options: PerplexityOptions(
        id: 'perplexity',
        apiKeys: [ApiKeyConfig.create('configured-key')],
      ),
      responseBody: jsonEncode({
        'output': [
          {
            'type': 'fetch_url_results',
            'contents': [
              {
                'url': target.toString(),
                'title': 'Perplexity title',
                'snippet': 'Perplexity content',
              },
            ],
          },
        ],
      }),
      expectedContent: 'Perplexity content',
      checkRequest: (request) {
        expect(request.url.toString(), 'https://api.perplexity.ai/v1/agent');
        expect(request.headers['Authorization'], 'Bearer override-key');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['model'], 'perplexity/sonar');
        expect(body['tools'], [
          {'type': 'fetch_url'},
        ]);
        expect(body['input'], contains(target.toString()));
      },
    ),
  ];

  group('native web fetch provider contracts', () {
    test('only documented providers advertise native fetch', () {
      final nativeOptions = <SearchServiceOptions>[
        TavilyOptions(id: 'tavily'),
        ExaOptions(id: 'exa'),
        ZhipuOptions(id: 'zhipu'),
        LinkUpOptions(id: 'linkup'),
        OllamaOptions(id: 'ollama'),
        JinaOptions(id: 'jina'),
        PerplexityOptions(id: 'perplexity'),
        SerperOptions(id: 'serper'),
      ];
      final builtInOptions = <SearchServiceOptions>[
        BingLocalOptions(id: 'bing'),
        DuckDuckGoOptions(id: 'duckduckgo'),
        SearXNGOptions(id: 'searxng', url: 'https://search.test'),
        BraveOptions(id: 'brave'),
        MetasoOptions(id: 'metaso'),
        BochaOptions(id: 'bocha'),
        GrokOptions(id: 'grok'),
        QueritOptions(id: 'querit'),
      ];

      expect(
        nativeOptions.map(
          (options) => SearchService.getService(options).supportsNativeFetch,
        ),
        everyElement(isTrue),
      );
      expect(
        builtInOptions.map(
          (options) => SearchService.getService(options).supportsNativeFetch,
        ),
        everyElement(isFalse),
      );
    });

    for (final fetchCase in cases) {
      test(
        '${fetchCase.name} sends the official request and parses content',
        () async {
          final client = MockClient((request) async {
            fetchCase.checkRequest(request);
            return http.Response(fetchCase.responseBody, 200);
          });

          final result = await fetchCase.service.fetch(
            url: target,
            commonOptions: common,
            serviceOptions: fetchCase.options,
            fetchClient: client,
            apiKeyOverride: 'override-key',
          );

          expect(result.content, fetchCase.expectedContent);
        },
      );

      test(
        '${fetchCase.name} rejects non-success and missing content',
        () async {
          for (final response in [
            http.Response('upstream failed', 503),
            http.Response('{}', 200),
          ]) {
            final client = MockClient((_) async => response);
            expect(
              () => fetchCase.service.fetch(
                url: target,
                commonOptions: common,
                serviceOptions: fetchCase.options,
                fetchClient: client,
                apiKeyOverride: 'override-key',
              ),
              throwsA(isA<Exception>()),
            );
          }
        },
      );
    }

    test(
      'Perplexity rejects content whose URL does not match the request',
      () async {
        final client = MockClient((_) async {
          return http.Response(
            jsonEncode({
              'output': [
                {
                  'type': 'fetch_url_results',
                  'contents': [
                    {'url': 'https://other.example.com/page', 'snippet': 'x'},
                  ],
                },
              ],
            }),
            200,
          );
        });

        await expectLater(
          PerplexitySearchService().fetch(
            url: target,
            commonOptions: common,
            serviceOptions: PerplexityOptions(
              id: 'perplexity',
              apiKeys: [ApiKeyConfig.create('key')],
            ),
            fetchClient: client,
            apiKeyOverride: 'override-key',
          ),
          throwsA(
            isA<Exception>().having(
              (e) => e.toString(),
              'message',
              contains('different URL'),
            ),
          ),
        );
      },
    );

    test('Perplexity accepts a semantically equal URL with reordered query '
        'parameters, trailing slash or encoding differences', () async {
      // Request: https://example.com/article?a=2&x=1
      final echoedUrls = [
        // Reordered query parameters compare equal after normalization.
        'https://example.com/article?x=1&a=2',
        // Trailing slash difference is tolerated (fallback match).
        'https://example.com/article/?x=1&a=2',
        // Host case difference is tolerated.
        'https://EXAMPLE.com/article?x=1&a=2',
        // Different query set: falls back to the origin/path match.
        'https://example.com/article?x=1',
      ];
      for (final echoed in echoedUrls) {
        final client = MockClient((_) async {
          return http.Response(
            jsonEncode({
              'output': [
                {
                  'type': 'fetch_url_results',
                  'contents': [
                    {'url': echoed, 'snippet': 'matched content'},
                  ],
                },
              ],
            }),
            200,
          );
        });

        final result = await PerplexitySearchService().fetch(
          url: Uri.parse('https://example.com/article?a=2&x=1'),
          commonOptions: common,
          serviceOptions: PerplexityOptions(
            id: 'perplexity',
            apiKeys: [ApiKeyConfig.create('key')],
          ),
          fetchClient: client,
          apiKeyOverride: 'override-key',
        );

        expect(result.content, 'matched content', reason: 'echoed $echoed');
      }
    });

    test(
      'Tavily and Exa derive official endpoints from default URLs',
      () async {
        final requested = <Uri>[];
        final client = MockClient((request) async {
          requested.add(request.url);
          if (request.url.host == 'api.tavily.com') {
            return http.Response(
              jsonEncode({
                'results': [
                  {'url': target.toString(), 'raw_content': 'content'},
                ],
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode({
              'results': [
                {'url': target.toString(), 'text': 'content'},
              ],
            }),
            200,
          );
        });

        await TavilySearchService().fetch(
          url: target,
          commonOptions: common,
          serviceOptions: TavilyOptions(
            id: 'tavily',
            apiKeys: [ApiKeyConfig.create('key')],
          ),
          fetchClient: client,
        );
        await ExaSearchService().fetch(
          url: target,
          commonOptions: common,
          serviceOptions: ExaOptions(
            id: 'exa',
            apiKeys: [ApiKeyConfig.create('key')],
          ),
          fetchClient: client,
        );

        expect(requested.map((uri) => uri.toString()), [
          'https://api.tavily.com/extract',
          'https://api.exa.ai/contents',
        ]);
      },
    );

    test('Tavily and Exa reject custom URLs that cannot be derived', () async {
      final client = MockClient(
        (_) async => throw StateError('request must not be sent'),
      );

      for (final entry in <(SearchService, SearchServiceOptions)>[
        (
          TavilySearchService(),
          TavilyOptions(id: 'tavily', url: 'https://gateway.test/api'),
        ),
        (ExaSearchService(), ExaOptions(id: 'exa', url: '/search')),
      ]) {
        expect(
          () => entry.$1.fetch(
            url: target,
            commonOptions: common,
            serviceOptions: entry.$2,
            fetchClient: client,
          ),
          throwsA(isA<Exception>()),
        );
      }
    });
  });
}
