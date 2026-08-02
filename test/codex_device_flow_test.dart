import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:Cuplivo/core/providers/codex_device_code_controller.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/network/dio_http_client.dart';

class _ScriptedClient extends http.BaseClient {
  final List<FutureOr<http.Response> Function(http.Request)> handlers = [];
  final List<http.Request> requests = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    // Limitation: only http.Request bodies are copied. StreamedRequest /
    // MultipartRequest payloads are dropped (the controller's traffic is all
    // client.post with a String body, so this is fine for now).
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

/// SharedPreferences store that can park a write on a gate. Lets a test land
/// a cancel() deterministically while the controller's credential persist is
/// still in flight - the one race window the poll-loop and exchange cancel
/// checks cannot observe from the scripted client side.
class _GatedPrefsStore extends SharedPreferencesStorePlatform {
  final Map<String, Object> data = {};
  final Completer<void> _writeStarted = Completer<void>();
  Completer<void>? _writeGate;
  final Completer<void> _removeStarted = Completer<void>();
  Completer<void>? _removeGate;

  void parkWrite() {
    _writeGate = Completer<void>();
  }

  void releaseWrite() {
    _writeGate?.complete();
  }

  /// Completes when the parked write has actually been invoked.
  Future<void> get writeStarted => _writeStarted.future;

  void parkRemove() {
    _removeGate = Completer<void>();
  }

  void releaseRemove() {
    _removeGate?.complete();
  }

  /// Completes when the parked remove has actually been invoked.
  Future<void> get removeStarted => _removeStarted.future;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    final gate = _writeGate;
    if (gate != null) {
      if (!_writeStarted.isCompleted) _writeStarted.complete();
      await gate.future;
      // Only clear after the release so releaseWrite can still complete the
      // gate while this write is parked on it.
      _writeGate = null;
    }
    data[key] = value;
    return true;
  }

  @override
  Future<Map<String, Object>> getAll() async => Map<String, Object>.of(data);

  @override
  Future<bool> remove(String key) async {
    final gate = _removeGate;
    if (gate != null) {
      if (!_removeStarted.isCompleted) _removeStarted.complete();
      await gate.future;
      _removeGate = null;
    }
    data.remove(key);
    return true;
  }

