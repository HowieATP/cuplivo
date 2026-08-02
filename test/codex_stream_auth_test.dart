import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/providers/codex_device_code_controller.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/api/chat_api_service.dart';

/// Scripted http client for the controller's usercode/poll/refresh traffic.
/// The LLM stream itself uses the real DioHttpClient from ChatApiService;
/// these tests assert that the auth guard fires before that client is ever
/// asked to send a request.
class _ScriptedClient extends http.BaseClient {
  final List<FutureOr<http.Response> Function(http.Request)> handlers = [];
  final List<http.Request> requests = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final req = http.Request(request.method, request.url)
      ..headers.addAll(request.headers);
    if (request is http.Request) {
      req.body = request.body;
    }
    requests.add(req);
    if (handlers.isEmpty) {
      throw StateError('No scripted handler for ${req.url}');
    }
    final handler = handlers.removeAt(0);
    final respOrFuture = handler(req);
    final resp = await Future.value(respOrFuture);
    return http.StreamedResponse(
      Stream<List<int>>.fromIterable([utf8.encode(resp.body)]),
      resp.statusCode,
      headers: resp.headers,
    );
  }
}

/// Records every request and answers with a fixed failing status, so tests
/// can assert what was actually put on the wire via the ChatApiService
/// debug client factory without a live server.
class _RecordingClient extends http.BaseClient {
  final List<http.Request> requests = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final req = http.Request(request.method, request.url)
      ..headers.addAll(request.headers);
    if (request is http.Request) {
      req.body = request.body;
    }
    requests.add(req);
    return http.StreamedResponse(
      Stream<List<int>>.empty(),
      500,
      headers: {'content-type': 'application/json'},
    );
  }
}

String? _headerOf(http.Request req, String name) {
  for (final e in req.headers.entries) {
    if (e.key.toLowerCase() == name.toLowerCase()) return e.value;
  }
  return null;
}

http.Response _json(int status, Map<String, dynamic> body) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

String _jwt(String payloadJson) {
  final enc = base64Url.encode(utf8.encode(payloadJson)).replaceAll('=', '');
  return 'eyJhbGciOiJub25lIn0.$enc.c2ln';
}

String _jwtWithAccount(String accountId) => _jwt(
  jsonEncode({
    'iss': 'https://auth.openai.com',
    'https://api.openai.com/auth': {'chatgpt_account_id': accountId},
  }),
);

