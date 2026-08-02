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
      final models = await ProviderManager.listModels(codexProviderConfig());

      expect(models.length, kCodexModels.length);
      expect(models.map((m) => m.id).toSet(), kCodexModels.toSet());
    });
  });
}
