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
  required Future<OAuthFlowStartResult> Function(String) begin,
  Future<void> Function(String, String)? complete,
  Future<String> Function(McpOAuthConfig)? ensureServerId,
  List<String>? notifications,
  List<String>? errors,
}) {
  final ctrl = McpOAuthSectionController(
    beginFlowOp: begin,
    completeFlowOp: complete ?? (serverId, pasted) async {},
    clearTokenOp: (serverId) async {},
    ensureServerIdOp: ensureServerId ?? (oauth) async => 'server-1',
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
      final ctrl = _controller(begin: (_) async => _autoResult());
      expect(ctrl.buildConfig(), isNull);

      ctrl.enabled = true;
      final config = ctrl.buildConfig();
      expect(config, isNotNull);
      expect(config!.authorizationEndpoint, '');
      expect(config.clientId, '');
    });

    test('initFrom pre-fills the form', () {
      final ctrl = _controller(begin: (_) async => _autoResult());
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
      final ctrl = _controller(begin: (_) async => _autoResult());
      ctrl.initFrom(null);
      expect(ctrl.enabled, isFalse);
    });
  });

  group('McpOAuthSectionController.startFlow', () {
    test('auto mode triggers completeFlow without copying the URL', () async {
      final notifications = <String>[];
      final ctrl = _controller(
        begin: (_) async => _autoResult(),
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
        begin: (_) async => _manualResult(),
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
        begin: (_) async => _autoResult(),
        errors: errors,
      );
      await ctrl.startFlow();
      expect(errors, contains('not-configured'));
    });
  });

  group('McpOAuthSectionController.completeFlow', () {
    test('success resets flow state and notifies', () async {
      final notifications = <String>[];
      final ctrl = _controller(
        begin: (_) async => _autoResult(),
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
        begin: (_) async => _autoResult(),
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
        begin: (_) async => _autoResult(),
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
  });
}
