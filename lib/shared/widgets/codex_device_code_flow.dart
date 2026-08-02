import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:Cuplivo/core/providers/codex_device_code_controller.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';

import 'ios_tile_button.dart';
import 'snackbar.dart';

/// Opens the Codex device-code sign-in flow, adapting to the host platform:
/// bottom sheet on mobile, dialog on desktop / web.
Future<void> showCodexDeviceCodeFlow(
  BuildContext context,
  ProviderConfig cfg,
) async {
  final isDesktop =
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.linux);
  if (isDesktop) {
    await showDialog<void>(
      context: context,
      builder: (_) => Dialog(child: CodexDeviceCodeFlow(cfg: cfg)),
    );
  } else {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => CodexDeviceCodeFlow(cfg: cfg),
    );
  }
}

/// Device-code sign-in UI for the Codex (ChatGPT) OAuth flow.
class CodexDeviceCodeFlow extends StatefulWidget {
  const CodexDeviceCodeFlow({super.key, required this.cfg});

  final ProviderConfig cfg;

  @override
  State<CodexDeviceCodeFlow> createState() => _CodexDeviceCodeFlowState();
}

class _CodexDeviceCodeFlowState extends State<CodexDeviceCodeFlow> {
  Timer? _timer;
  DateTime? _deadline;
  Duration _remaining = kCodexFlowDeadline;
  bool _countdownExpired = false;
  bool _starting = false;
  // Local failure state for failures that leave the controller without a
  // terminal status (e.g. a synchronous throw from startFlow's client
  // factory before its first await, or a notEnabled outcome): the controller
  // would otherwise sit in waitingForUser with no errorMessage, rendering a
  // permanent spinner.
  bool _localFlowFailed = false;
  String _localFlowTitle = '';
  bool _providerWriteError = false;
  bool _providerWriteRetrying = false;
  // The flow future of the current startFlow invocation, so a retry can wait
  // for the previous flow to fully exit (poll loop terminated, status
  // terminal) before restarting; restarting while the old flow is still
  // alive would be swallowed by the startFlow reentrancy guard.
  Future<CodexFlowOutcome>? _flowFuture;
  late final SettingsProvider _settings;
  late final CodexDeviceCodeController _controller;

  @override
  void initState() {
    super.initState();
    _settings = context.read<SettingsProvider>();
    _controller = context.read<CodexDeviceCodeController>();
    _start();
  }

  @override
  void dispose() {
    _timer?.cancel();
    if (_controller.status == CodexAuthStatus.waitingForUser ||
        _controller.status == CodexAuthStatus.polling) {
      _controller.cancel();
    }
    super.dispose();
  }

