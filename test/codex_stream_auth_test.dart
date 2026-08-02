import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/providers/codex_device_code_controller.dart';
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
      'stale credential refreshes once then fails without an LLM request',
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
      'stale credential refresh rejection propagates as HttpException',
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
}
