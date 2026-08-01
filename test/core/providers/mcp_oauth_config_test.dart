import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mcp_client/mcp_client.dart' as mcp;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/providers/mcp_provider.dart';
import 'package:Cuplivo/core/services/oauth/oauth_flow_service.dart';

McpOAuthConfig _fullOAuth() => const McpOAuthConfig(
  authorizationEndpoint: 'https://auth.example.com/authorize',
  tokenEndpoint: 'https://auth.example.com/token',
  clientId: 'client-1',
  clientSecret: 'secret-1',
  scopes: 'mcp:tools:execute mcp:resources:read',
  redirectUri: 'https://app.example.com/callback',
);

mcp.OAuthToken _token() => mcp.OAuthToken(
  accessToken: 'at-1',
  refreshToken: 'rt-1',
  expiresIn: 3600,
  issuedAt: DateTime.fromMillisecondsSinceEpoch(1722400000000),
);

void main() {
  group('McpOAuthConfig', () {
    test('round-trips through toJson/fromJson with all fields', () {
      final restored = McpOAuthConfig.fromJson(_fullOAuth().toJson());
      expect(
        restored.authorizationEndpoint,
        'https://auth.example.com/authorize',
      );
      expect(restored.tokenEndpoint, 'https://auth.example.com/token');
      expect(restored.clientId, 'client-1');
      expect(restored.clientSecret, 'secret-1');
      expect(restored.scopes, 'mcp:tools:execute mcp:resources:read');
      expect(restored.redirectUri, 'https://app.example.com/callback');
    });

    test('omits empty optional fields from JSON', () {
      const config = McpOAuthConfig(
        authorizationEndpoint: 'a',
        tokenEndpoint: 't',
        clientId: 'c',
      );
      final json = config.toJson();
      expect(json.containsKey('clientSecret'), isFalse);
      expect(json.containsKey('scopes'), isFalse);
      expect(json.containsKey('redirectUri'), isFalse);
    });

    test('clientRegistrationVersion defaults to 0 and round-trips', () {
      expect(_fullOAuth().clientRegistrationVersion, 0);
      final versioned = _fullOAuth().copyWith(clientRegistrationVersion: 2);
      expect(versioned.clientRegistrationVersion, 2);
      expect(
        McpOAuthConfig.fromJson(versioned.toJson()).clientRegistrationVersion,
        2,
      );
    });

    test(
      'maps to the library OAuthConfig (scopes split, empty fields null)',
      () {
        final lib = _fullOAuth().toLibraryConfig();
        expect(lib.authorizationEndpoint, 'https://auth.example.com/authorize');
        expect(lib.tokenEndpoint, 'https://auth.example.com/token');
        expect(lib.clientId, 'client-1');
        expect(lib.clientSecret, 'secret-1');
        expect(lib.redirectUri, 'https://app.example.com/callback');
        expect(lib.scopes, ['mcp:tools:execute', 'mcp:resources:read']);
        expect(lib.grantType, mcp.OAuthGrantType.authorizationCode);
        expect(lib.codeChallengeMethod, 'S256');

        const minimal = McpOAuthConfig(
          authorizationEndpoint: 'a',
          tokenEndpoint: 't',
          clientId: 'c',
        );
        final libMin = minimal.toLibraryConfig();
        expect(libMin.clientSecret, isNull);
        expect(libMin.redirectUri, isNull);
        expect(libMin.scopes, isEmpty);
      },
    );
  });

  group('McpServerConfig OAuth round-trip', () {
    test('http server preserves oauth + oauthToken through JSON', () {
      final server = McpServerConfig(
        id: 's1',
        enabled: true,
        name: 'Auth MCP',
        transport: McpTransportType.http,
        url: 'https://mcp.example.com/mcp',
        oauth: _fullOAuth(),
        oauthToken: _token(),
      );

      final restored = McpServerConfig.fromJson(server.toJson());
      expect(restored.oauth?.clientId, 'client-1');
      expect(restored.oauth?.scopes, contains('mcp:resources:read'));
      expect(restored.oauthToken?.accessToken, 'at-1');
      expect(restored.oauthToken?.refreshToken, 'rt-1');
    });

    test(
      'old-format JSON without oauth keys loads as null (backward compat)',
      () {
        final old = jsonDecode(
          '{"id":"s1","enabled":true,"name":"Old","transport":"http",'
          '"url":"https://mcp.example.com/mcp","tools":[]}',
        );
        final restored = McpServerConfig.fromJson(
          (old as Map).cast<String, dynamic>(),
        );
        expect(restored.oauth, isNull);
        expect(restored.oauthToken, isNull);
      },
    );

    test(
      'copyWith(clearOauthToken: true) clears the token; null is a no-op',
      () {
        final server = McpServerConfig(
          id: 's1',
          enabled: true,
          name: 'Auth MCP',
          transport: McpTransportType.http,
          url: 'https://mcp.example.com/mcp',
          oauth: _fullOAuth(),
          oauthToken: _token(),
        );

        final noop = server.copyWith(oauthToken: null);
        expect(noop.oauthToken?.accessToken, 'at-1');

        final cleared = server.copyWith(clearOauthToken: true);
        expect(cleared.oauthToken, isNull);
        expect(cleared.oauth, isNotNull);

        final oauthCleared = server.copyWith(clearOauth: true);
        expect(oauthCleared.oauth, isNull);
        expect(oauthCleared.oauthToken, isNotNull);
      },
    );
  });

  group('McpProvider OAuth flow integration', () {
    late MockClient tokenServer;

    setUp(() {
      tokenServer = MockClient((request) async {
        if (request.url.toString().contains('/token')) {
          return http.Response(
            jsonEncode({
              'access_token': 'at-1',
              'token_type': 'Bearer',
              'expires_in': 3600,
              'refresh_token': 'rt-1',
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('not found', 404);
      });
    });

    McpProvider buildProvider() => McpProvider(
      contextProvider: () => throw UnimplementedError(),
      oauthFlowService: OAuthFlowService(clientFactory: () => tokenServer),
    );

    test('beginOAuthFlow throws StateError without OAuth config', () async {
      SharedPreferences.setMockInitialValues({});
      final provider = buildProvider();
      final id = await provider.addServer(
        enabled: false,
        name: 'No OAuth',
        transport: McpTransportType.http,
        url: 'https://mcp.example.com/mcp',
      );

      await expectLater(
        provider.beginOAuthFlow(id),
        throwsA(isA<StateError>()),
      );
    });

    test('beginOAuthFlow returns an authorize URL with client_id', () async {
      SharedPreferences.setMockInitialValues({});
      final provider = buildProvider();
      final id = await provider.addServer(
        enabled: false,
        name: 'Auth MCP',
        transport: McpTransportType.http,
        url: 'https://mcp.example.com/mcp',
        oauth: _fullOAuth(),
      );

      final result = await provider.beginOAuthFlow(id);
      expect(result.authorizationUrl.queryParameters['client_id'], 'client-1');
      expect(result.authorizationUrl.queryParameters['state'], isNotEmpty);
    });

    test(
      'completeOAuthFlow persists the token into the server config',
      () async {
        SharedPreferences.setMockInitialValues({});
        final provider = buildProvider();
        final id = await provider.addServer(
          enabled: false,
          name: 'Auth MCP',
          transport: McpTransportType.http,
          url: 'https://mcp.example.com/mcp',
          oauth: _fullOAuth(),
        );

        final result = await provider.beginOAuthFlow(id);
        final state = result.authorizationUrl.queryParameters['state']!;
        await provider.completeOAuthFlow(
          id,
          'https://app.example.com/callback?code=c1&state=$state',
        );

        final updated = provider.getById(id)!;
        expect(updated.oauthToken?.accessToken, 'at-1');
        expect(updated.oauthToken?.refreshToken, 'rt-1');

        // Persisted to SharedPreferences as well.
        final prefs = await SharedPreferences.getInstance();
        final raw = prefs.getString('mcp_servers_v1');
        expect(raw, contains('oauthToken'));
      },
    );

    test('clearOAuthToken removes the persisted token', () async {
      SharedPreferences.setMockInitialValues({});
      final provider = buildProvider();
      final id = await provider.addServer(
        enabled: false,
        name: 'Auth MCP',
        transport: McpTransportType.http,
        url: 'https://mcp.example.com/mcp',
        oauth: _fullOAuth(),
      );
      final result = await provider.beginOAuthFlow(id);
      final state = result.authorizationUrl.queryParameters['state']!;
      await provider.completeOAuthFlow(
        id,
        'https://app.example.com/callback?code=c1&state=$state',
      );

      await provider.clearOAuthToken(id);

      expect(provider.getById(id)!.oauthToken, isNull);
    });

    test('enabled server with OAuth but no token does NOT auto-connect '
        '(avoids stale "no token yet" error state)', () async {
      SharedPreferences.setMockInitialValues({});
      final provider = buildProvider();
      final id = await provider.addServer(
        enabled: true,
        name: 'Auth MCP',
        transport: McpTransportType.http,
        url: 'https://mcp.example.com/mcp',
        oauth: _fullOAuth(),
      );

      // Give any (wrongly) unawaited connect a chance to run.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(provider.statusFor(id), McpStatus.idle);
    });

    test('legacy auto-registered client (version 1) is re-registered on the '
        'next flow and the version is bumped', () async {
      SharedPreferences.setMockInitialValues({});
      final fullServer = MockClient((request) async {
        final path = request.url.path;
        if (path == '/.well-known/oauth-authorization-server') {
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
        if (path == '/register') {
          return http.Response(
            jsonEncode({'client_id': 'registered-client-1'}),
            201,
            headers: {'content-type': 'application/json'},
          );
        }
        if (path == '/token') {
          return http.Response(
            jsonEncode({'access_token': 'at', 'token_type': 'Bearer'}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('not found', 404);
      });
      final provider = McpProvider(
        contextProvider: () => throw UnimplementedError(),
        oauthFlowService: OAuthFlowService(clientFactory: () => fullServer),
      );
      final id = await provider.addServer(
        enabled: false,
        name: 'Legacy',
        transport: McpTransportType.http,
        url: 'https://mcp.example.com/mcp',
        oauth: const McpOAuthConfig(
          authorizationEndpoint: 'https://mcp.example.com/authorize',
          tokenEndpoint: 'https://mcp.example.com/token',
          clientId: 'legacy-client',
          clientRegistrationVersion: 1,
        ),
      );

      final result = await provider.beginOAuthFlow(id);

      expect(result.usedDcr, isTrue, reason: 'legacy client must re-register');
      expect(result.discoveredClientId, 'registered-client-1');
      final updated = provider.getById(id)!.oauth!;
      expect(updated.clientId, 'registered-client-1');
      expect(updated.clientRegistrationVersion, 2);
    });
  });
}
