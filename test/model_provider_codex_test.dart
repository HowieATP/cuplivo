import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/providers/codex_device_code_controller.dart';
import 'package:Cuplivo/core/providers/model_provider.dart';

/// Client that records every request and rejects them all. The
/// ProviderManager methods under test create their own LLM clients, but the
/// auth guard must fire before any of those is used, so this client stays
/// untouched when the guard behaves.
class _RejectingClient extends http.BaseClient {
  final List<http.Request> requests = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final req = http.Request(request.method, request.url)
      ..headers.addAll(request.headers);
    requests.add(req);
    throw StateError('Unexpected request: ${req.url}');
  }
}

/// Records every request and answers with a fixed failing status, so tests
/// can assert what was put on the wire via the ProviderManager debug client
/// factory without a live server.
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _RejectingClient client;
  late CodexDeviceCodeController controller;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    client = _RejectingClient();
    controller = CodexDeviceCodeController(clientFactory: (proxy) => client);
    CodexDeviceCodeController.debugOverrideInstance(controller);
  });

  tearDown(() {
    controller.resetForTest();
    CodexDeviceCodeController.debugOverrideInstance(
      CodexDeviceCodeController(),
    );
  });

  group('ProviderManager codex branches', () {
    test(
      'testConnection on a codex host without sign-in throws and never sends a request',
      () async {
        // Route the LLM client through the rejecting client too, so a
        // regression that moved the guard after client construction fails
        // loudly instead of silently using a real DioHttpClient.
        ProviderManager.debugClientFactory = (cfg, {proxy}) => client;
        addTearDown(() => ProviderManager.debugClientFactory = null);

        await expectLater(
          ProviderManager.testConnection(
            codexProviderConfig(),
            kCodexModels.first,
          ),
          throwsA(
            isA<HttpException>().having(
              (e) => e.message,
              'message',
              contains('not signed in'),
            ),
          ),
        );

        // The guard fires before the connection client is used: no
        // refresh/LLM traffic may ever be dispatched.
        expect(client.requests, isEmpty);
      },
    );

    test('listModels on a codex host returns the fixed model set', () async {
      // Same lock as testConnection: the codex-host branch must return the
      // fixed model set with zero network traffic.
      ProviderManager.debugClientFactory = (cfg, {proxy}) => client;
      addTearDown(() => ProviderManager.debugClientFactory = null);

      final models = await ProviderManager.listModels(codexProviderConfig());

      expect(models.length, kCodexModels.length);
      expect(models.map((m) => m.id).toSet(), kCodexModels.toSet());
      expect(client.requests, isEmpty);
    });

    test(
      'testConnection on a signed-in codex host sends codex auth headers',
      () async {
        controller.credential = CodexOAuthCredential(
          accessToken: _jwtWithAccount('acc-1'),
          refreshToken: 'rt-old',
          expiresAt: DateTime.now().add(const Duration(hours: 1)),
          accountId: 'acc-1',
        );
        controller.status = CodexAuthStatus.signedIn;
        final recorded = _RecordingClient();
        ProviderManager.debugClientFactory = (cfg, {proxy}) => recorded;
        addTearDown(() => ProviderManager.debugClientFactory = null);

        // The recording client answers 500 so testConnection throws; the
        // assertions only care about the headers that were actually sent.
        await expectLater(
          ProviderManager.testConnection(
            codexProviderConfig(),
            kCodexModels.first,
          ),
          throwsA(isA<HttpException>()),
        );

        expect(recorded.requests, hasLength(1));
        final req = recorded.requests.single;
        expect(
          _headerOf(req, 'Authorization'),
          'Bearer ${_jwtWithAccount('acc-1')}',
        );
        expect(_headerOf(req, 'chatgpt-account-id'), 'acc-1');
        expect(_headerOf(req, 'OpenAI-Beta'), 'responses=experimental');
      },
    );
  });
}