  @override
  Future<bool> clear() async {
    data.clear();
    return true;
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

Map<String, dynamic> _tokenBody(String accountId, {int expiresIn = 3600}) => {
  'access_token': _jwtWithAccount(accountId),
  'refresh_token': 'rt-1',
  'expires_in': expiresIn,
};

ProviderConfig _cfg({
  String id = 'OpenAI',
  String baseUrl = 'https://api.openai.com/v1',
  ProviderKind? kind,
  bool? multiKey,
  bool? useResponseApi,
  bool? proxyEnabled,
  String proxyHost = '',
  String proxyPort = '',
  String proxyUsername = '',
  String proxyPassword = '',
}) => ProviderConfig(
  id: id,
  enabled: true,
  name: id,
  apiKey: '',
  baseUrl: baseUrl,
  providerType: kind,
  multiKeyEnabled: multiKey,
  useResponseApi: useResponseApi,
  proxyEnabled: proxyEnabled,
  proxyHost: proxyHost,
  proxyPort: proxyPort,
  proxyUsername: proxyUsername,
  proxyPassword: proxyPassword,
);

CodexOAuthCredential _freshCred(String accountId) => CodexOAuthCredential(
  accessToken: _jwtWithAccount(accountId),
  refreshToken: 'rt-old',
  expiresAt: DateTime.now().add(const Duration(hours: 1)),
  accountId: accountId,
);

CodexOAuthCredential _expiredCred(String accountId) => CodexOAuthCredential(
  accessToken: _jwtWithAccount(accountId),
  refreshToken: 'rt-old',
  expiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
  accountId: accountId,
);

/// Token still inside the absolute validity window but past the 60s refresh
/// grace: [isFresh] is false while [isUsable] stays true.
CodexOAuthCredential _graceCred(String accountId) => CodexOAuthCredential(
  accessToken: _jwtWithAccount(accountId),
  refreshToken: 'rt-old',
  expiresAt: DateTime.now().add(const Duration(seconds: 30)),
  accountId: accountId,
);

String? _headerOf(http.Request req, String name) {
  for (final e in req.headers.entries) {
    if (e.key.toLowerCase() == name.toLowerCase()) return e.value;
  }
  return null;
}

Future<void> _waitForRequests(
  _ScriptedClient client,
  int count, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (client.requests.length < count && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  if (client.requests.length < count) {
    throw StateError(
      'Timed out waiting for $count requests; got ${client.requests.length}',
    );
  }
}

void main() {
  late _ScriptedClient client;
  late CodexDeviceCodeController controller;
  int onAuthenticatedCalls = 0;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    client = _ScriptedClient();
    controller = CodexDeviceCodeController(
      clientFactory: (proxy) => client,
      pollDeadline: kCodexFlowDeadline,
    );
    CodexDeviceCodeController.debugOverrideInstance(controller);
    onAuthenticatedCalls = 0;
  });

  tearDown(() {
    controller.resetForTest();
    CodexDeviceCodeController.debugOverrideInstance(
      CodexDeviceCodeController(),
    );
  });

  group('startFlow', () {
    test('happy path exchanges and persists credential', () async {
      DateTime? poll1At;
      DateTime? poll2At;
      client.handlers.add(
        (_) async => _json(200, {
          'device_auth_id': 'da-1',
          'user_code': 'ABC-DEF',
          'interval': '2',
        }),
      );
      client.handlers.add((_) async {
        poll1At = DateTime.now();
        return http.Response('{}', 403);
      });
      client.handlers.add((_) async {
        poll2At = DateTime.now();
        return _json(200, {
          'authorization_code': 'ac-1',
          'code_verifier': 'cv-1',
        });
      });
      client.handlers.add((_) async => _json(200, _tokenBody('acc-1')));

      final outcome = await controller.startFlow(
        cfg: codexProviderConfig(),
        onAuthenticated: () async {
          onAuthenticatedCalls++;
        },
      );

      expect(outcome, CodexFlowOutcome.success);
      expect(controller.status, CodexAuthStatus.signedIn);
      expect(controller.credential, isNotNull);
      expect(controller.credential!.accountId, 'acc-1');
      expect(onAuthenticatedCalls, 1);
      expect(client.requests.length, 4);

      final usercodeReq = client.requests[0];
      expect(usercodeReq.url.toString(), kCodexUsercodeEndpoint);
      expect(usercodeReq.body, jsonEncode({'client_id': kCodexClientId}));

      final pollReq = client.requests[1];
      expect(pollReq.url.toString(), kCodexPollEndpoint);
      expect(jsonDecode(pollReq.body), {
        'device_auth_id': 'da-1',
        'user_code': 'ABC-DEF',
      });

      final exchangeReq = client.requests[3];
      expect(exchangeReq.url.toString(), kCodexTokenEndpoint);
      expect(
        _headerOf(exchangeReq, 'Content-Type'),
        'application/x-www-form-urlencoded',
      );
      expect(exchangeReq.body, contains('grant_type=authorization_code'));
      expect(exchangeReq.body, contains('code=ac-1'));
      expect(exchangeReq.body, contains('code_verifier=cv-1'));
      expect(
        exchangeReq.body,
        contains(
          'redirect_uri=${Uri.encodeQueryComponent('https://auth.openai.com/deviceauth/callback')}',
        ),
      );
      expect(exchangeReq.body, contains('client_id=$kCodexClientId'));

      // String interval '2' honored: the wait lands in [1.5s, 4.5s), which
      // the 5s default (>= 4.5s) and the 1s minimum clamp (~1s) cannot
      // satisfy, so this window pins the server value (1500ms lower bound
      // excludes a regression to the 1s clamp; the 4.5s upper bound leaves
      // slack for the 2s sleep's scheduling noise).
      final pollGap = poll2At!.difference(poll1At!);
      expect(pollGap, greaterThanOrEqualTo(const Duration(milliseconds: 1500)));
      expect(pollGap, lessThan(const Duration(milliseconds: 4500)));

      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(kCodexPrefsKey);
      expect(raw, isNotNull);
      final decoded = jsonDecode(raw!) as Map<String, dynamic>;
      expect(decoded['accountId'], 'acc-1');
      expect(decoded['refreshToken'], 'rt-1');
      expect(decoded['expiresAt'], isA<num>());
      expect(decoded['proxy'], isNull);
    });

    test('happy path persists the sign-in proxy in prefs', () async {
      client.handlers.add(
        (_) async => _json(200, {
          'device_auth_id': 'da-1',
          'user_code': 'ABC-DEF',
          'interval': '1',
        }),
      );
      client.handlers.add(
        (_) async =>
            _json(200, {'authorization_code': 'ac-1', 'code_verifier': 'cv-1'}),
      );
      client.handlers.add((_) async => _json(200, _tokenBody('acc-1')));

      final outcome = await controller.startFlow(
        cfg: _cfg(
          id: 'Codex',
          baseUrl: kCodexBaseUrl,
          proxyEnabled: true,
          proxyHost: '127.0.0.1',
          proxyPort: '1080',
          proxyUsername: 'user',
          proxyPassword: 'pass',
        ),
        onAuthenticated: () async {},
      );

      expect(outcome, CodexFlowOutcome.success);
      expect(controller.credential!.proxy, isNotNull);
      expect(controller.credential!.proxy!.host, '127.0.0.1');
      expect(controller.credential!.proxy!.port, 1080);
      expect(controller.credential!.proxy!.type, 'http');
      expect(controller.credential!.proxy!.username, 'user');
      expect(controller.credential!.proxy!.password, 'pass');

      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(kCodexPrefsKey);
      expect(raw, isNotNull);
      final decoded = jsonDecode(raw!) as Map<String, dynamic>;
      expect(decoded['proxy'], {
        'type': 'http',
        'host': '127.0.0.1',
        'port': 1080,
        'username': 'user',
        'password': 'pass',
      });
    });

    test('usercode 404 returns notEnabled with zero polls', () async {
      client.handlers.add((_) async => http.Response('{}', 404));

      final outcome = await controller.startFlow(
        cfg: codexProviderConfig(),
        onAuthenticated: () async {
          onAuthenticatedCalls++;
        },
      );

      expect(outcome, CodexFlowOutcome.notEnabled);
      expect(client.requests.length, 1);
      expect(controller.status, CodexAuthStatus.signedOut);
      expect(onAuthenticatedCalls, 0);
    });

    test('missing interval falls back to 5s default', () async {
      DateTime? poll1At;
      DateTime? poll2At;
      client.handlers.add(
        (_) async =>
            _json(200, {'device_auth_id': 'da-1', 'user_code': 'ABC-DEF'}),
      );
      client.handlers.add((_) async {
        poll1At = DateTime.now();
        return http.Response('{}', 403);
      });
      client.handlers.add((_) async {
        poll2At = DateTime.now();
        return _json(200, {
          'authorization_code': 'ac-1',
          'code_verifier': 'cv-1',
        });
      });
      client.handlers.add((_) async => _json(200, _tokenBody('acc-1')));

      final outcome = await controller.startFlow(
        cfg: codexProviderConfig(),
        onAuthenticated: () async {},
      );

      expect(outcome, CodexFlowOutcome.success);
      expect(
        poll2At!.difference(poll1At!),
        greaterThanOrEqualTo(const Duration(seconds: 4)),
      );
    });

    test('invalid interval string falls back to 5s default', () async {
      DateTime? poll1At;
      DateTime? poll2At;
      client.handlers.add(
        (_) async => _json(200, {
          'device_auth_id': 'da-1',
          'user_code': 'ABC-DEF',
          'interval': 'abc',
        }),
      );
      client.handlers.add((_) async {
        poll1At = DateTime.now();
        return http.Response('{}', 403);
      });
      client.handlers.add((_) async {
        poll2At = DateTime.now();
        return _json(200, {
          'authorization_code': 'ac-1',
          'code_verifier': 'cv-1',
        });
      });
      client.handlers.add((_) async => _json(200, _tokenBody('acc-1')));

      final outcome = await controller.startFlow(
        cfg: codexProviderConfig(),
        onAuthenticated: () async {},
      );

      expect(outcome, CodexFlowOutcome.success);
      expect(
        poll2At!.difference(poll1At!),
        greaterThanOrEqualTo(const Duration(seconds: 4)),
      );
    });

    test(
      'pending poll forms (403/404/string error/map error) tolerated',
      () async {
        client.handlers.add(
          (_) async => _json(200, {
            'device_auth_id': 'da-1',
            'user_code': 'ABC-DEF',
            'interval': '1',
          }),
        );
        client.handlers.add((_) async => http.Response('{}', 403));
        client.handlers.add((_) async => http.Response('{}', 404));
        client.handlers.add(
          (_) async =>
              _json(400, {'error': 'deviceauth_authorization_pending'}),
        );
        client.handlers.add(
          (_) async => _json(400, {
            'error': {'code': 'deviceauth_authorization_pending'},
          }),
        );
        client.handlers.add(
          (_) async => _json(200, {
            'authorization_code': 'ac-1',
            'code_verifier': 'cv-1',
          }),
        );
        client.handlers.add((_) async => _json(200, _tokenBody('acc-1')));

        final outcome = await controller.startFlow(
          cfg: codexProviderConfig(),
          onAuthenticated: () async {},
        );

        expect(outcome, CodexFlowOutcome.success);
        expect(client.requests.length, 7);
        for (final req in client.requests.sublist(1, 5)) {
          expect(
            req.body,
            jsonEncode({'device_auth_id': 'da-1', 'user_code': 'ABC-DEF'}),
          );
        }
      },
    );

    test('403 with denied error code fails immediately', () async {
      client.handlers.add(
        (_) async => _json(200, {
          'device_auth_id': 'da-1',
          'user_code': 'ABC-DEF',
          'interval': '1',
        }),
      );
      client.handlers.add(
        (_) async => _json(403, {
          'error': {'code': 'access_denied'},
        }),
      );

      final outcome = await controller.startFlow(
        cfg: codexProviderConfig(),
        onAuthenticated: () async {},
      );

      expect(outcome, CodexFlowOutcome.failed);
      expect(controller.status, CodexAuthStatus.failed);
      expect(client.requests.length, 2);
    });

    test('404 with expired_token error code fails immediately', () async {
      client.handlers.add(
        (_) async => _json(200, {
          'device_auth_id': 'da-1',
          'user_code': 'ABC-DEF',
          'interval': '1',
        }),
      );
      client.handlers.add((_) async => _json(404, {'error': 'expired_token'}));

      final outcome = await controller.startFlow(
        cfg: codexProviderConfig(),
        onAuthenticated: () async {},
      );

      expect(outcome, CodexFlowOutcome.failed);
      expect(controller.status, CodexAuthStatus.failed);
      expect(client.requests.length, 2);
    });

    test('403 with an unknown rejection code fails fast', () async {
      client.handlers.add(
        (_) async => _json(200, {
          'device_auth_id': 'da-1',
          'user_code': 'ABC-DEF',
          'interval': '1',
        }),
      );
      client.handlers.add(
        (_) async => _json(403, {
          'error': {'code': 'some_unknown_rejection'},
        }),
      );

      final outcome = await controller.startFlow(
        cfg: codexProviderConfig(),
        onAuthenticated: () async {},
      );

      expect(outcome, CodexFlowOutcome.failed);
      expect(controller.status, CodexAuthStatus.failed);
      expect(
        controller.errorMessage,
        contains('rejected with code: some_unknown_rejection'),
      );
      expect(client.requests.length, 2);
    });

    test('403 with pending error code keeps polling', () async {
      client.handlers.add(
        (_) async => _json(200, {
          'device_auth_id': 'da-1',
          'user_code': 'ABC-DEF',
          'interval': '1',
        }),
      );
      client.handlers.add(
        (_) async => _json(403, {'error': 'deviceauth_authorization_pending'}),
      );
      client.handlers.add(
        (_) async =>
            _json(200, {'authorization_code': 'ac-1', 'code_verifier': 'cv-1'}),
      );
      client.handlers.add((_) async => _json(200, _tokenBody('acc-1')));

      final outcome = await controller.startFlow(
        cfg: codexProviderConfig(),
        onAuthenticated: () async {},
      );

      // The pending code must not be swallowed by the unknown-code fail-fast:
      // a subsequent poll request proves the loop kept going.
      expect(outcome, CodexFlowOutcome.success);
      expect(client.requests.length, 4);
      expect(client.requests[2].url.toString(), kCodexPollEndpoint);
    });

    test('429 poll keeps polling instead of failing fast', () async {
      client.handlers.add(
        (_) async => _json(200, {
          'device_auth_id': 'da-1',
          'user_code': 'ABC-DEF',
          'interval': '1',
        }),
      );
      client.handlers.add((_) async => _json(429, {'error': 'server_busy'}));
      client.handlers.add(
        (_) async =>
            _json(200, {'authorization_code': 'ac-1', 'code_verifier': 'cv-1'}),
      );
      client.handlers.add((_) async => _json(200, _tokenBody('acc-1')));

      final outcome = await controller.startFlow(
        cfg: codexProviderConfig(),
        onAuthenticated: () async {},
      );

      // A transient rate limit must not kill the login: the loop keeps
      // polling until a success or the deadline.
      expect(outcome, CodexFlowOutcome.success);
      expect(client.requests.length, 4);
      expect(client.requests[2].url.toString(), kCodexPollEndpoint);
    });

    test('500 poll keeps polling instead of failing fast', () async {
      client.handlers.add(
        (_) async => _json(200, {
          'device_auth_id': 'da-1',
          'user_code': 'ABC-DEF',
          'interval': '1',
        }),
      );
      client.handlers.add((_) async => http.Response('oops', 500));
      client.handlers.add(
        (_) async =>
            _json(200, {'authorization_code': 'ac-1', 'code_verifier': 'cv-1'}),
      );
      client.handlers.add((_) async => _json(200, _tokenBody('acc-1')));

      final outcome = await controller.startFlow(
        cfg: codexProviderConfig(),
        onAuthenticated: () async {},
      );

      expect(outcome, CodexFlowOutcome.success);
      expect(client.requests.length, 4);
      expect(client.requests[2].url.toString(), kCodexPollEndpoint);
    });

    test(
      'poll SocketException keeps polling instead of failing the login',
      () async {
        client.handlers.add(
          (_) async => _json(200, {
            'device_auth_id': 'da-1',
            'user_code': 'ABC-DEF',
            'interval': '1',
          }),
        );
        client.handlers.add(
          (_) async => throw const SocketException('refused'),
        );
        client.handlers.add(
          (_) async => _json(200, {
            'authorization_code': 'ac-1',
            'code_verifier': 'cv-1',
          }),
        );
        client.handlers.add((_) async => _json(200, _tokenBody('acc-1')));

        final outcome = await controller.startFlow(
          cfg: codexProviderConfig(),
          onAuthenticated: () async {},
        );

        // A transient network failure must not kill the login: the loop keeps
        // polling until a success or the deadline instead of surfacing a
        // failed login.
        expect(outcome, CodexFlowOutcome.success);
        expect(client.requests.length, 4);
        expect(client.requests[2].url.toString(), kCodexPollEndpoint);
      },
    );

    test('502 poll with an error code keeps polling too', () async {
      client.handlers.add(
        (_) async => _json(200, {
          'device_auth_id': 'da-1',
          'user_code': 'ABC-DEF',
          'interval': '1',
        }),
      );
      client.handlers.add((_) async => _json(502, {'error': 'bad_gateway'}));
      client.handlers.add(
        (_) async =>
            _json(200, {'authorization_code': 'ac-1', 'code_verifier': 'cv-1'}),
      );
      client.handlers.add((_) async => _json(200, _tokenBody('acc-1')));

      final outcome = await controller.startFlow(
        cfg: codexProviderConfig(),
        onAuthenticated: () async {},
      );

      expect(outcome, CodexFlowOutcome.success);
      expect(client.requests.length, 4);
    });

    test('400 with an unknown error code still fails fast', () async {
      client.handlers.add(
        (_) async => _json(200, {
          'device_auth_id': 'da-1',
          'user_code': 'ABC-DEF',
          'interval': '1',
        }),
      );
      client.handlers.add((_) async => _json(400, {'error': 'bad_request'}));

      final outcome = await controller.startFlow(
        cfg: codexProviderConfig(),
        onAuthenticated: () async {},
      );

      expect(outcome, CodexFlowOutcome.failed);
      expect(controller.status, CodexAuthStatus.failed);
      expect(client.requests.length, 2);
    });

    test('403 slow_down keeps polling instead of failing fast', () async {
      client.handlers.add(
        (_) async => _json(200, {
          'device_auth_id': 'da-1',
          'user_code': 'ABC-DEF',
          'interval': '1',
        }),
      );
      client.handlers.add(
        (_) async => _json(403, {
          'error': {'code': 'slow_down'},
        }),
      );
      client.handlers.add(
        (_) async =>
            _json(200, {'authorization_code': 'ac-1', 'code_verifier': 'cv-1'}),
      );
      client.handlers.add((_) async => _json(200, _tokenBody('acc-1')));

      final outcome = await controller.startFlow(
        cfg: codexProviderConfig(),
        onAuthenticated: () async {},
      );

      expect(outcome, CodexFlowOutcome.success);
      // slow_down must not be swallowed by the unknown-code fail-fast: a
      // subsequent poll request proves the loop kept going.
      expect(client.requests.length, 4);
      expect(client.requests[2].url.toString(), kCodexPollEndpoint);
    });

    test('slow_down grows the poll interval', () async {
      DateTime? poll1At;
      DateTime? poll2At;
      client.handlers.add(
        (_) async => _json(200, {
          'device_auth_id': 'da-1',
          'user_code': 'ABC-DEF',
          'interval': '1',
        }),
      );
      client.handlers.add((_) async {
        poll1At = DateTime.now();
        return _json(429, {'error': 'slow_down'});
      });
      client.handlers.add((_) async {
        poll2At = DateTime.now();
        return _json(200, {
          'authorization_code': 'ac-1',
          'code_verifier': 'cv-1',
        });
      });
      client.handlers.add((_) async => _json(200, _tokenBody('acc-1')));

      final outcome = await controller.startFlow(
        cfg: codexProviderConfig(),
        onAuthenticated: () async {},
      );

      expect(outcome, CodexFlowOutcome.success);
      // base interval 1s + 5s slow_down increment
      expect(
        poll2At!.difference(poll1At!),
        greaterThanOrEqualTo(const Duration(seconds: 6)),
      );
    });

    test('poll 200 missing code_verifier fails', () async {
      client.handlers.add(
        (_) async => _json(200, {
          'device_auth_id': 'da-1',
          'user_code': 'ABC-DEF',
          'interval': '1',
        }),
      );
      client.handlers.add(
        (_) async => _json(200, {'authorization_code': 'ac-1'}),
      );

      final outcome = await controller.startFlow(
        cfg: codexProviderConfig(),
        onAuthenticated: () async {},
      );

      expect(outcome, CodexFlowOutcome.failed);
      expect(controller.status, CodexAuthStatus.failed);
      expect(onAuthenticatedCalls, 0);
    });

    test('poll 200 missing authorization_code fails', () async {
      client.handlers.add(
        (_) async => _json(200, {
          'device_auth_id': 'da-1',
          'user_code': 'ABC-DEF',
          'interval': '1',
        }),
      );
      client.handlers.add((_) async => _json(200, {'code_verifier': 'cv-1'}));

      final outcome = await controller.startFlow(
        cfg: codexProviderConfig(),
        onAuthenticated: () async {},
      );

      expect(outcome, CodexFlowOutcome.failed);
      expect(controller.status, CodexAuthStatus.failed);
      expect(onAuthenticatedCalls, 0);
    });

    test('exchange 400 fails without persisting', () async {
      client.handlers.add(
        (_) async => _json(200, {
          'device_auth_id': 'da-1',
          'user_code': 'ABC-DEF',
          'interval': '1',
        }),
      );
      client.handlers.add(
        (_) async =>
            _json(200, {'authorization_code': 'ac-1', 'code_verifier': 'cv-1'}),
      );
      client.handlers.add((_) async => _json(400, {'error': 'invalid_grant'}));

      final outcome = await controller.startFlow(
        cfg: codexProviderConfig(),
        onAuthenticated: () async {
          onAuthenticatedCalls++;
        },
      );

      expect(outcome, CodexFlowOutcome.failed);
      expect(controller.status, CodexAuthStatus.failed);
      expect(controller.credential, isNull);
      expect(onAuthenticatedCalls, 0);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kCodexPrefsKey), isNull);
    });

    test('exchange 500 fails without persisting', () async {
      client.handlers.add(
        (_) async => _json(200, {
          'device_auth_id': 'da-1',
          'user_code': 'ABC-DEF',
          'interval': '1',
        }),
      );
      client.handlers.add(
        (_) async =>
            _json(200, {'authorization_code': 'ac-1', 'code_verifier': 'cv-1'}),
      );
      client.handlers.add((_) async => http.Response('oops', 500));

      final outcome = await controller.startFlow(
        cfg: codexProviderConfig(),
        onAuthenticated: () async {
          onAuthenticatedCalls++;
        },
      );

      expect(outcome, CodexFlowOutcome.failed);
      expect(controller.status, CodexAuthStatus.failed);
      expect(controller.credential, isNull);
      expect(onAuthenticatedCalls, 0);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kCodexPrefsKey), isNull);
    });

    test('exchange 200 with non-JSON body fails without persisting', () async {
      client.handlers.add(
        (_) async => _json(200, {
          'device_auth_id': 'da-1',
          'user_code': 'ABC-DEF',
          'interval': '1',
        }),
      );
      client.handlers.add(
        (_) async =>
            _json(200, {'authorization_code': 'ac-1', 'code_verifier': 'cv-1'}),
      );
      client.handlers.add((_) async => http.Response('OK', 200));

      final outcome = await controller.startFlow(
        cfg: codexProviderConfig(),
        onAuthenticated: () async {
          onAuthenticatedCalls++;
        },
      );

      // A 200 with a non-JSON body is treated as a missing-fields response:
      // fail cleanly instead of crashing on the decode.
      expect(outcome, CodexFlowOutcome.failed);
      expect(controller.status, CodexAuthStatus.failed);
      expect(controller.errorMessage, contains('missing fields'));
      expect(controller.credential, isNull);
      expect(onAuthenticatedCalls, 0);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kCodexPrefsKey), isNull);
    });

    test('exchange SocketException fails without persisting', () async {
      client.handlers.add(
        (_) async => _json(200, {
          'device_auth_id': 'da-1',
          'user_code': 'ABC-DEF',
          'interval': '1',
        }),
      );
      client.handlers.add(
        (_) async =>
            _json(200, {'authorization_code': 'ac-1', 'code_verifier': 'cv-1'}),
      );
      client.handlers.add((_) async => throw const SocketException('refused'));

      final outcome = await controller.startFlow(
        cfg: codexProviderConfig(),
        onAuthenticated: () async {
          onAuthenticatedCalls++;
        },
      );

      expect(outcome, CodexFlowOutcome.failed);
      expect(controller.status, CodexAuthStatus.failed);
      expect(controller.credential, isNull);
      expect(onAuthenticatedCalls, 0);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kCodexPrefsKey), isNull);
    });

    test('exchange TimeoutException fails without persisting', () async {
      client.handlers.add(
        (_) async => _json(200, {
          'device_auth_id': 'da-1',
          'user_code': 'ABC-DEF',
          'interval': '1',
        }),
      );
      client.handlers.add(
        (_) async =>
            _json(200, {'authorization_code': 'ac-1', 'code_verifier': 'cv-1'}),
      );
      client.handlers.add((_) async => throw TimeoutException('slow'));

      final outcome = await controller.startFlow(
        cfg: codexProviderConfig(),
        onAuthenticated: () async {
          onAuthenticatedCalls++;
        },
      );

      expect(outcome, CodexFlowOutcome.failed);
      expect(controller.status, CodexAuthStatus.failed);
      expect(controller.credential, isNull);
      expect(onAuthenticatedCalls, 0);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kCodexPrefsKey), isNull);
    });

    test('usercode SocketException returns failed', () async {
      client.handlers.add((_) async => throw const SocketException('refused'));

      final outcome = await controller.startFlow(
        cfg: codexProviderConfig(),
        onAuthenticated: () async {},
      );

      expect(outcome, CodexFlowOutcome.failed);
      expect(controller.status, CodexAuthStatus.failed);
      expect(controller.credential, isNull);
      expect(onAuthenticatedCalls, 0);
    });

    test('usercode TimeoutException returns failed', () async {
      client.handlers.add((_) async => throw TimeoutException('slow'));

      final outcome = await controller.startFlow(
        cfg: codexProviderConfig(),
        onAuthenticated: () async {},
      );

      expect(outcome, CodexFlowOutcome.failed);
      expect(controller.status, CodexAuthStatus.failed);
      expect(controller.credential, isNull);
      expect(onAuthenticatedCalls, 0);
    });

    test('poll deadline exceeded returns timedOut', () async {
      final shortController = CodexDeviceCodeController(
        clientFactory: (proxy) => client,
        pollDeadline: const Duration(milliseconds: 300),
      );
      CodexDeviceCodeController.debugOverrideInstance(shortController);
      client.handlers.add(
        (_) async => _json(200, {
          'device_auth_id': 'da-1',
          'user_code': 'ABC-DEF',
          'interval': '1',
        }),
      );
      client.handlers.add((_) async => http.Response('{}', 403));
      client.handlers.add((_) async => http.Response('{}', 403));

      final sw = Stopwatch()..start();
      final outcome = await shortController.startFlow(
        cfg: codexProviderConfig(),
        onAuthenticated: () async {},
      );
      sw.stop();

      expect(outcome, CodexFlowOutcome.timedOut);
      expect(shortController.status, CodexAuthStatus.signedOut);
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
      expect(client.requests.length, greaterThanOrEqualTo(2));
    });

    test('cancel during polling aborts without persisting', () async {
      client.handlers.add(
        (_) async => _json(200, {
          'device_auth_id': 'da-1',
          'user_code': 'ABC-DEF',
          'interval': '5',
        }),
      );
      client.handlers.add((_) async => http.Response('{}', 403));

      final sw = Stopwatch()..start();
      final flow = controller.startFlow(
        cfg: codexProviderConfig(),
        onAuthenticated: () async {
          onAuthenticatedCalls++;
        },
      );
      await _waitForRequests(client, 2);
      controller.cancel();
      final outcome = await flow.timeout(const Duration(seconds: 5));
      sw.stop();

      expect(outcome, CodexFlowOutcome.cancelled);
      expect(controller.status, CodexAuthStatus.signedOut);
      expect(onAuthenticatedCalls, 0);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kCodexPrefsKey), isNull);
      // interval '5' would sleep ~5s if the cancel did not wake the poll
      // loop; the interrupt must end the flow well before that.
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('cancel during exchange discards credential', () async {
      final exchangeGate = Completer<http.Response>();
      client.handlers.add(
        (_) async => _json(200, {
          'device_auth_id': 'da-1',
          'user_code': 'ABC-DEF',
          'interval': '1',
        }),
      );
      client.handlers.add(
        (_) async =>
            _json(200, {'authorization_code': 'ac-1', 'code_verifier': 'cv-1'}),
      );
      client.handlers.add((_) => exchangeGate.future);

      final flow = controller.startFlow(
        cfg: codexProviderConfig(),
        onAuthenticated: () async {
          onAuthenticatedCalls++;
        },
      );
      await _waitForRequests(client, 3);
      controller.cancel();
      // Release the exchange response only after the cancel landed, so the
      // ordering is deterministic instead of racing a fixed delay.
      exchangeGate.complete(_json(200, _tokenBody('acc-1')));
      final outcome = await flow.timeout(const Duration(seconds: 5));

      expect(outcome, CodexFlowOutcome.cancelled);
      expect(controller.status, CodexAuthStatus.signedOut);
      expect(controller.credential, isNull);
      expect(onAuthenticatedCalls, 0);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kCodexPrefsKey), isNull);
    });

    test('cancel landing while the credential persist is in flight resets the '
        'flow for reentry', () async {
      // Park the persist write so the cancel lands exactly inside
      // _persistCredential: the one window neither the poll-loop nor the
      // exchange cancel checks can observe from the scripted client.
      SharedPreferences.setMockInitialValues({});
      final gated = _GatedPrefsStore();
      SharedPreferencesStorePlatform.instance = gated;
      client.handlers.add(
        (_) async => _json(200, {
          'device_auth_id': 'da-1',
          'user_code': 'ABC-DEF',
          'interval': '1',
        }),
      );
      client.handlers.add(
        (_) async =>
            _json(200, {'authorization_code': 'ac-1', 'code_verifier': 'cv-1'}),
      );
      client.handlers.add((_) async => _json(200, _tokenBody('acc-1')));
      gated.parkWrite();

      final flow = controller.startFlow(
        cfg: codexProviderConfig(),
        onAuthenticated: () async {
          onAuthenticatedCalls++;
        },
      );
      // The exchange has completed and the credential write is parked on
      // the gate: this is "cancel during persist".
      await gated.writeStarted.timeout(const Duration(seconds: 5));
      controller.cancel();
      gated.releaseWrite();
      final outcome = await flow.timeout(const Duration(seconds: 5));

      expect(outcome, CodexFlowOutcome.cancelled);
      expect(controller.status, CodexAuthStatus.signedOut);
      expect(controller.credential, isNull);
      expect(onAuthenticatedCalls, 0);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kCodexPrefsKey), isNull);

      // Reentrancy: a fresh flow must start after the cancelled one, not be
      // blocked by a lingering polling status or a stale _cancelled flag.
      client.handlers.add(
        (_) async => _json(200, {
          'device_auth_id': 'da-2',
          'user_code': 'DEF-GHI',
          'interval': '1',
        }),
      );
      client.handlers.add(
        (_) async =>
            _json(200, {'authorization_code': 'ac-2', 'code_verifier': 'cv-2'}),
      );
      client.handlers.add((_) async => _json(200, _tokenBody('acc-2')));

      final second = await controller.startFlow(
        cfg: codexProviderConfig(),
        onAuthenticated: () async {},
      );

      expect(second, CodexFlowOutcome.success);
      expect(controller.status, CodexAuthStatus.signedIn);
      expect(controller.credential!.accountId, 'acc-2');
    });

    test('cancel after credential persist still returns success', () async {
      client.handlers.add(
        (_) async => _json(200, {
          'device_auth_id': 'da-1',
          'user_code': 'ABC-DEF',
          'interval': '1',
        }),
      );
      client.handlers.add(
        (_) async =>
            _json(200, {'authorization_code': 'ac-1', 'code_verifier': 'cv-1'}),
      );
      client.handlers.add((_) async => _json(200, _tokenBody('acc-1')));

      final outcome = await controller.startFlow(
        cfg: codexProviderConfig(),
        onAuthenticated: () async {
          onAuthenticatedCalls++;
          // Cancel lands after the credential is persisted and status is
          // already signedIn: the flow must still report success so the UI
          // does not show a cancelled login for a session that exists.
          controller.cancel();
        },
      );

      expect(outcome, CodexFlowOutcome.success);
      expect(controller.status, CodexAuthStatus.signedIn);
      expect(controller.credential, isNotNull);
      expect(onAuthenticatedCalls, 1);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kCodexPrefsKey), isNotNull);
    });

    test('startFlow is not reentrant while polling', () async {
      client.handlers.add(
        (_) async => _json(200, {
          'device_auth_id': 'da-1',
          'user_code': 'ABC-DEF',
          'interval': '5',
        }),
      );
      client.handlers.add((_) async => http.Response('{}', 403));

      final flow = controller.startFlow(
        cfg: codexProviderConfig(),
        onAuthenticated: () async {},
      );
      await _waitForRequests(client, 2);
      final second = await controller.startFlow(
        cfg: codexProviderConfig(),
        onAuthenticated: () async {},
      );
      expect(second, CodexFlowOutcome.failed);
      controller.cancel();
      expect(
        await flow.timeout(const Duration(seconds: 5)),
        CodexFlowOutcome.cancelled,
      );
    });
  });

  group('ensureFresh', () {
    test('does nothing when credential is fresh', () async {
      controller.credential = _freshCred('acc-1');
      controller.status = CodexAuthStatus.signedIn;

      await controller.ensureFresh();

      expect(client.requests, isEmpty);
    });

    test('refreshes expired credential without redirect_uri', () async {
      controller.credential = _expiredCred('acc-1');
      controller.status = CodexAuthStatus.expired;
      client.handlers.add((_) async => _json(200, _tokenBody('acc-2')));

      await controller.ensureFresh();

      expect(client.requests.length, 1);
      final req = client.requests.single;
      expect(req.url.toString(), kCodexTokenEndpoint);
      expect(req.body, contains('grant_type=refresh_token'));
      expect(req.body, contains('refresh_token=rt-old'));
      expect(req.body, contains('client_id=$kCodexClientId'));
      expect(req.body, isNot(contains('redirect_uri')));
      expect(controller.credential!.accountId, 'acc-2');
      expect(controller.status, CodexAuthStatus.signedIn);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kCodexPrefsKey), isNotNull);
    });

    test('refresh without refresh_token keeps the previous one', () async {
      controller.credential = _expiredCred('acc-1');
      controller.status = CodexAuthStatus.expired;
      client.handlers.add(
        (_) async => _json(200, {
          'access_token': _jwtWithAccount('acc-2'),
          'expires_in': 3600,
        }),
      );

      await controller.ensureFresh();

      expect(client.requests.length, 1);
      expect(controller.credential!.accessToken, _jwtWithAccount('acc-2'));
      expect(controller.credential!.refreshToken, 'rt-old');
      expect(controller.credential!.accountId, 'acc-2');
      expect(controller.status, CodexAuthStatus.signedIn);
    });

    test('clears credential on invalid_grant', () async {
      controller.credential = _expiredCred('acc-1');
      controller.status = CodexAuthStatus.expired;
      client.handlers.add((_) async => _json(400, {'error': 'invalid_grant'}));

      await controller.ensureFresh();

      expect(controller.credential, isNull);
      expect(controller.status, CodexAuthStatus.expired);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kCodexPrefsKey), isNull);
    });

    test('keeps credential and status on server error', () async {
      controller.credential = _expiredCred('acc-1');
      controller.status = CodexAuthStatus.signedIn;
      client.handlers.add((_) async => http.Response('oops', 500));

      await controller.ensureFresh();

      expect(controller.credential, isNotNull);
      expect(controller.status, CodexAuthStatus.signedIn);
    });

    test(
      'keeps credential and status when refresh response is malformed',
      () async {
        controller.credential = _expiredCred('acc-1');
        controller.status = CodexAuthStatus.signedIn;
        client.handlers.add((_) async => _json(200, {'access_token': 'x'}));

        await controller.ensureFresh();

        expect(controller.credential, isNotNull);
        expect(controller.status, CodexAuthStatus.signedIn);
      },
    );

    test(
      'refresh 200 with non-JSON body keeps credential and status',
      () async {
        controller.credential = _expiredCred('acc-1');
        controller.status = CodexAuthStatus.expired;
        client.handlers.add((_) async => http.Response('OK', 200));

        await controller.ensureFresh();

        // A 200 that cannot be decoded is a missing-fields response: the
        // credential and status survive untouched instead of crashing.
        expect(controller.credential, isNotNull);
        expect(controller.credential!.accountId, 'acc-1');
        expect(controller.status, CodexAuthStatus.expired);
      },
    );

    test('is single-flight under concurrency', () async {
      controller.credential = _expiredCred('acc-1');
      client.handlers.add((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 150));
        return _json(200, _tokenBody('acc-2'));
      });

      await Future.wait([
        controller.ensureFresh(),
        controller.ensureFresh(),
        controller.ensureFresh(),
      ]);

      expect(client.requests.length, 1);
    });

    test('keeps credential and status on SocketException', () async {
      controller.credential = _expiredCred('acc-1');
      controller.status = CodexAuthStatus.signedIn;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        kCodexPrefsKey,
        jsonEncode(controller.credential!.toJson()),
      );
      client.handlers.add((_) async => throw const SocketException('refused'));

      await controller.ensureFresh();

      expect(controller.credential, isNotNull);
      expect(controller.status, CodexAuthStatus.signedIn);
      expect(prefs.getString(kCodexPrefsKey), isNotNull);
    });

    test('keeps credential and status on TimeoutException', () async {
      controller.credential = _expiredCred('acc-1');
      controller.status = CodexAuthStatus.signedIn;
      client.handlers.add((_) async => throw TimeoutException('slow response'));

      await controller.ensureFresh();

      expect(controller.credential, isNotNull);
      expect(controller.status, CodexAuthStatus.signedIn);
    });
  });

  group('ensureFreshOrThrow', () {
    test('returns immediately for non-codex hosts', () async {
      await CodexDeviceCodeController.ensureFreshOrThrow(
        _cfg(id: 'OpenAI', baseUrl: 'https://api.openai.com/v1'),
      );

      expect(client.requests, isEmpty);
    });

    test('throws HttpException when no credential exists', () async {
      controller.status = CodexAuthStatus.signedOut;

      await expectLater(
        CodexDeviceCodeController.ensureFreshOrThrow(codexProviderConfig()),
        throwsA(isA<HttpException>()),
      );
      expect(client.requests, isEmpty);
    });

    test('throws HttpException when refresh is rejected', () async {
      controller.credential = _expiredCred('acc-1');
      controller.status = CodexAuthStatus.expired;
      client.handlers.add((_) async => _json(400, {'error': 'invalid_grant'}));

      await expectLater(
        CodexDeviceCodeController.ensureFreshOrThrow(codexProviderConfig()),
        throwsA(isA<HttpException>()),
      );
      expect(controller.credential, isNull);
    });

    test('passes when refresh succeeds', () async {
      controller.credential = _expiredCred('acc-1');
      controller.status = CodexAuthStatus.expired;
      client.handlers.add((_) async => _json(200, _tokenBody('acc-2')));

      await CodexDeviceCodeController.ensureFreshOrThrow(codexProviderConfig());

      expect(controller.isFresh, isTrue);
      expect(controller.credential!.accountId, 'acc-2');
    });

    test('grace-period token passes without refresh traffic', () async {
      controller.credential = _graceCred('acc-1');
      controller.status = CodexAuthStatus.signedIn;
      client.handlers.add((_) async => _json(500, {'error': 'boom'}));

      await CodexDeviceCodeController.ensureFreshOrThrow(codexProviderConfig());

      // Not fresh (grace window passed) but still usable: the guard must not
      // throw and must not even attempt a refresh.
      expect(controller.isFresh, isFalse);
      expect(controller.isUsable, isTrue);
      expect(client.requests, isEmpty);
    });
  });

  group('credential proxy persistence', () {
    test('init() restores the proxy from prefs', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        kCodexPrefsKey,
        jsonEncode({
          'accessToken': _jwtWithAccount('acc-1'),
          'refreshToken': 'rt-old',
          'expiresAt': DateTime.now()
              .subtract(const Duration(seconds: 1))
              .millisecondsSinceEpoch,
          'accountId': 'acc-1',
          'proxy': {
            'type': 'socks5',
            'host': '127.0.0.1',
            'port': 1080,
            'username': 'user',
            'password': 'pass',
          },
        }),
      );

      await controller.init();

      expect(controller.credential, isNotNull);
      expect(controller.credential!.proxy, isNotNull);
      expect(controller.credential!.proxy!.type, 'socks5');
      expect(controller.credential!.proxy!.host, '127.0.0.1');
      expect(controller.credential!.proxy!.port, 1080);
      expect(controller.credential!.proxy!.username, 'user');
      expect(controller.credential!.proxy!.password, 'pass');
      expect(controller.status, CodexAuthStatus.expired);
    });

    test('init() tolerates a missing or malformed proxy block', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        kCodexPrefsKey,
        jsonEncode({
          'accessToken': _jwtWithAccount('acc-1'),
          'refreshToken': 'rt-old',
          'expiresAt': DateTime.now()
              .subtract(const Duration(seconds: 1))
              .millisecondsSinceEpoch,
          'accountId': 'acc-1',
          'proxy': {'host': '', 'port': 'not-a-number'},
        }),
      );

      await controller.init();

      expect(controller.credential, isNotNull);
      expect(controller.credential!.proxy, isNull);
    });

    test('init() clears a persisted credential with empty fields', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        kCodexPrefsKey,
        jsonEncode({
          'accessToken': '',
          'refreshToken': 'rt-1',
          'expiresAt': DateTime.now()
              .add(const Duration(hours: 1))
              .millisecondsSinceEpoch,
          'accountId': 'acc-1',
        }),
      );

      await controller.init();

      expect(controller.credential, isNull);
      expect(controller.status, CodexAuthStatus.signedOut);
      expect(prefs.getString(kCodexPrefsKey), isNull);
    });

    test('init() clears a persisted credential missing accountId', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        kCodexPrefsKey,
        jsonEncode({
          'accessToken': _jwtWithAccount('acc-1'),
          'refreshToken': 'rt-1',
          'expiresAt': DateTime.now()
              .add(const Duration(hours: 1))
              .millisecondsSinceEpoch,
          'accountId': '',
        }),
      );

      await controller.init();

      expect(controller.credential, isNull);
      expect(controller.status, CodexAuthStatus.signedOut);
      expect(prefs.getString(kCodexPrefsKey), isNull);
    });

    test('init() tolerates non-JSON prefs and stays signedOut', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(kCodexPrefsKey, 'not-json{');

      await controller.init();

      expect(controller.credential, isNull);
      expect(controller.status, CodexAuthStatus.signedOut);
      // Self-healing: the corrupt entry is dropped so every launch does not
      // repeat the failed parse.
      expect(prefs.getString(kCodexPrefsKey), isNull);
    });

    test('init() clears persisted JSON that is not an object', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(kCodexPrefsKey, '[1,2,3]');

      await controller.init();

      expect(controller.credential, isNull);
      expect(controller.status, CodexAuthStatus.signedOut);
      expect(prefs.getString(kCodexPrefsKey), isNull);
    });

    test('_doRefresh uses the persisted proxy after init()', () async {
      NetworkProxyConfig? factoryProxy;
      final proxiedClient = _ScriptedClient();
      final restored = CodexDeviceCodeController(
        clientFactory: (proxy) {
          factoryProxy = proxy;
          return proxiedClient;
        },
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        kCodexPrefsKey,
        jsonEncode({
          'accessToken': _jwtWithAccount('acc-1'),
          'refreshToken': 'rt-old',
          'expiresAt': DateTime.now()
              .subtract(const Duration(seconds: 1))
              .millisecondsSinceEpoch,
          'accountId': 'acc-1',
          'proxy': {'type': 'http', 'host': 'proxy.example.com', 'port': 3128},
        }),
      );
      await restored.init();
      proxiedClient.handlers.add((_) async => _json(200, _tokenBody('acc-2')));

      await restored.ensureFresh();

      expect(factoryProxy, isNotNull);
      expect(factoryProxy!.host, 'proxy.example.com');
      expect(factoryProxy!.port, 3128);
      expect(restored.credential!.accountId, 'acc-2');
    });
  });

  group('sign-in proxy lifecycle', () {
    test(
      'a failed flow no longer routes refreshes through the sign-in proxy',
      () async {
        NetworkProxyConfig? factoryProxy;
        final proxiedClient = _ScriptedClient();
        final proxied = CodexDeviceCodeController(
          clientFactory: (proxy) {
            factoryProxy = proxy;
            return proxiedClient;
          },
        );
        CodexDeviceCodeController.debugOverrideInstance(proxied);
        proxiedClient.handlers.add(
          (_) async => _json(200, {
            'device_auth_id': 'da-1',
            'user_code': 'ABC-DEF',
            'interval': '1',
          }),
        );
        proxiedClient.handlers.add(
          (_) async => _json(403, {
            'error': {'code': 'access_denied'},
          }),
        );

        final outcome = await proxied.startFlow(
          cfg: _cfg(
            id: 'Codex',
            baseUrl: kCodexBaseUrl,
            proxyEnabled: true,
            proxyHost: '127.0.0.1',
            proxyPort: '1080',
          ),
          onAuthenticated: () async {},
        );

        expect(outcome, CodexFlowOutcome.failed);
        expect(proxied.status, CodexAuthStatus.failed);

        // A later refresh of a proxy-less credential must not reuse the
        // failed flow's proxy: _fail() clears _signInProxy.
        proxied.credential = _expiredCred('acc-1');
        proxied.status = CodexAuthStatus.expired;
        factoryProxy = null;
        proxiedClient.handlers.add(
          (_) async => _json(200, _tokenBody('acc-2')),
        );

        await proxied.ensureFresh();

        expect(factoryProxy, isNull);
        expect(proxied.credential!.accountId, 'acc-2');
      },
    );

    test(
      'a cancelled flow no longer routes refreshes through the sign-in proxy',
      () async {
        NetworkProxyConfig? factoryProxy;
        final proxiedClient = _ScriptedClient();
        final proxied = CodexDeviceCodeController(
          clientFactory: (proxy) {
            factoryProxy = proxy;
            return proxiedClient;
          },
        );
        CodexDeviceCodeController.debugOverrideInstance(proxied);
        proxiedClient.handlers.add(
          (_) async => _json(200, {
            'device_auth_id': 'da-1',
            'user_code': 'ABC-DEF',
            'interval': '5',
          }),
        );
        proxiedClient.handlers.add((_) async => http.Response('{}', 403));

        final flow = proxied.startFlow(
          cfg: _cfg(
            id: 'Codex',
            baseUrl: kCodexBaseUrl,
            proxyEnabled: true,
            proxyHost: '127.0.0.1',
            proxyPort: '1080',
          ),
          onAuthenticated: () async {},
        );
        await _waitForRequests(proxiedClient, 2);
        proxied.cancel();
        final outcome = await flow.timeout(const Duration(seconds: 5));

        expect(outcome, CodexFlowOutcome.cancelled);
        expect(proxied.status, CodexAuthStatus.signedOut);

        proxied.credential = _expiredCred('acc-1');
        proxied.status = CodexAuthStatus.expired;
        factoryProxy = null;
        proxiedClient.handlers.add(
          (_) async => _json(200, _tokenBody('acc-2')),
        );

        await proxied.ensureFresh();

        expect(factoryProxy, isNull);
        expect(proxied.credential!.accountId, 'acc-2');
      },
    );

    test(
      'a timed-out flow no longer routes refreshes through the sign-in proxy',
      () async {
        NetworkProxyConfig? factoryProxy;
        final proxiedClient = _ScriptedClient();
        final proxied = CodexDeviceCodeController(
          clientFactory: (proxy) {
            factoryProxy = proxy;
            return proxiedClient;
          },
          pollDeadline: const Duration(milliseconds: 300),
        );
        CodexDeviceCodeController.debugOverrideInstance(proxied);
        proxiedClient.handlers.add(
          (_) async => _json(200, {
            'device_auth_id': 'da-1',
            'user_code': 'ABC-DEF',
            'interval': '1',
          }),
        );
        proxiedClient.handlers.add((_) async => http.Response('{}', 403));

        final outcome = await proxied.startFlow(
          cfg: _cfg(
            id: 'Codex',
            baseUrl: kCodexBaseUrl,
            proxyEnabled: true,
            proxyHost: '127.0.0.1',
            proxyPort: '1080',
          ),
          onAuthenticated: () async {},
        );

        expect(outcome, CodexFlowOutcome.timedOut);
        expect(proxied.status, CodexAuthStatus.signedOut);

        // Same lifecycle rule as the failed / cancelled variants: a timeout
        // also clears _signInProxy, so a later refresh of a proxy-less
        // credential must not reuse the dead flow's proxy.
        proxied.credential = _expiredCred('acc-1');
        proxied.status = CodexAuthStatus.expired;
        factoryProxy = null;
        proxiedClient.handlers.add(
          (_) async => _json(200, _tokenBody('acc-2')),
        );

        await proxied.ensureFresh();

        expect(factoryProxy, isNull);
        expect(proxied.credential!.accountId, 'acc-2');
      },
    );
  });

  group('maybeCodexHeaders', () {
    test('empty for non-codex hosts', () {
      controller.credential = _freshCred('acc-1');

      final h = controller.maybeCodexHeaders(
        _cfg(id: 'OpenAI', useResponseApi: true),
      );

      expect(h, isEmpty);
    });

    test('empty when id is Codex but baseUrl is not a chatgpt.com host', () {
      controller.credential = _freshCred('acc-1');

      final h = controller.maybeCodexHeaders(
        _cfg(id: 'Codex', baseUrl: 'https://proxy.example.com/v1'),
      );

      expect(h, isEmpty);
      expect(CodexDeviceCodeController.isCodexHost(_cfg(id: 'Codex')), isFalse);
    });

    test('empty without credential', () {
      final h = controller.maybeCodexHeaders(codexProviderConfig());

      expect(h, isEmpty);
    });

    test('fresh credential with responses api yields three headers', () {
      controller.credential = _freshCred('acc-1');

      final h = controller.maybeCodexHeaders(codexProviderConfig());

      expect(h, {
        'Authorization': 'Bearer ${_jwtWithAccount('acc-1')}',
        'chatgpt-account-id': 'acc-1',
        'OpenAI-Beta': 'responses=experimental',
      });
    });

    test('fresh credential without responses api omits OpenAI-Beta', () {
      controller.credential = _freshCred('acc-1');

      final h = controller.maybeCodexHeaders(
        _cfg(id: 'Codex', baseUrl: kCodexBaseUrl, useResponseApi: false),
      );

      expect(h, {
        'Authorization': 'Bearer ${_jwtWithAccount('acc-1')}',
        'chatgpt-account-id': 'acc-1',
      });
    });

    test('grace-period token still injects headers', () {
      controller.credential = _graceCred('acc-1');

      final h = controller.maybeCodexHeaders(codexProviderConfig());

      // isFresh is false but the token has not absolutely expired: headers
      // are injected instead of triggering a background refresh.
      expect(controller.isFresh, isFalse);
      expect(h['Authorization'], 'Bearer ${_jwtWithAccount('acc-1')}');
      expect(h['chatgpt-account-id'], 'acc-1');
      expect(client.requests, isEmpty);
    });

    test(
      'stale credential yields empty headers and background refresh',
      () async {
        controller.credential = _expiredCred('acc-1');
        client.handlers.add((_) async => _json(200, _tokenBody('acc-2')));

        final h = controller.maybeCodexHeaders(codexProviderConfig());

        expect(h, isEmpty);
        // Poll until the background refresh completes and signs back in.
        final deadline = DateTime.now().add(const Duration(seconds: 3));
        while (controller.status != CodexAuthStatus.signedIn &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(controller.status, CodexAuthStatus.signedIn);
        expect(controller.credential, isNotNull);
        expect(controller.credential!.accountId, 'acc-2');
      },
    );
  });

  group('routing helpers', () {
    test('isCodexHost branches', () {
      expect(CodexDeviceCodeController.isCodexHost(_cfg(id: 'Codex')), isFalse);
      expect(
        CodexDeviceCodeController.isCodexHost(
          _cfg(id: 'Codex', baseUrl: kCodexBaseUrl),
        ),
        isTrue,
      );
      expect(
        CodexDeviceCodeController.isCodexHost(
          _cfg(id: 'X', baseUrl: 'https://chatgpt.com/backend-api/codex'),
        ),
        isTrue,
      );
      expect(
        CodexDeviceCodeController.isCodexHost(
          _cfg(id: 'X', baseUrl: 'https://chatgpt.com/backend-api/codex/'),
        ),
        isTrue,
      );
      expect(
        CodexDeviceCodeController.isCodexHost(
          _cfg(id: 'X', baseUrl: 'https://chatgpt.com/somewhere'),
        ),
        isFalse,
      );
      expect(
        CodexDeviceCodeController.isCodexHost(
          _cfg(id: 'X', baseUrl: 'https://chatgpt.com/backend-api/notcodex'),
        ),
        isFalse,
      );
      expect(
        CodexDeviceCodeController.isCodexHost(
          _cfg(id: 'X', baseUrl: 'https://chatgpt.com/precodex-gateway'),
        ),
        isFalse,
      );
      expect(
        CodexDeviceCodeController.isCodexHost(
          _cfg(
            id: 'X',
            baseUrl: 'https://chatgpt.com/backend-api/codex-proxy/foo',
          ),
        ),
        isFalse,
      );
      expect(
        CodexDeviceCodeController.isCodexHost(
          _cfg(id: 'X', baseUrl: 'https://www.chatgpt.com/backend-api/codex'),
        ),
        isTrue,
      );
      expect(
        CodexDeviceCodeController.isCodexHost(
          _cfg(id: 'X', baseUrl: 'https://notchatgpt.com/backend-api/codex'),
        ),
        isFalse,
      );
      expect(
        CodexDeviceCodeController.isCodexHost(
          _cfg(
            id: 'X',
            baseUrl: 'https://chatgpt.com.evil.com/backend-api/codex',
          ),
        ),
        isFalse,
      );
      expect(
        CodexDeviceCodeController.isCodexHost(
          _cfg(id: 'X', baseUrl: 'https://evil-chatgpt.com/backend-api/codex'),
        ),
        isFalse,
      );
      expect(
        CodexDeviceCodeController.isCodexHost(
          _cfg(id: 'OpenAI', baseUrl: 'https://api.openai.com/v1'),
        ),
        isFalse,
      );
      expect(
        CodexDeviceCodeController.isCodexHost(_cfg(id: 'X', baseUrl: '')),
        isFalse,
      );
    });

    test('showEntryFor branches', () {
      expect(
        CodexDeviceCodeController.showEntryFor(_cfg(id: 'OpenAI')),
        isTrue,
      );
      expect(CodexDeviceCodeController.showEntryFor(_cfg(id: 'Codex')), isTrue);
      expect(
        CodexDeviceCodeController.showEntryFor(
          _cfg(id: 'X', baseUrl: 'https://chatgpt.com/backend-api/codex'),
        ),
        isTrue,
      );
      expect(
        CodexDeviceCodeController.showEntryFor(
          _cfg(id: 'X', kind: ProviderKind.claude),
        ),
        isFalse,
      );
      expect(
        CodexDeviceCodeController.showEntryFor(
          _cfg(id: 'X', kind: ProviderKind.google),
        ),
        isFalse,
      );
      expect(
        CodexDeviceCodeController.showEntryFor(
          _cfg(id: 'OpenAI', multiKey: true),
        ),
        // multiKey gating moved to the call sites, which hold the live page
        // state; showEntryFor only decides kind/id/host.
        isTrue,
      );
      expect(CodexDeviceCodeController.showEntryFor(_cfg(id: 'X')), isFalse);
    });

    test('proxyFromConfig rejects unparseable or out-of-range ports', () {
      NetworkProxyConfig? proxyOf(String port) =>
          CodexDeviceCodeController.proxyFromConfig(
            _cfg(
              id: 'X',
              baseUrl: kCodexBaseUrl,
              proxyEnabled: true,
              proxyHost: '127.0.0.1',
              proxyPort: port,
            ),
          );

      // A non-numeric port must be "no proxy", not a silent 8080 default.
      expect(proxyOf('not-a-number'), isNull);
      expect(proxyOf(''), isNull);
      expect(proxyOf('0'), isNull);
      expect(proxyOf('-1'), isNull);
      expect(proxyOf('65536'), isNull);
      // Boundary values stay valid.
      expect(proxyOf('1'), isNotNull);
      expect(proxyOf('65535'), isNotNull);
      expect(proxyOf('1080'), isNotNull);
    });
  });

  group('codexProviderConfig', () {
    test('declares the codex provider surface', () {
      final cfg = codexProviderConfig();

      expect(cfg.id, kCodexProviderKey);
      expect(cfg.name, kCodexProviderKey);
      expect(cfg.enabled, isTrue);
      expect(cfg.apiKey, isEmpty);
      expect(cfg.baseUrl, kCodexBaseUrl);
      expect(cfg.providerType, ProviderKind.openai);
      expect(cfg.useResponseApi, isTrue);
      expect(cfg.models.length, kCodexModels.length);
      for (final m in kCodexModels) {
        expect(cfg.models, contains(m));
      }
      expect(cfg.modelOverrides.length, kCodexModels.length);
      for (final ov in cfg.modelOverrides.values) {
        expect(ov['type'], 'chat');
        expect(ov['input'], ['text']);
        expect(ov['output'], ['text']);
        expect(ov['abilities'], ['tool', 'reasoning']);
      }
      expect(cfg.balanceEnabled, isFalse);
      expect(cfg.multiKeyEnabled, isFalse);
      expect(cfg.proxyEnabled, isFalse);
      expect(cfg.claudePromptCachingEnabled, isFalse);
    });
  });

  group('JWT account id extraction', () {
    test('exchange fails on 2-segment access token', () async {
      client.handlers.add(
        (_) async => _json(200, {
          'device_auth_id': 'da-1',
          'user_code': 'ABC-DEF',
          'interval': '1',
        }),
      );
      client.handlers.add(
        (_) async =>
            _json(200, {'authorization_code': 'ac-1', 'code_verifier': 'cv-1'}),
      );
      client.handlers.add(
        (_) async => _json(200, {
          'access_token': 'aaa.bbb',
          'refresh_token': 'rt-1',
          'expires_in': 3600,
        }),
      );

      final outcome = await controller.startFlow(
        cfg: codexProviderConfig(),
        onAuthenticated: () async {},
      );

      expect(outcome, CodexFlowOutcome.failed);
      expect(controller.status, CodexAuthStatus.failed);
      expect(controller.credential, isNull);
    });

    test('exchange fails when jwt lacks auth claim', () async {
      client.handlers.add(
        (_) async => _json(200, {
          'device_auth_id': 'da-1',
          'user_code': 'ABC-DEF',
          'interval': '1',
        }),
      );
      client.handlers.add(
        (_) async =>
            _json(200, {'authorization_code': 'ac-1', 'code_verifier': 'cv-1'}),
      );
      client.handlers.add(
        (_) async => _json(200, {
          'access_token': _jwt(jsonEncode({'iss': 'https://auth.openai.com'})),
          'refresh_token': 'rt-1',
          'expires_in': 3600,
        }),
      );

      final outcome = await controller.startFlow(
        cfg: codexProviderConfig(),
        onAuthenticated: () async {},
      );

      expect(outcome, CodexFlowOutcome.failed);
      expect(controller.status, CodexAuthStatus.failed);
    });

    test('exchange fails on empty account id', () async {
      client.handlers.add(
        (_) async => _json(200, {
          'device_auth_id': 'da-1',
          'user_code': 'ABC-DEF',
          'interval': '1',
        }),
      );
      client.handlers.add(
        (_) async =>
            _json(200, {'authorization_code': 'ac-1', 'code_verifier': 'cv-1'}),
      );
      client.handlers.add((_) async => _json(200, _tokenBody('')));

      final outcome = await controller.startFlow(
        cfg: codexProviderConfig(),
        onAuthenticated: () async {},
      );

      expect(outcome, CodexFlowOutcome.failed);
      expect(controller.status, CodexAuthStatus.failed);
    });
  });

  group('signOut', () {
    test('clears credential and stored prefs', () async {
      controller.credential = _freshCred('acc-1');
      controller.status = CodexAuthStatus.signedIn;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        kCodexPrefsKey,
        jsonEncode(controller.credential!.toJson()),
      );

      await controller.signOut();

      expect(controller.credential, isNull);
      expect(controller.status, CodexAuthStatus.signedOut);
      expect(prefs.getString(kCodexPrefsKey), isNull);
    });

    test(
      'signOut during an in-flight refresh leaves the credential cleared',
      () async {
        final refreshGate = Completer<http.Response>();
        controller.credential = _expiredCred('acc-1');
        controller.status = CodexAuthStatus.expired;
        client.handlers.add((_) => refreshGate.future);

        final refreshing = controller.ensureFresh();
        await _waitForRequests(client, 1);
        final signOutFuture = controller.signOut();
        // signOut awaits the in-flight refresh; release its response only
        // after signOut has started, so the ordering is deterministic.
        refreshGate.complete(_json(200, _tokenBody('acc-2')));
        await signOutFuture.timeout(const Duration(seconds: 5));
        await refreshing.timeout(const Duration(seconds: 5));

        expect(controller.credential, isNull);
        expect(controller.status, CodexAuthStatus.signedOut);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString(kCodexPrefsKey), isNull);
      },
    );

    test('a refresh starting during signOut prefs removal cannot resurrect '
        'the session', () async {
      // Park signOut's prefs removal: the async gap in which a fresh
      // ensureFresh() (e.g. maybeCodexHeaders' unawaited kick-off) can
      // start a _doRefresh from a still-non-null credential.
      SharedPreferences.setMockInitialValues({});
      final gated = _GatedPrefsStore();
      SharedPreferencesStorePlatform.instance = gated;
      final prefs = await SharedPreferences.getInstance();
      controller.credential = _expiredCred('acc-1');
      controller.status = CodexAuthStatus.expired;
      await prefs.setString(
        kCodexPrefsKey,
        jsonEncode(controller.credential!.toJson()),
      );

      final refreshGate = Completer<http.Response>();
      client.handlers.add((_) => refreshGate.future);

      gated.parkRemove();
      final signOutFuture = controller.signOut();
      await gated.removeStarted.timeout(const Duration(seconds: 5));
      // signOut is parked inside the removal; _refreshing is still null and
      // the credential not yet cleared, so the refresh starts.
      final refreshing = controller.ensureFresh();
      await _waitForRequests(client, 1);
      gated.releaseRemove();
      await signOutFuture.timeout(const Duration(seconds: 5));
      // The refresh response lands only after sign-out committed: its
      // commit must be aborted instead of re-persisting / flipping back to
      // signedIn.
      refreshGate.complete(_json(200, _tokenBody('acc-2')));
      await refreshing.timeout(const Duration(seconds: 5));

      expect(controller.credential, isNull);
      expect(controller.status, CodexAuthStatus.signedOut);
      final storedPrefs = await SharedPreferences.getInstance();
      expect(storedPrefs.getString(kCodexPrefsKey), isNull);
    });

    test('a refresh born while signOut is parked cannot resurrect the session '
        'when a poll flow is active', () async {
      // The poll flow is what distinguishes this from the refresh-only
      // variant: while signOut is parked on its prefs removal, the flow's
      // _flowEnded() resets _cancelled, so the refresh's commit guard cannot
      // rely on the cancel flag alone - the sign-out epoch must still reject
      // the commit once the response arrives.
      SharedPreferences.setMockInitialValues({});
      final gated = _GatedPrefsStore();
      SharedPreferencesStorePlatform.instance = gated;
      final prefs = await SharedPreferences.getInstance();
      controller.credential = _expiredCred('acc-1');
      controller.status = CodexAuthStatus.expired;
      await prefs.setString(
        kCodexPrefsKey,
        jsonEncode(controller.credential!.toJson()),
      );

      final pollGate = Completer<http.Response>();
      client.handlers.add(
        (_) async => _json(200, {
          'device_auth_id': 'da-1',
          'user_code': 'ABC-DEF',
          'interval': '5',
        }),
      );
      client.handlers.add((_) => pollGate.future);

      gated.parkRemove();
      final flow = controller.startFlow(
        cfg: codexProviderConfig(),
        onAuthenticated: () async {},
      );
      // The flow is polling with its poll request hanging on pollGate.
      await _waitForRequests(client, 2);
      final signOutFuture = controller.signOut();
      await gated.removeStarted.timeout(const Duration(seconds: 5));
      // signOut is parked inside the removal while the flow is still alive.
      // Releasing the poll makes the flow exit through _flowEnded(), which
      // resets _cancelled - the window a stale refresh must not commit into.
      pollGate.complete(http.Response('{}', 403));
      expect(
        await flow.timeout(const Duration(seconds: 5)),
        CodexFlowOutcome.cancelled,
      );
      expect(controller.status, CodexAuthStatus.signedOut);

      // The flow has ended and _cancelled is reset, but signOut is still
      // parked: a refresh born now captures the post-signOut epoch.
      final refreshGate = Completer<http.Response>();
      client.handlers.add((_) => refreshGate.future);
      final refreshing = controller.ensureFresh();
      await _waitForRequests(client, 3);
      gated.releaseRemove();
      await signOutFuture.timeout(const Duration(seconds: 5));
      // The response lands only after sign-out committed: the commit must be
      // aborted instead of re-persisting / flipping back to signedIn.
      refreshGate.complete(_json(200, _tokenBody('acc-2')));
      await refreshing.timeout(const Duration(seconds: 5));

      expect(controller.credential, isNull);
      expect(controller.status, CodexAuthStatus.signedOut);
      final storedPrefs = await SharedPreferences.getInstance();
      expect(storedPrefs.getString(kCodexPrefsKey), isNull);
    });

    test('signOut aborts an in-flight device-code flow', () async {
      client.handlers.add(
        (_) async => _json(200, {
          'device_auth_id': 'da-1',
          'user_code': 'ABC-DEF',
          'interval': '5',
        }),
      );
      client.handlers.add((_) async => http.Response('{}', 403));

      final flow = controller.startFlow(
        cfg: codexProviderConfig(),
        onAuthenticated: () async {
          onAuthenticatedCalls++;
        },
      );
      await _waitForRequests(client, 2);
      await controller.signOut();
      final outcome = await flow;

      expect(outcome, CodexFlowOutcome.cancelled);
      expect(controller.status, CodexAuthStatus.signedOut);
      expect(controller.credential, isNull);
      expect(onAuthenticatedCalls, 0);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kCodexPrefsKey), isNull);
    });

    test(
      'signOut during the exchange then success response leaves prefs clean',
      () async {
        final exchangeGate = Completer<http.Response>();
        client.handlers.add(
          (_) async => _json(200, {
            'device_auth_id': 'da-1',
            'user_code': 'ABC-DEF',
            'interval': '1',
          }),
        );
        client.handlers.add(
          (_) async => _json(200, {
            'authorization_code': 'ac-1',
            'code_verifier': 'cv-1',
          }),
        );
        client.handlers.add((_) => exchangeGate.future);

        final flow = controller.startFlow(
          cfg: codexProviderConfig(),
          onAuthenticated: () async {
            onAuthenticatedCalls++;
          },
        );
        // Sign out while the exchange request is in flight; the exchange
        // then succeeds, which is the last moment the flow could persist.
        await _waitForRequests(client, 3);
        await controller.signOut();
        exchangeGate.complete(_json(200, _tokenBody('acc-1')));
        final outcome = await flow.timeout(const Duration(seconds: 5));

        expect(outcome, CodexFlowOutcome.cancelled);
        expect(controller.status, CodexAuthStatus.signedOut);
        expect(controller.credential, isNull);
        expect(onAuthenticatedCalls, 0);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString(kCodexPrefsKey), isNull);
      },
    );

    test(
      'signOut while the usercode request is in flight never flips to polling',
      () async {
        final usercodeGate = Completer<http.Response>();
        client.handlers.add((_) => usercodeGate.future);

        final statuses = <CodexAuthStatus>[];
        controller.addListener(() => statuses.add(controller.status));
        final flow = controller.startFlow(
          cfg: codexProviderConfig(),
          onAuthenticated: () async {
            onAuthenticatedCalls++;
          },
        );
        await _waitForRequests(client, 1);
        await controller.signOut();
        usercodeGate.complete(
          _json(200, {
            'device_auth_id': 'da-1',
            'user_code': 'ABC-DEF',
            'interval': '1',
          }),
        );
        final outcome = await flow.timeout(const Duration(seconds: 5));

        expect(outcome, CodexFlowOutcome.cancelled);
        expect(controller.status, CodexAuthStatus.signedOut);
        // The cancelled flow must not publish the code or flip into polling:
        // a late usercode response must not resurrect the flow state.
        expect(controller.usercode, isNull);
        expect(controller.verificationUri, isNull);
        expect(controller.errorMessage, isNull);
        expect(onAuthenticatedCalls, 0);
        expect(statuses, isNot(contains(CodexAuthStatus.polling)));
      },
    );
  });
}
