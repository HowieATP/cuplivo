import 'dart:convert';

import 'package:test/test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mcp_client/mcp_client.dart' as mcp;

void main() {
  group('OAuthConfig.copyWith', () {
    test('replaces fields, nulls are no-ops, clear flags clear', () {
      const base = mcp.OAuthConfig(
        authorizationEndpoint: 'https://a.example.com/authorize',
        tokenEndpoint: 'https://a.example.com/token',
        clientId: 'c1',
        clientSecret: 's1',
        redirectUri: 'https://app.example.com/cb',
        scopes: ['openid'],
      );

      final noop = base.copyWith(clientId: null, clientSecret: null);
      expect(noop.clientId, 'c1');
      expect(noop.clientSecret, 's1');

      final replaced = base.copyWith(clientId: 'c2', scopes: ['offline']);
      expect(replaced.clientId, 'c2');
      expect(replaced.scopes, ['offline']);
      expect(replaced.authorizationEndpoint, base.authorizationEndpoint);

      final cleared = base.copyWith(clearClientSecret: true);
      expect(cleared.clientSecret, isNull);
      expect(cleared.redirectUri, 'https://app.example.com/cb');

      final clearedUri = base.copyWith(clearRedirectUri: true);
      expect(clearedUri.redirectUri, isNull);
    });
  });

  group('HttpOAuthClient.discoverAuthServerMetadata', () {
    test('probes {origin}/.well-known/oauth-authorization-server', () async {
      final mock = MockClient((request) async {
        expect(
          request.url.toString(),
          'https://mcp.example.com/.well-known/oauth-authorization-server',
        );
        return http.Response(
          jsonEncode({
            'issuer': 'https://mcp.example.com/',
            'authorization_endpoint': 'https://mcp.example.com/authorize',
            'token_endpoint': 'https://mcp.example.com/token',
            'registration_endpoint': 'https://mcp.example.com/register',
            'code_challenge_methods_supported': ['S256'],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final metadata = await mcp.HttpOAuthClient.discoverAuthServerMetadata(
        'https://mcp.example.com/mcp/path',
        client: mock,
      );
      expect(metadata, isNotNull);
      expect(
        metadata!.authorizationEndpoint,
        'https://mcp.example.com/authorize',
      );
      expect(metadata.tokenEndpoint, 'https://mcp.example.com/token');
      expect(metadata.registrationEndpoint, 'https://mcp.example.com/register');
    });

    test(
      'returns null when the server serves no metadata (no OAuth)',
      () async {
        final mock = MockClient((request) async => http.Response('nf', 404));
        final metadata = await mcp.HttpOAuthClient.discoverAuthServerMetadata(
          'https://plain.example.com/mcp',
          client: mock,
        );
        expect(metadata, isNull);
      },
    );

    test('returns null for malformed URLs', () async {
      final metadata = await mcp.HttpOAuthClient.discoverAuthServerMetadata(
        'not a url',
      );
      expect(metadata, isNull);
    });
  });

  group('HttpOAuthClient.registerClient (RFC 7591)', () {
    test('posts the registration and returns the assigned client id', () async {
      String? sentBody;
      final mock = MockClient((request) async {
        if (request.url.path == '/.well-known/oauth-authorization-server') {
          return http.Response(
            jsonEncode({
              'issuer': 'https://mcp.example.com/',
              'authorization_endpoint': 'https://mcp.example.com/authorize',
              'token_endpoint': 'https://mcp.example.com/token',
              'registration_endpoint': 'https://mcp.example.com/register',
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.url.path == '/register') {
          sentBody = request.body;
          return http.Response(
            jsonEncode({
              'client_id': 'assigned-42',
              'redirect_uris': ['http://127.0.0.1/callback'],
              'token_endpoint_auth_method': 'none',
            }),
            201,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('nf', 404);
      });

      final client = mcp.HttpOAuthClient(
        config: const mcp.OAuthConfig(
          authorizationEndpoint: 'https://mcp.example.com/authorize',
          tokenEndpoint: 'https://mcp.example.com/token',
          clientId: 'pre-existing',
          authServerMetadataUrl:
              'https://mcp.example.com/.well-known/oauth-authorization-server',
        ),
        httpClient: mock,
      );

      final registered = await client.registerClient(
        redirectUris: const ['http://127.0.0.1/callback'],
        clientName: 'Cuplivo',
        tokenEndpointAuthMethod: 'none',
      );

      expect(registered.clientId, 'assigned-42');
      final body = jsonDecode(sentBody!) as Map<String, dynamic>;
      expect(body['client_name'], 'Cuplivo');
      expect(body['redirect_uris'], ['http://127.0.0.1/callback']);
      expect(body['token_endpoint_auth_method'], 'none');
      expect(body['grant_types'], ['authorization_code', 'refresh_token']);
    });

    test('uses an explicitly provided registration endpoint', () async {
      final mock = MockClient((request) async {
        expect(request.url.toString(), 'https://auth.example.com/register');
        return http.Response(
          jsonEncode({'client_id': 'explicit-7'}),
          201,
          headers: {'content-type': 'application/json'},
        );
      });

      final client = mcp.HttpOAuthClient(
        config: const mcp.OAuthConfig(
          authorizationEndpoint: 'https://mcp.example.com/authorize',
          tokenEndpoint: 'https://mcp.example.com/token',
          clientId: 'c',
        ),
        httpClient: mock,
      );

      final registered = await client.registerClient(
        redirectUris: const ['http://127.0.0.1/callback'],
        registrationEndpoint: 'https://auth.example.com/register',
      );
      expect(registered.clientId, 'explicit-7');
    });

    test('throws no_registration_endpoint without an endpoint', () async {
      final client = mcp.HttpOAuthClient(
        config: const mcp.OAuthConfig(
          authorizationEndpoint: 'https://mcp.example.com/authorize',
          tokenEndpoint: 'https://mcp.example.com/token',
          clientId: 'c',
        ),
        httpClient: MockClient((request) async => http.Response('nf', 404)),
      );

      await expectLater(
        client.registerClient(
          redirectUris: const ['http://127.0.0.1/callback'],
        ),
        throwsA(
          isA<mcp.OAuthError>().having(
            (e) => e.error,
            'error',
            'no_registration_endpoint',
          ),
        ),
      );
    });
  });

  group('HttpOAuthClient.exchangeCodeForToken redirect override', () {
    test(
      'sends the overridden redirect_uri instead of the config one',
      () async {
        String? sentBody;
        final mock = MockClient((request) async {
          if (request.url.path == '/token') {
            sentBody = request.body;
            return http.Response(
              jsonEncode({'access_token': 'at', 'token_type': 'Bearer'}),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response('nf', 404);
        });

        final client = mcp.HttpOAuthClient(
          config: const mcp.OAuthConfig(
            authorizationEndpoint: 'https://mcp.example.com/authorize',
            tokenEndpoint: 'https://mcp.example.com/token',
            clientId: 'c',
            redirectUri: 'https://app.example.com/cb',
          ),
          httpClient: mock,
        );

        await client.exchangeCodeForToken(
          code: 'code1',
          codeVerifier: 'verifier',
          redirectUri: 'http://127.0.0.1:1234/callback',
        );

        expect(
          sentBody,
          contains('redirect_uri=http%3A%2F%2F127.0.0.1%3A1234%2Fcallback'),
        );
        expect(sentBody, isNot(contains('app.example.com')));
      },
    );
  });

  group('OAuthTokenManager refresh hooks', () {
    test('getAccessToken fires onTokenRefresh with the new token', () async {
      final fake = _FakeOAuthClient();
      final manager = mcp.OAuthTokenManager(fake);
      final refreshed = <mcp.OAuthToken>[];
      manager.onTokenRefresh = (oldToken, newToken) {
        refreshed.add(newToken);
      };
      manager.setToken(
        mcp.OAuthToken(
          accessToken: 'at-expired',
          refreshToken: 'rt-1',
          expiresIn: 1,
          issuedAt: DateTime.now().subtract(const Duration(seconds: 5)),
        ),
      );

      final access = await manager.getAccessToken();

      expect(access, 'at-refreshed');
      // The refreshed token replaced the expired one.
      expect(manager.currentToken?.accessToken, 'at-refreshed');
      expect(manager.currentToken?.refreshToken, 'rt-refreshed');
      // The persistence hook must fire (regression: it was only reachable
      // via OAuthTokenManager.refreshToken(), which nothing called).
      expect(refreshed, hasLength(1));
      expect(refreshed.single.accessToken, 'at-refreshed');
    });

    test('setToken alone does not fire onTokenRefresh', () async {
      final fake = _FakeOAuthClient();
      final manager = mcp.OAuthTokenManager(fake);
      var calls = 0;
      manager.onTokenRefresh = (oldToken, newToken) => calls++;

      manager.setToken(
        mcp.OAuthToken(
          accessToken: 'at-1',
          refreshToken: 'rt-1',
          expiresIn: 3600,
          issuedAt: DateTime.now(),
        ),
      );

      expect(calls, 0);
    });
  });
}

class _FakeOAuthClient extends mcp.HttpOAuthClient {
  _FakeOAuthClient()
    : super(
        config: mcp.OAuthConfig(
          authorizationEndpoint: 'https://auth.example.com/authorize',
          tokenEndpoint: 'https://auth.example.com/token',
          clientId: 'c',
        ),
      );

  @override
  Future<mcp.OAuthToken> refreshToken({required String refreshToken}) async {
    return mcp.OAuthToken(
      accessToken: 'at-refreshed',
      refreshToken: 'rt-refreshed',
      expiresIn: 3600,
      issuedAt: DateTime.now(),
    );
  }
}