  void _start() {
    _deadline = DateTime.now().add(kCodexFlowDeadline);
    _remaining = kCodexFlowDeadline;
    _countdownExpired = false;
    _localFlowFailed = false;
    _localFlowTitle = '';
    _providerWriteError = false;
    _providerWriteRetrying = false;
    // Cover the deferred startFlow window: until _runFlow actually starts the
    // flow, the controller still reports its previous terminal state and the
    // first frame would flash it.
    _starting = true;
    if (mounted) setState(() {});
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) {
        _timer?.cancel();
        return;
      }
      final status = _controller.status;
      if (status == CodexAuthStatus.signedIn ||
          status == CodexAuthStatus.signedOut ||
          status == CodexAuthStatus.failed ||
          status == CodexAuthStatus.expired) {
        _timer?.cancel();
        return;
      }
      final left = _deadline!.difference(DateTime.now());
      final next = left.isNegative ? Duration.zero : left;
      if (next == _remaining) return;
      setState(() {
        _remaining = next;
        if (next == Duration.zero &&
            (status == CodexAuthStatus.waitingForUser ||
                status == CodexAuthStatus.polling)) {
          // The controller deadline fires at the same instant, but render the
          // expired state locally instead of freezing at 00:00 until its
          // notification lands.
          _countdownExpired = true;
        }
      });
      if (next == Duration.zero) _timer?.cancel();
    });
    _flowFuture = _runFlow();
  }

  /// Runs the flow; `startFlow` already handles most failures internally, so
  /// this is a last-resort guard for pre-await exceptions (e.g. a client
  /// factory throwing) that would otherwise surface as an unhandled future.
  Future<CodexFlowOutcome> _runFlow() async {
    // startFlow() notifies synchronously up to its first await; defer past the
    // build phase so initState-triggered flows never mark dependents dirty
    // while a route (bottom sheet / dialog) is still mounting.
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return CodexFlowOutcome.cancelled;
    if (_starting) {
      setState(() => _starting = false);
    }
    try {
      final outcome = await _controller.startFlow(
        cfg: widget.cfg,
        onAuthenticated: _onAuthenticated,
      );
      if (!mounted) return outcome;
      if (outcome == CodexFlowOutcome.notEnabled) {
        // The controller is already back to signedOut; surface the
        // account-level rejection on a retryable local error view instead of
        // the bare "not signed in" end state.
        setState(() {
          _localFlowFailed = true;
          _localFlowTitle = AppLocalizations.of(context)!.codexLoginNotEnabled;
        });
      } else if (outcome == CodexFlowOutcome.failed &&
          _controller.status != CodexAuthStatus.failed) {
        // startFlow failed without a terminal controller status (e.g. the
        // reentrancy guard swallowed a restart while the previous flow was
        // still polling): the controller would otherwise keep rendering a
        // code-less waiting view forever. The local failed view keeps the
        // retry/close buttons reachable. Genuine flow failures already set
        // status=failed and render the controller-driven error view with the
        // detail message, so they are not shadowed here.
        setState(() {
          _localFlowFailed = true;
          _localFlowTitle = AppLocalizations.of(
            context,
          )!.codexLoginStatusFailed;
        });
      }
      return outcome;
    } catch (e, st) {
      debugPrint('[CodexOAuth] startFlow threw: $e\n$st');
      if (!mounted) return CodexFlowOutcome.failed;
      setState(() {
        _localFlowFailed = true;
        _localFlowTitle = AppLocalizations.of(context)!.codexLoginStatusFailed;
      });
      return CodexFlowOutcome.failed;
    }
  }

  /// Restarts the flow after a failure: cancels the current flow and waits
  /// for it to fully exit (poll loop terminated, status terminal) so the
  /// startFlow reentrancy guard cannot swallow the restart, then starts a
  /// fresh flow. A terminal flow future (failed / expired view) completes
  /// immediately.
  Future<void> _retryFlow() async {
    _controller.cancel();
    final flow = _flowFuture;
    if (flow != null) {
      try {
        await flow;
      } catch (_) {}
    }
    if (!mounted) return;
    _start();
  }

  Future<void> _onAuthenticated() async {
    try {
      await _settings.setProviderConfig(
        kCodexProviderKey,
        codexProviderConfig(),
      );
    } catch (e, st) {
      // Provider-config write failure is a persistence problem, not a
      // network problem: keep the flow open on an error view instead of
      // popping into an orphan state (credential persisted but the provider
      // never created). The raw exception stays in the log; the view shows
      // only the localized failure copy.
      debugPrint('[CodexOAuth] setProviderConfig failed: $e\n$st');
      if (mounted) {
        setState(() => _providerWriteError = true);
      }
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  /// Retries the provider-config write after a failure. The credential is
  /// already persisted and signedIn, so this must not restart the device-code
  /// flow; a success pops the sheet, a failure keeps the error view.
  Future<void> _retryProviderWrite() async {
    if (_providerWriteRetrying) return;
    setState(() => _providerWriteRetrying = true);
    try {
      await _settings.setProviderConfig(
        kCodexProviderKey,
        codexProviderConfig(),
      );
    } catch (e, st) {
      debugPrint('[CodexOAuth] setProviderConfig retry failed: $e\n$st');
      return;
    } finally {
      if (mounted) setState(() => _providerWriteRetrying = false);
    }
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _openAuthPage(Uri? uri, String errorMessage) async {
    var target = uri ?? Uri.parse(kCodexVerificationUri);
    // Defensive hardening: only ever open the trusted OpenAI auth origin.
    // A corrupted controller value or a future call site forwarding an
    // arbitrary URL must not drive the external browser to an untrusted
    // host. The controller only ever publishes kCodexVerificationUri, so an
    // exact host match is all that is trusted.
    final trusted =
        target.scheme == 'https' && target.host == 'auth.openai.com';
    if (!trusted) {
      target = Uri.parse(kCodexVerificationUri);
    }
    try {
      final ok = await launchUrl(target, mode: LaunchMode.externalApplication);
      if (!ok && mounted) {
        showAppSnackBar(
          context,
          message: errorMessage,
          type: NotificationType.error,
        );
      }
    } catch (_) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: errorMessage,
        type: NotificationType.error,
      );
    }
  }

  Future<void> _copyUsercode(String code, String toast) async {
    try {
      await Clipboard.setData(ClipboardData(text: code));
    } catch (e, st) {
      debugPrint('[CodexOAuth] clipboard copy failed: $e\n$st');
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: AppLocalizations.of(context)!.codexLoginCopyFailed,
        type: NotificationType.error,
      );
      return;
    }
    if (!mounted) return;
    showAppSnackBar(context, message: toast, type: NotificationType.success);
  }

  void _cancel() {
    Navigator.of(context).pop();
  }

  String _formatRemaining(Duration d) {
    final minutes = d.inMinutes.toString().padLeft(2, '0');
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    // watch: subscribes to the same instance captured in [initState] so the
    // UI rebuilds on status changes; no second instance source.
    final controller = context.watch<CodexDeviceCodeController>();
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;

    final Widget content = _localFlowFailed
        ? _buildLocalFailed(
            l10n,
            cs,
            _localFlowTitle.isEmpty
                ? l10n.codexLoginStatusFailed
                : _localFlowTitle,
          )
        : _providerWriteError
        ? _buildProviderWriteError(l10n, cs)
        : switch (controller.status) {
            CodexAuthStatus.waitingForUser || CodexAuthStatus.polling =>
              _countdownExpired
                  ? _buildFailed(controller, l10n, l10n.codexLoginStatusExpired)
                  : _buildWaiting(controller, l10n, cs),
            CodexAuthStatus.expired => _buildFailed(
              controller,
              l10n,
              l10n.codexLoginStatusExpired,
            ),
            CodexAuthStatus.failed => _buildFailed(
              controller,
              l10n,
              l10n.codexLoginStatusFailed,
            ),
            CodexAuthStatus.signedIn => Text(
              l10n.codexLoginStatusSignedIn,
              style: TextStyle(fontSize: 14, color: cs.onSurface),
              textAlign: TextAlign.center,
            ),
            CodexAuthStatus.signedOut =>
              _starting
                  ? _buildWaiting(controller, l10n, cs)
                  : (controller.errorMessage != null &&
                        controller.errorMessage!.isNotEmpty)
                  ? _buildFailed(controller, l10n, l10n.codexLoginStatusFailed)
                  : _buildSignedOutEnd(l10n, cs),
          };

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
        child: content,
      ),
    );
  }

  Widget _buildWaiting(
    CodexDeviceCodeController controller,
    AppLocalizations l10n,
    ColorScheme cs,
  ) {
    final waitingText = controller.status == CodexAuthStatus.polling
        ? l10n.codexLoginStatusPolling
        : l10n.codexLoginStatusWaiting;
    final usercode = controller.usercode;
    final hasUsercode = usercode != null && usercode.isNotEmpty;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Lucide.KeyRound, size: 28, color: cs.primary),
        const SizedBox(height: 12),
        Text(
          l10n.codexLoginTitle,
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: cs.onSurface,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 6),
        Text(
          l10n.codexLoginHelpText,
          style: TextStyle(
            fontSize: 13,
            color: cs.onSurface.withValues(alpha: 0.7),
            height: 1.4,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 20),
        Text(
          l10n.codexLoginUsercodeLabel,
          style: TextStyle(
            fontSize: 12,
            color: cs.onSurface.withValues(alpha: 0.6),
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 6),
        if (hasUsercode)
          SelectableText(
            usercode,
            style: TextStyle(
              fontSize: 34,
              fontWeight: FontWeight.w700,
              letterSpacing: 4,
              fontFamily: 'monospace',
              color: cs.onSurface,
            ),
            textAlign: TextAlign.center,
          )
        else
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        const SizedBox(height: 14),
        Text(
          waitingText,
          style: TextStyle(
            fontSize: 13,
            color: cs.onSurface.withValues(alpha: 0.6),
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 6),
        Text(
          _formatRemaining(_remaining),
          style: TextStyle(
            fontSize: 12,
            fontFamily: 'monospace',
            color: cs.onSurface.withValues(alpha: 0.5),
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 18),
        SizedBox(
          width: double.infinity,
          child: IosTileButton(
            icon: Lucide.Globe,
            label: l10n.codexLoginOpenPageButton,
            backgroundColor: cs.primary,
            onTap: () => _openAuthPage(
              controller.verificationUri,
              l10n.codexLoginNetworkError,
            ),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: IosTileButton(
            icon: Lucide.Copy,
            label: l10n.codexLoginCopyCodeButton,
            enabled: hasUsercode,
            onTap: hasUsercode
                ? () => _copyUsercode(usercode, l10n.codexLoginCopiedToast)
                : () {},
          ),
        ),
        const SizedBox(height: 4),
        TextButton(
          onPressed: _cancel,
          child: Text(l10n.codexLoginCancelButton),
        ),
      ],
    );
  }

  Widget _buildSignedOutEnd(AppLocalizations l10n, ColorScheme cs) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          l10n.codexLoginStatusSignedOut,
          style: TextStyle(fontSize: 14, color: cs.onSurface),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 18),
        TextButton(onPressed: _cancel, child: Text(l10n.codexLoginCloseButton)),
      ],
    );
  }

  /// Shown when the credential persisted but writing the provider config
  /// failed. Closing accepts the orphan state (credential stays signed in;
  /// it can be removed from the account entry's sign-out button).
  Widget _buildProviderWriteError(AppLocalizations l10n, ColorScheme cs) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Lucide.TriangleAlert, size: 28, color: cs.error),
        const SizedBox(height: 12),
        Text(
          l10n.codexLoginStatusFailed,
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: cs.onSurface,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 18),
        SizedBox(
          width: double.infinity,
          child: IosTileButton(
            icon: Lucide.RefreshCw,
            label: l10n.codexLoginSignInButton,
            backgroundColor: cs.primary,
            enabled: !_providerWriteRetrying,
            onTap: _retryProviderWrite,
          ),
        ),
        const SizedBox(height: 4),
        TextButton(
          onPressed: _cancel,
          child: Text(l10n.codexLoginCancelButton),
        ),
      ],
    );
  }

  /// Local failure view for errors that never reached the controller's
  /// terminal statuses: the retry is always enabled because the controller
  /// may be stuck in a pre-flow state that the controller-driven failed view
  /// would keep disabled.
  Widget _buildLocalFailed(
    AppLocalizations l10n,
    ColorScheme cs,
    String title,
  ) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Lucide.TriangleAlert, size: 28, color: cs.error),
        const SizedBox(height: 12),
        Text(
          title,
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: cs.onSurface,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 18),
        SizedBox(
          width: double.infinity,
          child: IosTileButton(
            icon: Lucide.RefreshCw,
            label: l10n.codexLoginSignInButton,
            backgroundColor: cs.primary,
            // Cancel the stale flow and wait for it to fully exit before
            // restarting: while a stale poll loop is still running, a plain
            // retry would be swallowed by the startFlow reentrancy guard and
            // appear dead.
            onTap: _retryFlow,
          ),
        ),
        const SizedBox(height: 4),
        TextButton(
          onPressed: _cancel,
          child: Text(l10n.codexLoginCancelButton),
        ),
      ],
    );
  }

  Widget _buildFailed(
    CodexDeviceCodeController controller,
    AppLocalizations l10n,
    String title,
  ) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Lucide.TriangleAlert, size: 28, color: cs.error),
        const SizedBox(height: 12),
        Text(
          title,
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: cs.onSurface,
          ),
          textAlign: TextAlign.center,
        ),
        if (controller.errorMessage != null &&
            controller.errorMessage!.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            controller.errorMessage!,
            style: TextStyle(
              fontSize: 12,
              color: cs.error.withValues(alpha: 0.9),
              height: 1.4,
            ),
            textAlign: TextAlign.center,
          ),
        ],
        const SizedBox(height: 18),
        SizedBox(
          width: double.infinity,
          child: IosTileButton(
            icon: Lucide.RefreshCw,
            label: l10n.codexLoginSignInButton,
            backgroundColor: cs.primary,
            onTap: _retryFlow,
          ),
        ),
        const SizedBox(height: 4),
        TextButton(
          onPressed: _cancel,
          child: Text(l10n.codexLoginCancelButton),
        ),
      ],
    );
  }
}
