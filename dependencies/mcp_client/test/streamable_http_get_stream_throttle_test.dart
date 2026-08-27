@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mcp_client/mcp_client.dart';
import 'package:test/test.dart';

/// Regression for Kelivo #937 ("MCP反复连接" — the client hammered a server
/// with ~1 request/second of GET-stream reconnects when the server closed
/// the stream).
///
/// Verifies that the background GET stream:
///  - reconnects with exponentially growing gaps (1s, 2s, 4s, ...),
///  - stops after a bounded number of consecutive failures instead of
///    retrying forever at a flat interval.
void main() {
  test('GET stream reconnect is throttled and capped after failures', () async {
    final server = await ThrottleMockServer.start();
    addTearDown(server.close);

    late StreamableHttpClientTransport transport;
    transport = await StreamableHttpClientTransport.create(
      baseUrl: server.url,
      terminateOnClose: false,
    );
    addTearDown(transport.close);

    final responses = transport.onMessage.listen((_) {}, onError: (_) {});
    addTearDown(responses.cancel);

    // Establish the session (the transport captures MCP-Session-Id from the
    // initialize response).
    final initializeDone = Completer<void>();
    final initialized = transport.onMessage.listen((message) {
      if (message is Map && message['id'] == 1) {
        if (!initializeDone.isCompleted) initializeDone.complete();
      }
    });
    addTearDown(initialized.cancel);

    transport.send({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'initialize',
      'params': {
        'protocolVersion': McpProtocol.defaultVersion,
        'clientInfo': {'name': 'test', 'version': '1.0.0'},
        'capabilities': <String, dynamic>{},
      },
    });
    await initializeDone.future.timeout(const Duration(seconds: 5));

    // The initialized notification is what arms the background GET stream.
    transport.send({'jsonrpc': '2.0', 'method': 'notifications/initialized'});

    // Allow the cap sequence to run: 1s, 2s, 4s, 8s gaps (5 GETs total)
    // then the loop must stop.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await _waitUntil(() => server.getTimes.length >= 3);
    final firstGaps = <int>[
      server.getTimes[1].difference(server.getTimes[0]).inMilliseconds,
      server.getTimes[2].difference(server.getTimes[1]).inMilliseconds,
    ];

    // No flat 1s retry storm: the second gap must be significantly larger
    // than the first (exponential backoff).
    expect(
      firstGaps[1],
      greaterThanOrEqualTo((firstGaps[0] * 1.5).round()),
      reason: 'expected exponential backoff, got gaps $firstGaps',
    );

    await _waitUntil(() => server.getTimes.length >= 4);
    final thirdGap =
        server.getTimes[3].difference(server.getTimes[2]).inMilliseconds;
    expect(
      thirdGap,
      greaterThanOrEqualTo((firstGaps[1] * 1.5).round()),
      reason: 'expected further exponential growth, got gap $thirdGap',
    );

    // Run past the last scheduled reconnect (8s after GET #4) and assert the
    // loop gave up: no further GETs arrive and the count stays bounded.
    await Future<void>.delayed(const Duration(seconds: 10));
    final after = server.getTimes.length;
    await Future<void>.delayed(const Duration(seconds: 4));
    expect(
      server.getTimes.length,
      after,
      reason: 'GET stream kept reconnecting after the failure cap',
    );
    expect(
      after,
      lessThanOrEqualTo(6),
      reason: 'cap not applied: ${server.getTimes.length} GETs',
    );
  }, timeout: const Timeout(Duration(seconds: 45)));
}

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition was not met');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// Streamable-HTTP mock whose GET stream answers 200 and then closes
/// immediately — the exact server shape that used to produce the 1s
/// reconnect storm.
class ThrottleMockServer {
  final HttpServer _server;
  final List<DateTime> getTimes = [];
  late final Future<void> _serving;

  ThrottleMockServer._(this._server) {
    _serving = _serve();
  }

  static Future<ThrottleMockServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return ThrottleMockServer._(server);
  }

  String get url => 'http://${_server.address.address}:${_server.port}/mcp';

  Future<void> close() async {
    await _server.close(force: true);
    await _serving.timeout(const Duration(seconds: 1), onTimeout: () {});
  }

  Future<void> _serve() async {
    await for (final request in _server) {
      if (request.method == 'GET') {
        getTimes.add(DateTime.now());
        request.response.bufferOutput = false;
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
        );
        request.response.write(': connected\n\n');
        await request.response.flush();
        await request.response.close();
        continue;
      }

      final body = await utf8.decoder.bind(request).join();
      final message = jsonDecode(body) as Map<String, dynamic>;
      if (message['method'] == 'initialize') {
        request.response.headers.set('MCP-Session-Id', 'session-1');
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': message['id'],
            'result': {
              'protocolVersion': McpProtocol.defaultVersion,
              'serverInfo': {'name': 'ThrottleMock', 'version': '1.0.0'},
              'capabilities': <String, dynamic>{},
            },
          }),
        );
        await request.response.close();
        continue;
      }

      request.response.statusCode = HttpStatus.accepted;
      await request.response.close();
    }
  }
}
