import 'package:flutter_test/flutter_test.dart';
import 'package:Cuplivo/core/providers/mcp_provider.dart';
import 'package:Cuplivo/core/services/oauth/oauth_flow_service.dart';
import 'package:Cuplivo/features/mcp/widgets/mcp_oauth_section_controller.dart';

OAuthSectionMessages _messages() => const OAuthSectionMessages(
  notConfigured: 'not-configured',
  urlCopied: 'url-copied',
  flowStartFailed: 'flow-start-failed',
  success: 'success',
  tokenCleared: 'token-cleared',
);
McpOAuthSectionController _controller({
  required Future<OAuthFlowStartResult> Function(
    String serverId,
    McpOAuthConfig config,
  )
  begin,
  Future<void> Function(String, String)? complete,
  Future<String> Function(McpOAuthConfig)? ensureServerId,
  Future<void> Function(String)? removeServer,
  List<String>? notifications,
  List<String>? errors,
}) {
  final ctrl = McpOAuthSectionController(
    beginFlowOp: begin,
    completeFlowOp: complete ?? (serverId, pasted) async {},
    clearTokenOp: (serverId) async {},
    ensureServerIdOp: ensureServerId ?? (oauth) async => 'server-1',
    removeServerOp: removeServer,
    notify: (message, {isError = false}) {
      notifications?.add(message);
      if (isError) errors?.add(message);
    },
    launch: (url) async {},
    copyText: (text) async {},
    errorMessage: (code, detail) => 'err:$code:$detail',
    messages: _messages(),
  );
  return ctrl;
}

OAuthFlowStartResult _autoResult() => OAuthFlowStartResult(
  authorizationUrl: Uri.parse('https://mcp.example.com/authorize?x=1'),
  loopbackCallbackUrl: Uri.parse('http://localhost:1234/callback'),
);

