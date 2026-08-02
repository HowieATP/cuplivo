import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:Cuplivo/core/providers/grok_device_code_controller.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';

import 'ios_tile_button.dart';
import 'snackbar.dart';

/// Opens the Grok device-code sign-in flow (dialog on desktop, sheet on mobile).
Future<void> showGrokDeviceCodeFlow(
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
      builder: (_) => Dialog(child: GrokDeviceCodeFlow(cfg: cfg)),
    );
  } else {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => GrokDeviceCodeFlow(cfg: cfg),
    );
  }
}

/// Device-code sign-in UI for the Grok (xAI) OAuth flow.
class GrokDeviceCodeFlow extends StatefulWidget {
  const GrokDeviceCodeFlow({super.key, required this.cfg});

  final ProviderConfig cfg;

  @override
  State<GrokDeviceCodeFlow> createState() => _GrokDeviceCodeFlowState();
}

class _GrokDeviceCodeFlowState extends State<GrokDeviceCodeFlow> {
  Timer? _timer;
  DateTime? _deadline;
  Duration _remaining = kGrokFlowDeadline;
  bool _countdownExpired = false;
  bool _starting = false;
  bool _localFlowFailed = false;
  String _localFlowTitle = '';
  bool _providerWriteError = false;
  bool _providerWriteRetrying = false;
  Future<GrokFlowOutcome>? _flowFuture;
  late final SettingsProvider _settings;
  late final GrokDeviceCodeController _controller;

  @override
  void initState() {
    super.initState();
    _settings = context.read<SettingsProvider>();
    _controller = context.read<GrokDeviceCodeController>();
    _start();
  }

  @override
  void dispose() {
    _timer?.cancel();
    if (_controller.status == GrokAuthStatus.waitingForUser ||
        _controller.status == GrokAuthStatus.polling) {
      _controller.cancel();
    }
    super.dispose();
  }

