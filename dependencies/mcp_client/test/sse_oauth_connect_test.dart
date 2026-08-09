@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mcp_client/mcp_client.dart';
import 'package:test/test.dart';

void main() {
  group(
    'SseAuthClientTransport restart auto-connect (issue: expired token)',
    () {
      late HttpServer server;
      int tokenEndpointHits = 0;
      String serverUrl = '';
      String tokenEndpoint = '';

      tearDown(() async {
        await server.close(force: true);
      });

      Future<void> startServer() async {
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        serverUrl = 'http://${server.address.address}:${server.port}/sse';
        tokenEndpoint = 'http://${server.address.address}:${server.port}/token';
        tokenEndpointHits = 0;

        server.listen((request) async {
          if (request.method == 'POST' && request.uri.path == '/token') {
            tokenEndpointHits++;
            final body = await utf8.decoder.bind(request).join();
            final params = Uri.splitQueryString(body);
            if (params['refresh_token'] == 'rt-hang') {
              // Simulates an unreachable/hung authorization server: never
              // answer within the transport's refresh bound.
              await Future<void>.delayed(const Duration(seconds: 60));
              request.response.statusCode = HttpStatus.internalServerError;
              await request.response.close();
              return;
            }
            if (params['grant_type'] == 'refresh_token' &&
                params['refresh_token'] == 'rt-1') {
              request.response.headers.contentType = ContentType.json;
              request.response.write(
                jsonEncode({
                  'access_token': 'at-refreshed',
                  'refresh_token': 'rt-refreshed',
                  'expires_in': 3600,
                  'token_type': 'Bearer',
                }),
              );
              await request.response.close();
              return;
            }
            request.response.statusCode = HttpStatus.badRequest;
            request.response.headers.contentType = ContentType.json;
            request.response.write(
              jsonEncode({
                'error': 'invalid_grant',
                'error_description': 'Unknown refresh token',
              }),
            );
            await request.response.close();
            return;
          }

          if (request.method == 'GET' && request.uri.path == '/sse') {
            final auth = request.headers.value(HttpHeaders.authorizationHeader);
            if (auth == 'Bearer at-valid' || auth == 'Bearer at-refreshed') {
              request.response.headers.contentType = ContentType(
                'text',
                'event-stream',
              );
              request.response.write(
                'event: endpoint\n'
                'data: /messages?session_id=test\n\n',
              );
              await request.response.close();
              return;
            }
            request.response.statusCode = HttpStatus.unauthorized;
            request.response.headers.contentType = ContentType.json;
            request.response.write(
              jsonEncode({
                'error': 'invalid_token',
                'error_description': 'The access token is expired',
              }),
            );
            await request.response.close();
            return;
          }

          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
        });
      }

      OAuthConfig oauthConfig() => OAuthConfig(
        authorizationEndpoint:
            'http://${server.address.address}:${server.port}/auth',
        tokenEndpoint: tokenEndpoint,
        clientId: 'test-client',
      );

      test('connects with a non-expired persisted token (restart happy path, '
          'no refresh call)', () async {
        await startServer();
        final refreshed = <OAuthToken>[];

        final transport = await SseAuthClientTransport.create(
          serverUrl: serverUrl,
          oauthToken: OAuthToken(
            accessToken: 'at-valid',
            refreshToken: 'rt-1',
            expiresIn: 3600,
            issuedAt: DateTime.now(),
          ),
          oauthClient: HttpOAuthClient(config: oauthConfig()),
          onTokenRefreshed: refreshed.add,
        );
        addTearDown(transport.close);
        // The server closes the GET response after the endpoint event; the
        // transport reports that closure on its onClose future, which nobody
        // listens to. Consume it so the error cannot fail the test.
        unawaited(transport.onClose.then<void>((_) {}).catchError((_) {}));

        expect(tokenEndpointHits, 0);
        expect(refreshed, isEmpty);
      });

      test('fails to connect with an expired token that has no refresh token '
          '(no recovery path, the pre-fix restart symptom)', () async {
        await startServer();
        final refreshed = <OAuthToken>[];

        final outcome = await runZonedGuarded<Future<Object>>(() async {
          try {
            final transport = await SseAuthClientTransport.create(
              serverUrl: serverUrl,
              oauthToken: OAuthToken(
                accessToken: 'at-expired',
                expiresIn: 3600,
                issuedAt: DateTime.now().subtract(const Duration(hours: 2)),
              ),
              oauthClient: HttpOAuthClient(config: oauthConfig()),
              onTokenRefreshed: refreshed.add,
            );
            addTearDown(transport.close);
            unawaited(transport.onClose.then<void>((_) {}).catchError((_) {}));
            return transport;
          } catch (e) {
            return e;
          }
        }, (_, __) {});

        // No refresh token -> no refresh attempt; the stale token is rejected.
        expect(
          outcome,
          isA<McpError>().having(
            (e) => e.message,
            'message',
            contains('Authentication failed'),
          ),
        );
        expect(tokenEndpointHits, 0);
        expect(refreshed, isEmpty);
      });

      test('refreshes an expired token before connecting when a refresh token '
          'exists (desired restart behavior)', () async {
        await startServer();
        final refreshed = <OAuthToken>[];

        // Run inside a guarded zone so the transport's unlistened onClose
        // error cannot fail the test; the closure returns either the
        // transport (success) or the thrown error, asserted outside the zone.
        final outcome = await runZonedGuarded<Future<Object>>(() async {
          try {
            final transport = await SseAuthClientTransport.create(
              serverUrl: serverUrl,
              oauthToken: OAuthToken(
                accessToken: 'at-expired',
                refreshToken: 'rt-1',
                expiresIn: 3600,
                issuedAt: DateTime.now().subtract(const Duration(hours: 2)),
              ),
              oauthClient: HttpOAuthClient(config: oauthConfig()),
              onTokenRefreshed: refreshed.add,
            );
            addTearDown(transport.close);
            unawaited(transport.onClose.then<void>((_) {}).catchError((_) {}));
            return transport;
          } catch (e) {
            return e;
          }
        }, (_, __) {});

        expect(
          outcome,
          isA<SseAuthClientTransport>(),
          reason: 'expired token should auto-refresh before connecting',
        );
        expect(tokenEndpointHits, 1);
        expect(refreshed, hasLength(1));
        expect(refreshed.single.accessToken, 'at-refreshed');
      });

      test('a rejected refresh falls through to the stale token and surfaces '
          'the auth failure', () async {
        await startServer();
        final refreshed = <OAuthToken>[];

        final outcome = await runZonedGuarded<Future<Object>>(() async {
          try {
            final transport = await SseAuthClientTransport.create(
              serverUrl: serverUrl,
              oauthToken: OAuthToken(
                accessToken: 'at-expired',
                refreshToken: 'rt-revoked',
                expiresIn: 3600,
                issuedAt: DateTime.now().subtract(const Duration(hours: 2)),
              ),
              oauthClient: HttpOAuthClient(config: oauthConfig()),
              onTokenRefreshed: refreshed.add,
            );
            addTearDown(transport.close);
            unawaited(transport.onClose.then<void>((_) {}).catchError((_) {}));
            return transport;
          } catch (e) {
            return e;
          }
        }, (_, __) {});

        // The refresh was attempted (once) and rejected; the stale expired
        // token then gets the 401 -> auth failure, not a silent connect.
        expect(
          outcome,
          isA<McpError>().having(
            (e) => e.message,
            'message',
            contains('Authentication failed'),
          ),
        );
        expect(tokenEndpointHits, 1);
        expect(refreshed, isEmpty);
      });

      test('a token without expires_in is never considered expired and is '
          'used as-is (no refresh attempt)', () async {
        await startServer();
        final refreshed = <OAuthToken>[];

        final outcome = await runZonedGuarded<Future<Object>>(() async {
          try {
            final transport = await SseAuthClientTransport.create(
              serverUrl: serverUrl,
              oauthToken: OAuthToken(
                accessToken: 'at-expired',
                refreshToken: 'rt-1',
                issuedAt: DateTime.now().subtract(const Duration(hours: 2)),
              ),
              oauthClient: HttpOAuthClient(config: oauthConfig()),
              onTokenRefreshed: refreshed.add,
            );
            addTearDown(transport.close);
            unawaited(transport.onClose.then<void>((_) {}).catchError((_) {}));
            return transport;
          } catch (e) {
            return e;
          }
        }, (_, __) {});

        // Documented boundary: no expires_in -> isExpired() is false locally,
        // the stale token is sent, the server rejects it.
        expect(
          outcome,
          isA<McpError>().having(
            (e) => e.message,
            'message',
            contains('Authentication failed'),
          ),
        );
        expect(tokenEndpointHits, 0);
        expect(refreshed, isEmpty);
      });

      test('an unreachable token endpoint cannot hang connect '
          '(refresh is time-bounded)', () async {
        await startServer();
        final refreshed = <OAuthToken>[];

        final outcome = await runZonedGuarded<Future<Object>>(() async {
          try {
            final transport = await SseAuthClientTransport.create(
              serverUrl: serverUrl,
              oauthToken: OAuthToken(
                accessToken: 'at-expired',
                refreshToken: 'rt-hang',
                expiresIn: 3600,
                issuedAt: DateTime.now().subtract(const Duration(hours: 2)),
              ),
              oauthClient: HttpOAuthClient(config: oauthConfig()),
              onTokenRefreshed: refreshed.add,
            ).timeout(const Duration(seconds: 30));
            addTearDown(transport.close);
            unawaited(transport.onClose.then<void>((_) {}).catchError((_) {}));
            return transport;
          } catch (e) {
            return e;
          }
        }, (_, __) {});

        // The refresh times out (~15s), falls through to the stale token,
        // which the server 401s. Without the bound this test would hit the
        // outer 30s timeout and fail with a TimeoutException.
        expect(outcome, isA<McpError>());
        expect(tokenEndpointHits, 1);
      });
    },
  );
}