OAuthFlowStartResult _manualResult() => OAuthFlowStartResult(
  authorizationUrl: Uri.parse('https://mcp.example.com/authorize?x=1'),
);
void main() {
  group('McpOAuthSectionController.buildConfig', () {
    test('returns null when disabled, empty fields legal when enabled', () {
      final ctrl = _controller(
        begin: (serverId, config) async => _autoResult(),
      );
      expect(ctrl.buildConfig(), isNull);

      ctrl.enabled = true;
      final config = ctrl.buildConfig();
      expect(config, isNotNull);
      expect(config!.authorizationEndpoint, '');
      expect(config.clientId, '');
    });

    test('initFrom pre-fills the form', () {
      final ctrl = _controller(
        begin: (serverId, config) async => _autoResult(),
      );
      ctrl.initFrom(
        const McpOAuthConfig(
          authorizationEndpoint: 'a',
          tokenEndpoint: 't',
          clientId: 'c',
          redirectUri: 'https://app.example.com/cb',
        ),
      );
      expect(ctrl.enabled, isTrue);
      expect(ctrl.authEndpointCtrl.text, 'a');
      expect(ctrl.redirectUriCtrl.text, 'https://app.example.com/cb');
      expect(ctrl.buildConfig()!.clientId, 'c');
    });

    test('initFrom(null) disables the section', () {
      final ctrl = _controller(
        begin: (serverId, config) async => _autoResult(),
      );
      ctrl.initFrom(null);
      expect(ctrl.enabled, isFalse);
    });

    test('clientRegistrationVersion survives the form round-trip', () {
      final ctrl = _controller(
        begin: (serverId, config) async => _autoResult(),
      );
      ctrl.initFrom(
        const McpOAuthConfig(
          authorizationEndpoint: 'a',
          tokenEndpoint: 't',
          clientId: 'c',
          clientRegistrationVersion: 2,
        ),
      );
      expect(ctrl.buildConfig()!.clientRegistrationVersion, 2);
    });
  });

  group('McpOAuthSectionController.discovered values', () {
    test('startFlow back-fills discovered endpoints and client id', () async {
      final ctrl = _controller(
        begin: (serverId, config) async => OAuthFlowStartResult(
          authorizationUrl: Uri.parse('https://mcp.example.com/authorize?x=1'),
          loopbackCallbackUrl: Uri.parse('http://localhost:1234/callback'),
          usedDiscovery: true,
          usedDcr: true,
          discoveredAuthorizationEndpoint: 'https://mcp.example.com/authorize',
          discoveredTokenEndpoint: 'https://mcp.example.com/token',
          discoveredClientId: 'dcr-client-1',
        ),
        complete: (serverId, pasted) async {},
      );
      ctrl.enabled = true;
      await ctrl.startFlow();

      expect(ctrl.authEndpointCtrl.text, 'https://mcp.example.com/authorize');
      expect(ctrl.tokenEndpointCtrl.text, 'https://mcp.example.com/token');
      expect(ctrl.clientIdCtrl.text, 'dcr-client-1');
      // DCR ran — the form carries the current registration version so a
      // save does not reset it.
      expect(ctrl.clientRegistrationVersion, 2);
    });
  });

  group('McpOAuthSectionController.startFlow', () {
    test('auto mode triggers completeFlow without copying the URL', () async {
      final notifications = <String>[];
      final ctrl = _controller(
        begin: (serverId, config) async => _autoResult(),
        notifications: notifications,
      );
      ctrl.enabled = true;
      await ctrl.startFlow();

      // The auto completion runs immediately and finishes the flow.
      expect(ctrl.flowStarted, isFalse);
      expect(notifications, contains('success'));
      // Auto mode must not copy the URL (no url-copied notification).
      expect(notifications, isNot(contains('url-copied')));
    });

    test('manual mode copies the URL and notifies', () async {
      final notifications = <String>[];
      final ctrl = _controller(
        begin: (serverId, config) async => _manualResult(),
        notifications: notifications,
      );
      ctrl.enabled = true;
      await ctrl.startFlow();

      expect(ctrl.flowStarted, isTrue);
      expect(ctrl.autoMode, isFalse);
      expect(notifications, contains('url-copied'));
    });

    test('disabled section notifies notConfigured', () async {
      final errors = <String>[];
      final ctrl = _controller(
        begin: (serverId, config) async => _autoResult(),
        errors: errors,
      );
      await ctrl.startFlow();
      expect(errors, contains('not-configured'));
    });

    test(
      'OAuthFlowException from beginFlow maps through errorMessage',
      () async {
        final errors = <String>[];
        final ctrl = _controller(
          begin: (serverId, config) async {
            throw const OAuthFlowException(
              OAuthFlowErrorCode.noAuthEndpoint,
              'no metadata',
            );
          },
          errors: errors,
        );
        ctrl.enabled = true;
        await ctrl.startFlow();

        expect(
          errors,
          contains('err:OAuthFlowErrorCode.noAuthEndpoint:no metadata'),
        );
        // The generic fallback must NOT be shown for typed errors.
        expect(errors, isNot(contains('flow-start-failed')));
      },
    );

    test('generic exception from beginFlow shows flowStartFailed', () async {
      final errors = <String>[];
      final ctrl = _controller(
        begin: (serverId, config) async => throw StateError('boom'),
        errors: errors,
      );
      ctrl.enabled = true;
      await ctrl.startFlow();

      expect(errors, contains('flow-start-failed'));
    });

    test('failed start removes the add-mode server (ghost cleanup)', () async {
      final removed = <String>[];
      late final McpOAuthSectionController ctrl;
      ctrl = _controller(
        begin: (serverId, config) async => throw StateError('boom'),
        ensureServerId: (oauth) async {
          ctrl.createdId = 'ghost-1';
          return 'ghost-1';
        },
        removeServer: (serverId) async => removed.add(serverId),
      );
      ctrl.enabled = true;
      await ctrl.startFlow();

      expect(removed, ['ghost-1']);
      expect(ctrl.createdId, isNull);
    });

    test('failed start keeps edit-mode servers untouched', () async {
      final removed = <String>[];
      final ctrl = _controller(
        begin: (serverId, config) async => throw StateError('boom'),
        removeServer: (serverId) async => removed.add(serverId),
      );
      ctrl.enabled = true;
      await ctrl.startFlow();

      expect(removed, isEmpty);
    });
  });

  group('McpOAuthSectionController.completeFlow', () {
    test('success resets flow state and notifies', () async {
      final notifications = <String>[];
      final ctrl = _controller(
        begin: (serverId, config) async => _autoResult(),
        complete: (serverId, pasted) async {},
        notifications: notifications,
      );
      ctrl.flowStarted = true;
      ctrl.autoMode = true;
      await ctrl.completeFlow('server-1');

      expect(ctrl.flowStarted, isFalse);
      expect(ctrl.autoMode, isFalse);
      expect(notifications, contains('success'));
    });

    test('OAuthFlowException maps through errorMessage', () async {
      final errors = <String>[];
      final ctrl = _controller(
        begin: (serverId, config) async => _autoResult(),
        complete: (serverId, pasted) async {
          throw const OAuthFlowException(
            OAuthFlowErrorCode.stateMismatch,
            'bad state',
          );
        },
        errors: errors,
      );
      await ctrl.completeFlow('server-1');

      expect(
        errors,
        contains('err:OAuthFlowErrorCode.stateMismatch:bad state'),
      );
      // Session stays usable: completing resets for a retry.
      expect(ctrl.completing, isFalse);
    });

    test('guards concurrent completion', () async {
      var calls = 0;
      final ctrl = _controller(
        begin: (serverId, config) async => _autoResult(),
        complete: (serverId, pasted) async {
          calls++;
          await Future<void>.delayed(const Duration(milliseconds: 10));
        },
      );
      final first = ctrl.completeFlow('server-1');
      final second = ctrl.completeFlow('server-1'); // completing guard
      await Future.wait([first, second]);
      expect(calls, 1);
    });

    test('an empty paste does not disturb an in-flight auto wait', () async {
      var calls = 0;
      final ctrl = _controller(
        begin: (serverId, config) async => _autoResult(),
        complete: (serverId, pasted) async {
          calls++;
          await Future<void>.delayed(const Duration(milliseconds: 10));
        },
      );
      ctrl.flowStarted = true;
      ctrl.autoMode = true;
      final first = ctrl.completeFlow('server-1'); // auto wait in flight
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await ctrl.completeFlow('server-1'); // empty paste → no-op
      await first;
      expect(calls, 1);
    });

    test('a paste overrides the in-flight auto wait', () async {
      final received = <String>[];
      final ctrl = _controller(
        begin: (serverId, config) async => _autoResult(),
        complete: (serverId, pasted) async {
          received.add(pasted);
          await Future<void>.delayed(const Duration(milliseconds: 10));
        },
      );
      ctrl.flowStarted = true;
      ctrl.autoMode = true;
      final waiting = ctrl.completeFlow('server-1'); // auto wait in flight
      await Future<void>.delayed(const Duration(milliseconds: 5));

      ctrl.pasteCtrl.text = 'pasted-code';
      await ctrl.completeFlow('server-1'); // paste overrides the wait

      expect(received, contains('pasted-code'));
      expect(ctrl.autoMode, isFalse);
      await waiting;
    });

    test('interrupted signal is silent (no user-facing error)', () async {
      final errors = <String>[];
      final ctrl = _controller(
        begin: (serverId, config) async => _autoResult(),
        complete: (serverId, pasted) async {
          throw const OAuthFlowException(
            OAuthFlowErrorCode.interrupted,
            'overridden',
          );
        },
        errors: errors,
      );
      ctrl.flowStarted = true;
      await ctrl.completeFlow('server-1');

      expect(errors, isEmpty);
      expect(ctrl.completing, isFalse);
    });
  });
}
