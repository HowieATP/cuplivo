@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:mcp_client/mcp_client.dart';
import 'package:test/test.dart';

void main() {
  test('streamable HTTP: an unreachable token endpoint cannot hang a request '
      '(refresh is time-bounded)', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var tokenEndpointHits = 0;

    server.listen((request) async {
      if (request.method == 'POST' && request.uri.path == '/token') {
        tokenEndpointHits++;
        // Simulates an unreachable authorization server: never answer
        // within the token manager's refresh bound.
        await Future<void>.delayed(const Duration(seconds: 60));
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
        return;
      }
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    });

    addTearDown(() async {
      await server.close(force: true);
    });

    final transport = await StreamableHttpClientTransport.create(
      baseUrl: 'http://${server.address.address}:${server.port}/mcp',
      oauthConfig: OAuthConfig(
        authorizationEndpoint:
            'http://${server.address.address}:${server.port}/auth',
        tokenEndpoint: 'http://${server.address.address}:${server.port}/token',
        clientId: 'test-client',
      ),
      oauthToken: OAuthToken(
        accessToken: 'at-expired',
        refreshToken: 'rt-1',
        expiresIn: 3600,
        issuedAt: DateTime.now().subtract(const Duration(hours: 2)),
      ),
      terminateOnClose: false,
    );
    addTearDown(transport.close);

    // The refresh must time out (~15s) instead of hanging the request; the
    // error surfaces on the send operation's `done`.
    final errorReceived = Completer<Object>();
    final operation = transport.send({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'initialize',
    });
    operation.done.then<void>(
      (_) {},
      onError: (Object e, StackTrace _) {
        if (!errorReceived.isCompleted) errorReceived.complete(e);
      },
    );

    final err = await errorReceived.future.timeout(const Duration(seconds: 30));
    expect(err, isA<TimeoutException>());
    expect(tokenEndpointHits, 1);
  });
}
