import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import 'package:Cuplivo/core/providers/codex_device_code_controller.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';

import 'codex_device_code_flow.dart';
import 'ios_tile_button.dart';
import 'snackbar.dart';

/// Inline Codex account status card for provider settings pages: shows the
/// current sign-in state and lets the user start / sign out of the
/// device-code flow.
class CodexAccountEntry extends StatelessWidget {
  const CodexAccountEntry({super.key, required this.cfg});

  final ProviderConfig cfg;

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<CodexDeviceCodeController>();
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;

    final Widget body = switch (controller.status) {
      CodexAuthStatus.signedIn => _buildSignedIn(context, controller, l10n, cs),
      CodexAuthStatus.expired => _buildOutOfDate(
        context,
        controller,
        l10n,
        l10n.codexLoginStatusExpired,
      ),
      CodexAuthStatus.failed => _buildOutOfDate(
        context,
        controller,
        l10n,
        l10n.codexLoginStatusFailed,
      ),
      CodexAuthStatus.waitingForUser ||
      CodexAuthStatus.polling => _buildWaiting(controller, l10n, cs),
      CodexAuthStatus.signedOut => _buildSignedOut(context, l10n, cs),
    };

    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? Colors.white10 : cs.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.35)),
      ),
      child: body,
    );
  }

  Widget _buildSignedOut(
    BuildContext context,
    AppLocalizations l10n,
    ColorScheme cs,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.codexLoginTitle,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: cs.onSurface,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          l10n.codexLoginSubtitle,
          style: TextStyle(
            fontSize: 13,
            color: cs.onSurface.withValues(alpha: 0.7),
            height: 1.4,
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: IosTileButton(
            icon: Lucide.KeyRound,
            label: l10n.codexLoginSignInButton,
            backgroundColor: cs.primary,
            onTap: () => _openFlow(context),
          ),
        ),
      ],
    );
  }

  /// Reads the live provider config instead of the page snapshot so the flow
  /// starts with the current proxy / endpoint settings. The flow future is
  /// deliberately not awaited here; it guards its own errors.
  void _openFlow(BuildContext context) {
    final latest = context.read<SettingsProvider>().getProviderConfig(
      cfg.id,
      defaultName: cfg.name,
    );
    unawaited(showCodexDeviceCodeFlow(context, latest));
  }

  Widget _buildSignedIn(
    BuildContext context,
    CodexDeviceCodeController controller,
    AppLocalizations l10n,
    ColorScheme cs,
  ) {
    final cred = controller.credential;
    if (cred == null) {
      return _buildSignedOut(context, l10n, cs);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Lucide.CheckCircle, size: 18, color: Color(0xFF34C759)),
            const SizedBox(width: 8),
            Text(
              l10n.codexLoginStatusSignedIn,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: cs.onSurface,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          '${l10n.codexLoginAccountLabel}: ${cred.accountId}',
          style: TextStyle(
            fontSize: 13,
            color: cs.onSurface.withValues(alpha: 0.7),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '${l10n.codexLoginExpiresLabel}: ${DateFormat('yyyy-MM-dd HH:mm').format(cred.expiresAt.toLocal())}',
          style: TextStyle(
            fontSize: 13,
            color: cs.onSurface.withValues(alpha: 0.7),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: IosTileButton(
            icon: Lucide.Export,
            label: l10n.codexLoginSignOutButton,
            onTap: () => _confirmSignOut(context, controller, l10n),
          ),
        ),
      ],
    );
  }

  Widget _buildOutOfDate(
    BuildContext context,
    CodexDeviceCodeController controller,
    AppLocalizations l10n,
    String title,
  ) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: cs.error,
          ),
        ),
        if (controller.errorMessage != null &&
            controller.errorMessage!.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            controller.errorMessage!,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: cs.onSurface.withValues(alpha: 0.6),
              height: 1.4,
            ),
          ),
        ],
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: IosTileButton(
            icon: Lucide.KeyRound,
            label: l10n.codexLoginSignInButton,
            backgroundColor: cs.primary,
            onTap: () => _openFlow(context),
          ),
        ),
      ],
    );
  }

  Widget _buildWaiting(
    CodexDeviceCodeController controller,
    AppLocalizations l10n,
    ColorScheme cs,
  ) {
    final text = controller.status == CodexAuthStatus.polling
        ? l10n.codexLoginStatusPolling
        : l10n.codexLoginStatusWaiting;
    return Row(
      children: [
        const SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 13,
              color: cs.onSurface.withValues(alpha: 0.7),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _confirmSignOut(
    BuildContext context,
    CodexDeviceCodeController controller,
    AppLocalizations l10n,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.codexLoginSignOutButton),
        content: Text(l10n.codexLoginSignOutConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.codexLoginCancelButton),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.codexLoginSignOutButton),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!context.mounted) return;
    try {
      await controller.signOut();
    } catch (e, st) {
      debugPrint('[CodexOAuth] signOut failed: $e\n$st');
      if (!context.mounted) return;
      showAppSnackBar(
        context,
        message: l10n.codexLoginNetworkError,
        type: NotificationType.error,
      );
      return;
    }
    if (!context.mounted) return;
    showAppSnackBar(
      context,
      message: l10n.codexLoginSignedOutToast,
      type: NotificationType.success,
    );
  }
}