CodexOAuthCredential _expiredCred(String accountId) => CodexOAuthCredential(
  accessToken: _jwtWithAccount(accountId),
  refreshToken: 'rt-old',
  expiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
  accountId: accountId,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _ScriptedClient client;
  late CodexDeviceCodeController controller;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    client = _ScriptedClient();
    controller = CodexDeviceCodeController(
      clientFactory: (proxy) => client,
      pollDeadline: kCodexFlowDeadline,
    );
    CodexDeviceCodeController.debugOverrideInstance(controller);
  });

  tearDown(() {
    controller.resetForTest();
    CodexDeviceCodeController.debugOverrideInstance(
      CodexDeviceCodeController(),
    );
  });

  group('sendMessageStream auth guard for codex hosts', () {
    test('signed-out codex host fails fast with zero HTTP requests', () async {
      await expectLater(
        ChatApiService.sendMessageStream(
          config: codexProviderConfig(),
          modelId: kCodexModels.first,
          messages: const [
            {'role': 'user', 'content': 'hello'},
          ],
          stream: true,
        ).toList(),
        throwsA(
          isA<HttpException>().having(
            (e) => e.message,
            'message',
            contains('not signed in'),
          ),
        ),
      );

      // ensureFreshOrThrow fires before any request is dispatched, so no
      // usercode/poll/refresh/LLM traffic may ever happen.
      expect(client.requests, isEmpty);
    });

    test(
      'absolutely expired credential refreshes once then fails without an LLM request',
      () async {
        controller.credential = _expiredCred('acc-1');
        controller.status = CodexAuthStatus.expired;
        client.handlers.add(
          (_) async => _json(400, {'error': 'invalid_grant'}),
        );

        await expectLater(
          ChatApiService.sendMessageStream(
            config: codexProviderConfig(),
            modelId: kCodexModels.first,
            messages: const [
              {'role': 'user', 'content': 'hello'},
            ],
            stream: true,
          ).toList(),
          throwsA(
            isA<HttpException>().having(
              (e) => e.message,
              'message',
              // The rejected refresh cleared the credential, so the guard
              // reports the signed-out state.
              contains('not signed in'),
            ),
          ),
        );

        expect(controller.credential, isNull);
        // Exactly one refresh attempt against the token endpoint, and no
        // request against the codex LLM endpoint.
        expect(client.requests.length, 1);
        expect(client.requests.single.url.toString(), kCodexTokenEndpoint);
      },
    );

    test('fresh token passes the guard and injects headers', () async {
      controller.credential = CodexOAuthCredential(
        accessToken: _jwtWithAccount('acc-1'),
        refreshToken: 'rt-old',
        expiresAt: DateTime.now().add(const Duration(minutes: 5)),
        accountId: 'acc-1',
      );
      controller.status = CodexAuthStatus.signedIn;

      // Well inside the freshness window: the guard must pass without any
      // refresh traffic. (The old 30s margin sat inside the 60s grace window
      // and fed a 500 handler that was never consumed; grace-window behavior
      // is covered by codex_device_flow_test's grace-period tests.)
      expect(controller.isFresh, isTrue);
      expect(controller.isUsable, isTrue);

      await CodexDeviceCodeController.ensureFreshOrThrow(codexProviderConfig());

      expect(client.requests, isEmpty);

      final h = controller.maybeCodexHeaders(codexProviderConfig());
      expect(h['Authorization'], 'Bearer ${_jwtWithAccount('acc-1')}');
      expect(h['chatgpt-account-id'], 'acc-1');
    });
  });

  group('generateText auth guard for codex hosts', () {
    test('signed-out codex host fails fast with zero HTTP requests', () async {
      await expectLater(
        ChatApiService.generateText(
          config: codexProviderConfig(),
          modelId: kCodexModels.first,
          prompt: 'hello',
        ),
        throwsA(
          isA<HttpException>().having(
            (e) => e.message,
            'message',
            contains('not signed in'),
          ),
        ),
      );

      // ensureFreshOrThrow fires before any request is dispatched, so no
      // usercode/poll/refresh/LLM traffic may ever happen.
      expect(client.requests, isEmpty);
    });

    test(
      'absolutely expired credential refresh rejection propagates as HttpException',
      () async {
        controller.credential = _expiredCred('acc-1');
        controller.status = CodexAuthStatus.expired;
        client.handlers.add(
          (_) async => _json(400, {'error': 'invalid_grant'}),
        );

        await expectLater(
          ChatApiService.generateText(
            config: codexProviderConfig(),
            modelId: kCodexModels.first,
            prompt: 'hello',
          ),
          throwsA(
            isA<HttpException>().having(
              (e) => e.message,
              'message',
              contains('not signed in'),
            ),
          ),
        );

        expect(controller.credential, isNull);
        // Exactly one refresh attempt, and no codex LLM request.
        expect(client.requests.length, 1);
        expect(client.requests.single.url.toString(), kCodexTokenEndpoint);
      },
    );

    test('fresh credential passes the guard without network traffic', () async {
      controller.credential = CodexOAuthCredential(
        accessToken: _jwtWithAccount('acc-1'),
        refreshToken: 'rt-old',
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
        accountId: 'acc-1',
      );
      controller.status = CodexAuthStatus.signedIn;

      await CodexDeviceCodeController.ensureFreshOrThrow(codexProviderConfig());

      // Fresh session: no refresh and no LLM traffic from the guard.
      expect(client.requests, isEmpty);
      expect(controller.isFresh, isTrue);
    });
  });

  group('codex headers on the wire via the debug client factory', () {
    test(
      'stream request sends codex auth headers with no api-key residue',
      () async {
        controller.credential = CodexOAuthCredential(
          accessToken: _jwtWithAccount('acc-1'),
          refreshToken: 'rt-old',
          expiresAt: DateTime.now().add(const Duration(hours: 1)),
          accountId: 'acc-1',
        );
        controller.status = CodexAuthStatus.signedIn;
        final recorded = _RecordingClient();
        ChatApiService.debugClientFactory = (cfg, {proxy}) => recorded;
        addTearDown(() => ChatApiService.debugClientFactory = null);

        // The recording client answers 500 so the stream errors out; the
        // assertions only care about the headers that were actually sent.
        await expectLater(
          ChatApiService.sendMessageStream(
            config: codexProviderConfig(),
            modelId: kCodexModels.first,
            messages: const [
              {'role': 'user', 'content': 'hello'},
            ],
            stream: true,
          ).toList(),
          throwsA(isA<HttpException>()),
        );

        expect(recorded.requests, hasLength(1));
        final req = recorded.requests.single;
        expect(req.url.host, 'chatgpt.com');
        expect(
          _headerOf(req, 'Authorization'),
          'Bearer ${_jwtWithAccount('acc-1')}',
        );
        expect(_headerOf(req, 'chatgpt-account-id'), 'acc-1');
        // Responses API path: the OpenAI-Beta header must ride along.
        expect(_headerOf(req, 'OpenAI-Beta'), 'responses=experimental');
        // The codex provider's empty API key must not leak a dangling
        // 'Bearer ' prefix: the codex headers overwrite the placeholder.
        expect(_headerOf(req, 'Authorization'), isNot('Bearer '));
      },
    );

    test('stream request without responses api omits OpenAI-Beta', () async {
      controller.credential = CodexOAuthCredential(
        accessToken: _jwtWithAccount('acc-1'),
        refreshToken: 'rt-old',
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
        accountId: 'acc-1',
      );
      controller.status = CodexAuthStatus.signedIn;
      final recorded = _RecordingClient();
      ChatApiService.debugClientFactory = (cfg, {proxy}) => recorded;
      addTearDown(() => ChatApiService.debugClientFactory = null);

      await expectLater(
        ChatApiService.sendMessageStream(
          config: ProviderConfig(
            id: 'Codex',
            enabled: true,
            name: 'Codex',
            apiKey: '',
            baseUrl: kCodexBaseUrl,
            providerType: ProviderKind.openai,
            useResponseApi: false,
            models: kCodexModels,
          ),
          modelId: kCodexModels.first,
          messages: const [
            {'role': 'user', 'content': 'hello'},
          ],
          stream: true,
        ).toList(),
        throwsA(isA<HttpException>()),
      );

      final req = recorded.requests.single;
      expect(
        _headerOf(req, 'Authorization'),
        'Bearer ${_jwtWithAccount('acc-1')}',
      );
      expect(_headerOf(req, 'chatgpt-account-id'), 'acc-1');
      expect(_headerOf(req, 'OpenAI-Beta'), isNull);
    });

    test('non-codex host never receives codex auth headers', () async {
      controller.credential = CodexOAuthCredential(
        accessToken: _jwtWithAccount('acc-1'),
        refreshToken: 'rt-old',
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
        accountId: 'acc-1',
      );
      controller.status = CodexAuthStatus.signedIn;
      final recorded = _RecordingClient();
      ChatApiService.debugClientFactory = (cfg, {proxy}) => recorded;
      addTearDown(() => ChatApiService.debugClientFactory = null);

      // A signed-in Codex controller must not leak OAuth credentials to a
      // plain openai endpoint even when the provider kind is openai.
      await expectLater(
        ChatApiService.sendMessageStream(
          config: ProviderConfig(
            id: 'OpenAI',
            enabled: true,
            name: 'OpenAI',
            apiKey: 'sk-test',
            baseUrl: 'https://api.openai.com/v1',
            providerType: ProviderKind.openai,
            models: const ['gpt-4o'],
          ),
          modelId: 'gpt-4o',
          messages: const [
            {'role': 'user', 'content': 'hello'},
          ],
          stream: true,
        ).toList(),
        throwsA(isA<HttpException>()),
      );

      expect(recorded.requests, hasLength(1));
      final req = recorded.requests.single;
      expect(req.url.host, 'api.openai.com');
      expect(
        _headerOf(req, 'Authorization'),
        isNot('Bearer ${_jwtWithAccount('acc-1')}'),
      );
      expect(_headerOf(req, 'chatgpt-account-id'), isNull);
      // The regular api-key path is untouched.
      expect(_headerOf(req, 'Authorization'), 'Bearer sk-test');
    });
  });
}
