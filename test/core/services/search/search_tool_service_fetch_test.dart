import 'dart:convert';
import 'dart:io';

import 'package:Cuplivo/core/models/api_keys.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/fetch/web_fetch_target_guard.dart';
import 'package:Cuplivo/core/services/search/search_service.dart';
import 'package:Cuplivo/core/services/search/search_tool_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    WebFetchTargetGuard.blockPrivateTargets = false;
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    WebFetchTargetGuard.blockPrivateTargets = true;
  });

  test('fetch tool definition describes strict URL and paging parameters', () {
    final function =
        SearchToolService.getFetchToolDefinition()['function']
            as Map<String, dynamic>;
    final parameters = function['parameters'] as Map<String, dynamic>;
    final properties = parameters['properties'] as Map<String, dynamic>;

    expect(function['name'], 'web_fetch');
    expect(function['description'], contains('provided by the user'));
    expect(parameters['required'], ['url']);
    expect(properties['max_length'], containsPair('maximum', 20000));
    expect(properties['start_index'], containsPair('minimum', 0));

    final builtInFunction =
        SearchToolService.getFetchToolDefinition(
              includeBuiltInOptions: true,
            )['function']
            as Map<String, dynamic>;
    final builtInProperties =
        (builtInFunction['parameters'] as Map<String, dynamic>)['properties']
            as Map<String, dynamic>;
    expect(builtInProperties.keys, containsAll(['headers', 'raw']));
  });

  test(
    'fetch availability follows provider capability and fallback setting',
    () async {
      final settings = SettingsProvider();
      await pumpEventQueue();

      await settings.setSearchServices([TavilyOptions(id: 'native')]);
      expect(
        SearchToolService.selectedProviderSupportsNativeFetch(settings),
        isTrue,
      );
      expect(SearchToolService.shouldExposeFetchTool(settings), isTrue);
      expect(SearchToolService.shouldUseBuiltInFetch(settings), isFalse);

      await settings.setSearchServices([BingLocalOptions(id: 'fallback')]);
      expect(
        SearchToolService.selectedProviderSupportsNativeFetch(settings),
        isFalse,
      );
      expect(SearchToolService.shouldExposeFetchTool(settings), isTrue);
      expect(SearchToolService.shouldUseBuiltInFetch(settings), isTrue);

      await settings.setSearchCommonOptions(
        settings.searchCommonOptions.copyWith(
          enableFetchForUnsupportedProviders: false,
        ),
      );
      expect(SearchToolService.shouldExposeFetchTool(settings), isFalse);
      expect(SearchToolService.shouldUseBuiltInFetch(settings), isTrue);

      await settings.setSearchServices([]);
      expect(SearchToolService.shouldExposeFetchTool(settings), isFalse);
    },
  );

  test(
    'rejects malformed URL and paging arguments before any request',
    () async {
      final settings = SettingsProvider();
      var requests = 0;
      final client = MockClient((_) async {
        requests++;
        return http.Response('{}', 200);
      });

      final arguments = <Map<String, dynamic>>[
        {'url': ''},
        {'url': 'ftp://example.com/file'},
        {'url': 'https://example.com', 'max_length': 0},
        {'url': 'https://example.com', 'max_length': 20001},
        {'url': 'https://example.com', 'max_length': 1.5},
        {'url': 'https://example.com', 'start_index': -1},
      ];
      for (final input in arguments) {
        final result =
            jsonDecode(
                  await SearchToolService.executeFetch(
                    input,
                    settings,
                    fetchClient: client,
                  ),
                )
                as Map<String, dynamic>;
        expect(result['error'], isNotEmpty);
      }
      expect(requests, 0);
    },
  );

  test(
    'rotates native provider keys and returns a standardized window',
    () async {
      final settings = SettingsProvider();
      await settings.setSearchServices([
        TavilyOptions(
          id: 'fetch-rotation-test',
          url: 'https://gateway.test/search',
          apiKeys: [
            ApiKeyConfig.create('first-key'),
            ApiKeyConfig.create('second-key'),
          ],
        ),
      ]);
      final usedKeys = <String>[];
      final client = MockClient((request) async {
        final key = request.headers['Authorization']!;
        usedKeys.add(key);
        if (key == 'Bearer first-key') {
          return http.Response('failed', 503);
        }
        return http.Response(
          jsonEncode({
            'results': [
              {
                'url': 'https://example.com/article',
                'raw_content': '0123456789',
              },
            ],
          }),
          200,
        );
      });

      final result =
          jsonDecode(
                await SearchToolService.executeFetch(
                  {
                    'url': 'https://example.com/article',
                    'start_index': 2,
                    'max_length': 4,
                  },
                  settings,
                  fetchClient: client,
                ),
              )
              as Map<String, dynamic>;

      expect(usedKeys, ['Bearer first-key', 'Bearer second-key']);
      expect(result, containsPair('provider', 'Tavily'));
      expect(result, containsPair('content', '2345'));
      expect(result, containsPair('start_index', 2));
      expect(result, containsPair('end_index', 6));
      expect(result, containsPair('total_length', 10));
      expect(result, containsPair('truncated', true));
      expect(result, containsPair('next_start_index', 6));

      final persistedKeys = settings.searchServices.single.apiKeys;
      expect(persistedKeys.first.usage.failedRequests, 1);
      expect(persistedKeys.last.usage.successfulRequests, 1);
    },
  );

  test('native provider exhausts keys without using built-in fetch', () async {
    final settings = SettingsProvider();
    await settings.setSearchServices([
      TavilyOptions(
        id: 'fetch-all-fail-test',
        apiKeys: [ApiKeyConfig.create('key-a'), ApiKeyConfig.create('key-b')],
      ),
    ]);
    var requests = 0;
    final client = MockClient((_) async {
      requests++;
      return http.Response('failed', 503);
    });

    final result =
        jsonDecode(
              await SearchToolService.executeFetch(
                {'url': 'https://example.com/article'},
                settings,
                fetchClient: client,
              ),
            )
            as Map<String, dynamic>;

    expect(requests, 2);
    expect(result['provider'], 'Tavily');
    expect(result['error'], contains('All Tavily fetch keys failed'));
  });

  test(
    'native provider rejects built-in-only parameters without a request',
    () async {
      final settings = SettingsProvider();
      await settings.setSearchServices([
        TavilyOptions(
          id: 'fetch-unsupported-parameters',
          apiKeys: [ApiKeyConfig.create('key-a')],
        ),
      ]);
      var requests = 0;
      final client = MockClient((_) async {
        requests++;
        return http.Response('{}', 200);
      });

      final result =
          jsonDecode(
                await SearchToolService.executeFetch(
                  {'url': 'https://example.com/article', 'raw': true},
                  settings,
                  fetchClient: client,
                ),
              )
              as Map<String, dynamic>;

      expect(result['code'], 'unsupported_parameters');
      expect(result['error'], contains('raw'));
      expect(requests, 0);
    },
  );

  test('disabled built-in fallback fails before making a request', () async {
    final settings = SettingsProvider();
    await settings.setSearchServices([BingLocalOptions(id: 'bing-disabled')]);
    await settings.setSearchCommonOptions(
      settings.searchCommonOptions.copyWith(
        enableFetchForUnsupportedProviders: false,
      ),
    );

    final result =
        jsonDecode(
              await SearchToolService.executeFetch({
                'url': 'https://example.com/article',
              }, settings),
            )
            as Map<String, dynamic>;

    expect(result['code'], 'built_in_fetch_disabled');
    expect(result['provider'], 'Bing (Local)');
  });

  test('native provider with all keys disabled calls directly instead of '
      'failing rotation', () async {
    final settings = SettingsProvider();
    final disabled = ApiKeyConfig.create('key-a').copyWith(isEnabled: false);
    await settings.setSearchServices([
      TavilyOptions(id: 'all-disabled', apiKeys: [disabled]),
    ]);
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      return http.Response(
        jsonEncode({
          'results': [
            {'url': 'https://example.com/article', 'raw_content': 'ok'},
          ],
        }),
        200,
      );
    });

    final result =
        jsonDecode(
              await SearchToolService.executeFetch(
                {'url': 'https://example.com/article'},
                settings,
                fetchClient: client,
              ),
            )
            as Map<String, dynamic>;

    expect(requests, 1);
    expect(result['provider'], 'Tavily');
    expect(result['content'], 'ok');
  });

  test(
    'provider without native fetch uses the built-in readable fetcher',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) async {
        request.response.headers.contentType = ContentType.html;
        request.response.write(
          '<html><head><title>Local title</title></head>'
          '<body><main><h1>Hello</h1><p>Built-in body</p></main></body></html>',
        );
        await request.response.close();
      });
      addTearDown(() async {
        await subscription.cancel();
        await server.close(force: true);
      });
      final settings = SettingsProvider();
      await settings.setSearchServices([BingLocalOptions(id: 'bing')]);
      final url = 'http://${server.address.host}:${server.port}/page';

      final result =
          jsonDecode(
                await SearchToolService.executeFetch({'url': url}, settings),
              )
              as Map<String, dynamic>;

      expect(result['provider'], 'Cuplivo Built-in');
      expect(result['url'], url);
      expect(result['title'], 'Local title');
      expect(result['content'], contains('Hello'));
      expect(result['content'], contains('Built-in body'));
      expect(result['truncated'], isFalse);
    },
  );

  test('built-in fetch rejects binary content as a page body', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      request.response.headers.contentType = ContentType.binary;
      request.response.add([0, 1, 2, 3]);
      await request.response.close();
    });
    addTearDown(() async {
      await subscription.cancel();
      await server.close(force: true);
    });
    final settings = SettingsProvider();
    await settings.setSearchServices([BingLocalOptions(id: 'bing')]);
    final url = 'http://${server.address.host}:${server.port}/binary';

    final result =
        jsonDecode(await SearchToolService.executeFetch({'url': url}, settings))
            as Map<String, dynamic>;

    expect(result['provider'], 'Cuplivo Built-in');
    expect(result['url'], url);
    expect(result['error'], contains('Binary content is not supported'));
  });
}
