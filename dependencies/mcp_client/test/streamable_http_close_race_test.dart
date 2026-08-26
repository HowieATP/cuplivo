@TestOn('vm')
library;

import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:mcp_client/mcp_client.dart';
import 'package:test/test.dart';

/// A client whose request stays in flight until released, then fails.
///
/// Used to land a transport error after [StreamableHttpClientTransport.close]
/// has already closed the message stream.
class _HeldClient extends http.BaseClient {
  final Completer<void> requestStarted = Completer<void>();
  final Completer<void> release = Completer<void>();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (!requestStarted.isCompleted) {
      requestStarted.complete();
    }
    await release.future;
    throw http.ClientException('connection reset');
  }
}

void main() {
  test('errors landing after close() do not crash the transport', () async {
    final client = _HeldClient();
    final transport = await StreamableHttpClientTransport.create(
      baseUrl: 'http://127.0.0.1:9/mcp',
      httpClient: client,
      terminateOnClose: false,
      useHttp2: false,
    );
    addTearDown(transport.close);

    // Invariants of the redesigned transport: send errors are delivered on
    // the operation's `done` future — the message stream is only for
    // server-sent messages — and no late error is pushed onto a closed
    // broadcast controller.
    final operation = transport.send({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'ping',
    });
    final errorReceived = Completer<Object>();
    operation.done.then<void>(
      (_) {},
      onError: (Object e, StackTrace _) {
        if (!errorReceived.isCompleted) errorReceived.complete(e);
      },
    );
    await client.requestStarted.future;

    // Close the transport while the request is still in flight, then let
    // the request fail. Before the fix, the late error was pushed onto the
    // closed broadcast stream controller and surfaced as an unhandled
    // "Bad state: Cannot add new events after calling close".
    transport.close();
    client.release.complete();

    final err = await errorReceived.future.timeout(const Duration(seconds: 5));
    expect(err, isA<http.ClientException>());
  });
}