  void _start() {
    _deadline = DateTime.now().add(kGrokFlowDeadline);
    _remaining = kGrokFlowDeadline;
    _countdownExpired = false;
    _localFlowFailed = false;
    _localFlowTitle = '';
    _providerWriteError = false;
    _providerWriteRetrying = false;
    _starting = true;
    if (mounted) setState(() {});
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) {
        _timer?.cancel();
        return;
      }
      final status = _controller.status;
      if (status == GrokAuthStatus.signedIn ||
          status == GrokAuthStatus.signedOut ||
          status == GrokAuthStatus.failed ||
          status == GrokAuthStatus.expired) {
        _timer?.cancel();
        return;
      }
      final left = _deadline!.difference(DateTime.now());
      final next = left.isNegative ? Duration.zero : left;
      if (next == _remaining) return;
      setState(() {
        _remaining = next;
        if (next == Duration.zero &&
            (status == GrokAuthStatus.waitingForUser ||
                status == GrokAuthStatus.polling)) {
          _countdownExpired = true;
        }
      });
      if (next == Duration.zero) _timer?.cancel();
    });
    _flowFuture = _runFlow();
  }

  Future<GrokFlowOutcome> _runFlow() async {
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return GrokFlowOutcome.cancelled;
    if (_starting) {
      setState(() => _starting = false);
    }
    try {
      final outcome = await _controller.startFlow(
        cfg: widget.cfg,
        onAuthenticated: _onAuthenticated,
      );
      if (!mounted) return outcome;
      if (outcome == GrokFlowOutcome.failed &&
          _controller.status != GrokAuthStatus.failed) {
        setState(() {
          _localFlowFailed = true;
          _localFlowTitle = AppLocalizations.of(context)!.grokLoginStatusFailed;
        });
      }
      return outcome;
    } catch (e, st) {
      debugPrint('[GrokOAuth] startFlow threw: $e\n$st');
      if (!mounted) return GrokFlowOutcome.failed;
      setState(() {
        _localFlowFailed = true;
        _localFlowTitle = AppLocalizations.of(context)!.grokLoginStatusFailed;
      });
      return GrokFlowOutcome.failed;
    }
  }

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

  /// Only enable the Grok provider if disabled. Never clear/overwrite apiKey,
  /// models, or baseUrl (unless baseUrl is empty → set default).
  Future<void> _applyProviderAfterAuth() async {
    final existing = _settings.getProviderConfig(
      kGrokProviderKey,
      defaultName: kGrokProviderKey,
    );
    final baseUrl = existing.baseUrl.trim();
    final next = existing.copyWith(
      enabled: existing.enabled ? existing.enabled : true,
      baseUrl: baseUrl.isEmpty ? kGrokDefaultBaseUrl : existing.baseUrl,
    );
    final needsWrite = !existing.enabled || baseUrl.isEmpty;
    if (!needsWrite) return;
    await _settings.setProviderConfig(kGrokProviderKey, next);
  }

  Future<void> _onAuthenticated() async {
    try {
      await _applyProviderAfterAuth();
    } catch (e, st) {
      debugPrint('[GrokOAuth] setProviderConfig failed: $e\n$st');
      if (mounted) {
        setState(() => _providerWriteError = true);
      }
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _retryProviderWrite() async {
    if (_providerWriteRetrying) return;
    setState(() => _providerWriteRetrying = true);
    try {
      await _applyProviderAfterAuth();
    } catch (e, st) {
      debugPrint('[GrokOAuth] setProviderConfig retry failed: $e\n$st');
      return;
    } finally {
      if (mounted) setState(() => _providerWriteRetrying = false);
    }
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _openAuthPage(Uri? uri, String errorMessage) async {
    var target = uri ?? Uri.parse(kGrokTrustedVerificationUri);
    final host = target.host.toLowerCase();
    final trusted =
        target.scheme == 'https' && (host == 'x.ai' || host.endsWith('.x.ai'));
    if (!trusted) {
      target = Uri.parse(kGrokTrustedVerificationUri);
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
      debugPrint('[GrokOAuth] clipboard copy failed: $e\n$st');
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: AppLocalizations.of(context)!.grokLoginCopyFailed,
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
    final controller = context.watch<GrokDeviceCodeController>();
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;

    final Widget content = _localFlowFailed
        ? _buildLocalFailed(
            l10n,
            cs,
            _localFlowTitle.isEmpty
                ? l10n.grokLoginStatusFailed
                : _localFlowTitle,
          )
        : _providerWriteError
        ? _buildProviderWriteError(l10n, cs)
        : switch (controller.status) {
            GrokAuthStatus.waitingForUser || GrokAuthStatus.polling =>
              _countdownExpired
                  ? _buildFailed(controller, l10n, l10n.grokLoginStatusExpired)
                  : _buildWaiting(controller, l10n, cs),
            GrokAuthStatus.expired => _buildFailed(
              controller,
              l10n,
              l10n.grokLoginStatusExpired,
            ),
            GrokAuthStatus.failed => _buildFailed(
              controller,
              l10n,
              l10n.grokLoginStatusFailed,
            ),
            GrokAuthStatus.signedIn => Text(
              l10n.grokLoginStatusSignedIn,
              style: TextStyle(fontSize: 14, color: cs.onSurface),
              textAlign: TextAlign.center,
            ),
            GrokAuthStatus.signedOut =>
              _starting
                  ? _buildWaiting(controller, l10n, cs)
                  : (controller.errorMessage != null &&
                        controller.errorMessage!.isNotEmpty)
                  ? _buildFailed(controller, l10n, l10n.grokLoginStatusFailed)
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
    GrokDeviceCodeController controller,
    AppLocalizations l10n,
    ColorScheme cs,
  ) {
    final waitingText = controller.status == GrokAuthStatus.polling
        ? l10n.grokLoginStatusPolling
        : l10n.grokLoginStatusWaiting;
    final usercode = controller.usercode;
    final hasUsercode = usercode != null && usercode.isNotEmpty;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Lucide.KeyRound, size: 28, color: cs.primary),
        const SizedBox(height: 12),
        Text(
          l10n.grokLoginTitle,
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: cs.onSurface,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 6),
        Text(
          l10n.grokLoginHelpText,
          style: TextStyle(
            fontSize: 13,
            color: cs.onSurface.withValues(alpha: 0.7),
            height: 1.4,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 20),
        Text(
          l10n.grokLoginUsercodeLabel,
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
            label: l10n.grokLoginOpenPageButton,
            backgroundColor: cs.primary,
            onTap: () => _openAuthPage(
              controller.verificationUri,
              l10n.grokLoginNetworkError,
            ),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: IosTileButton(
            icon: Lucide.Copy,
            label: l10n.grokLoginCopyCodeButton,
            enabled: hasUsercode,
            onTap: hasUsercode
                ? () => _copyUsercode(usercode, l10n.grokLoginCopiedToast)
                : () {},
          ),
        ),
        const SizedBox(height: 4),
        TextButton(onPressed: _cancel, child: Text(l10n.grokLoginCancelButton)),
      ],
    );
  }

  Widget _buildSignedOutEnd(AppLocalizations l10n, ColorScheme cs) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          l10n.grokLoginStatusSignedOut,
          style: TextStyle(fontSize: 14, color: cs.onSurface),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 18),
        TextButton(onPressed: _cancel, child: Text(l10n.grokLoginCloseButton)),
      ],
    );
  }

  Widget _buildProviderWriteError(AppLocalizations l10n, ColorScheme cs) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Lucide.TriangleAlert, size: 28, color: cs.error),
        const SizedBox(height: 12),
        Text(
          l10n.grokLoginStatusFailed,
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
            label: l10n.grokLoginSignInButton,
            backgroundColor: cs.primary,
            enabled: !_providerWriteRetrying,
            onTap: _retryProviderWrite,
          ),
        ),
        const SizedBox(height: 4),
        TextButton(onPressed: _cancel, child: Text(l10n.grokLoginCancelButton)),
      ],
    );
  }

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
            label: l10n.grokLoginSignInButton,
            backgroundColor: cs.primary,
            onTap: _retryFlow,
          ),
        ),
        const SizedBox(height: 4),
        TextButton(onPressed: _cancel, child: Text(l10n.grokLoginCancelButton)),
      ],
    );
  }

  Widget _buildFailed(
    GrokDeviceCodeController controller,
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
            label: l10n.grokLoginSignInButton,
            backgroundColor: cs.primary,
            onTap: _retryFlow,
          ),
        ),
        const SizedBox(height: 4),
        TextButton(onPressed: _cancel, child: Text(l10n.grokLoginCancelButton)),
      ],
    );
  }
}
