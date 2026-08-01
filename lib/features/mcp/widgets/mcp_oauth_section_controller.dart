import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../../core/providers/mcp_provider.dart';
import '../../../core/services/oauth/oauth_flow_service.dart';

/// Localized user-facing strings for the OAuth section. The host builds
/// this from `AppLocalizations` — the controller never hardcodes text.
class OAuthSectionMessages {
  final String notConfigured;
  final String urlCopied;
  final String flowStartFailed;
  final String success;
  final String tokenCleared;

  const OAuthSectionMessages({
    required this.notConfigured,
    required this.urlCopied,
    required this.flowStartFailed,
    required this.success,
    required this.tokenCleared,
  });
}

/// Shared logic controller for the OAuth section of the MCP server edit
/// form (mobile bottom sheet and desktop dialog reuse it).
///
/// UI-agnostic: snackbar/clipboard/launch effects and the McpProvider
/// operations are injected as callbacks by the host widget (which owns the
/// `BuildContext` and its `mounted` checks). A future OAuth-protected LLM
/// provider (e.g. xAI) can reuse this controller by injecting its own
/// begin/complete implementations.
class McpOAuthSectionController {
  /// Host-injected operations. The `*Op` fields are usually thin wrappers
  /// around `McpProvider`; `ensureServerIdOp` persists the form in add-mode
  /// so the flow has an id.
  final Future<OAuthFlowStartResult> Function(String serverId) beginFlowOp;
  final Future<void> Function(String serverId, String pasted) completeFlowOp;
  final Future<void> Function(String serverId) clearTokenOp;
  final Future<String> Function(McpOAuthConfig oauth) ensureServerIdOp;

  /// Host-injected UI effects.
  final void Function(String message, {bool isError}) notify;
  final Future<void> Function(Uri url) launch;
  final Future<void> Function(String text) copyText;

  /// Maps an error code (plus raw server detail for exchange failures) to a
  /// localized message.
  final String Function(OAuthFlowErrorCode code, String detail) errorMessage;
  final OAuthSectionMessages messages;

  /// Called whenever flow state changes so the host can rebuild its UI.
  void Function()? onChanged;

  McpOAuthSectionController({
    required this.beginFlowOp,
    required this.completeFlowOp,
    required this.clearTokenOp,
    required this.ensureServerIdOp,
    required this.notify,
    required this.launch,
    required this.copyText,
    required this.errorMessage,
    required this.messages,
  });

  // --- form state ---
  final TextEditingController authEndpointCtrl = TextEditingController();
  final TextEditingController tokenEndpointCtrl = TextEditingController();
  final TextEditingController clientIdCtrl = TextEditingController();
  final TextEditingController clientSecretCtrl = TextEditingController();
  final TextEditingController scopesCtrl = TextEditingController();
  final TextEditingController redirectUriCtrl = TextEditingController();
  final TextEditingController pasteCtrl = TextEditingController();

  bool enabled = false;
  bool flowStarted = false;
  bool autoMode = false;
  bool completing = false;
  bool advancedExpanded = false;

  /// Set by [ensureServerIdOp] in add-mode so the save action updates the
  /// created server instead of creating a duplicate.
  String? createdId;

  /// Pre-fills the form from an existing config (edit mode).
  void initFrom(McpOAuthConfig? oauth) {
    enabled = oauth != null;
    if (oauth == null) return;
    authEndpointCtrl.text = oauth.authorizationEndpoint;
    tokenEndpointCtrl.text = oauth.tokenEndpoint;
    clientIdCtrl.text = oauth.clientId;
    clientSecretCtrl.text = oauth.clientSecret ?? '';
    scopesCtrl.text = oauth.scopes;
    redirectUriCtrl.text = oauth.redirectUri ?? '';
  }

  /// Assembles the OAuth config from the section fields.
  /// Returns null only when the switch is off. Empty fields are allowed —
  /// the flow auto-discovers endpoints and auto-registers a client.
  McpOAuthConfig? buildConfig() {
    if (!enabled) return null;
    final secret = clientSecretCtrl.text.trim();
    final redirect = redirectUriCtrl.text.trim();
    return McpOAuthConfig(
      authorizationEndpoint: authEndpointCtrl.text.trim(),
      tokenEndpoint: tokenEndpointCtrl.text.trim(),
      clientId: clientIdCtrl.text.trim(),
      clientSecret: secret.isEmpty ? null : secret,
      scopes: scopesCtrl.text.trim(),
      redirectUri: redirect.isEmpty ? null : redirect,
    );
  }

  /// Runs the authorization flow: ensure a server id (add mode), then
  /// `beginFlowOp` (discovery + DCR + loopback), open the browser, and in
  /// auto mode immediately start waiting for the callback.
  Future<void> startFlow() async {
    final oauth = buildConfig();
    if (oauth == null) {
      notify(messages.notConfigured, isError: true);
      return;
    }
    try {
      final serverId = await ensureServerIdOp(oauth);
      final result = await beginFlowOp(serverId);
      if (result.loopbackCallbackUrl != null) {
        // Auto mode: the loopback callback handles the exchange — no
        // clipboard copy needed.
        flowStarted = true;
        autoMode = true;
        pasteCtrl.clear();
        onChanged?.call();
        // The callback may arrive any moment — start waiting immediately
        // so the flow completes without the user tapping the button.
        unawaited(completeFlow(serverId));
      } else {
        // Manual mode: copy the URL for the user and show the paste field.
        await copyText(result.authorizationUrl.toString());
        notify(messages.urlCopied);
        flowStarted = true;
        autoMode = false;
        pasteCtrl.clear();
        onChanged?.call();
      }
      await launch(result.authorizationUrl);
    } catch (e) {
      notify(messages.flowStartFailed, isError: true);
    }
  }

  /// Completes the flow. A non-empty paste wins (manual); an empty paste in
  /// auto mode waits for the loopback callback.
  Future<void> completeFlow(String serverId) async {
    if (completing) return;
    final pasted = pasteCtrl.text.trim();
    completing = true;
    try {
      await completeFlowOp(serverId, pasted);
      flowStarted = false;
      autoMode = false;
      pasteCtrl.clear();
      notify(messages.success);
    } on OAuthFlowException catch (e) {
      notify(errorMessage(e.code, e.message), isError: true);
    } catch (e) {
      notify(
        errorMessage(OAuthFlowErrorCode.exchangeFailed, e.toString()),
        isError: true,
      );
    } finally {
      completing = false;
      onChanged?.call();
    }
  }

  /// Clears the persisted token (logout).
  Future<void> clearTokenFor(McpServerConfig server) async {
    await clearTokenOp(server.id);
    notify(messages.tokenCleared);
  }

  /// Whether the token has passed its expiry moment.
  bool isTokenExpired(DateTime? expires) =>
      expires != null && expires.isBefore(DateTime.now());

  void dispose() {
    authEndpointCtrl.dispose();
    tokenEndpointCtrl.dispose();
    clientIdCtrl.dispose();
    clientSecretCtrl.dispose();
    scopesCtrl.dispose();
    redirectUriCtrl.dispose();
    pasteCtrl.dispose();
  }
}
