import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:Cuplivo/core/providers/grok_device_code_controller.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/theme/app_semantic_colors.dart';
import 'grok_device_code_flow.dart';
import 'ios_tile_button.dart';
import 'snackbar.dart';

/// Inline Grok account status card for provider settings pages.
class GrokAccountEntry extends StatelessWidget {
  const GrokAccountEntry({super.key, required this.cfg});
  final ProviderConfig cfg;
  @override
  Widget build(BuildContext context) {
    final controller = context.watch<GrokDeviceCodeController>();
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final Widget body = switch (controller.status) {
      GrokAuthStatus.signedIn => _buildSignedIn(context, controller, l10n, cs),
      GrokAuthStatus.expired => _buildOutOfDate(
        context,
        controller,
        l10n,
        l10n.grokLoginStatusExpired,
      ),
      GrokAuthStatus.failed => _buildOutOfDate(
        context,
        controller,
        l10n,
        l10n.grokLoginStatusFailed,
      ),
      GrokAuthStatus.waitingForUser ||
      GrokAuthStatus.polling => _buildWaiting(controller, l10n, cs),
      GrokAuthStatus.signedOut => _buildSignedOut(context, l10n, cs),
    };
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        // color-gate: ignore
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
          l10n.grokLoginTitle,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: cs.onSurface,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          l10n.grokLoginSubtitle,
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
            label: l10n.grokLoginSignInButton,
            backgroundColor: cs.primary,
            onTap: () => _openFlow(context),
          ),
        ),
      ],
    );
  }

  void _openFlow(BuildContext context) {
    final controller = context.read<GrokDeviceCodeController>();
    if (controller.status == GrokAuthStatus.waitingForUser ||
        controller.status == GrokAuthStatus.polling) {
      return;
    }
    final latest = context.read<SettingsProvider>().getProviderConfig(
      cfg.id,
      defaultName: cfg.name,
    );
    unawaited(showGrokDeviceCodeFlow(context, latest));
  }

  Widget _buildSignedIn(
    BuildContext context,
    GrokDeviceCodeController controller,
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
            Icon(
              Lucide.CheckCircle,
              size: 18,
              color: context.appColors.success,
            ),
            const SizedBox(width: 8),
            Text(
              l10n.grokLoginStatusSignedIn,
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
          l10n.grokLoginAccountLabel,
          style: TextStyle(
            fontSize: 13,
            color: cs.onSurface.withValues(alpha: 0.7),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          l10n.grokLoginSessionHint,
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
            label: l10n.grokLoginSignOutButton,
            onTap: () => _confirmSignOut(context, controller, l10n),
          ),
        ),
      ],
    );
  }

  Widget _buildOutOfDate(
    BuildContext context,
    GrokDeviceCodeController controller,
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
            label: l10n.grokLoginSignInButton,
            backgroundColor: cs.primary,
            onTap: () => _openFlow(context),
          ),
        ),
      ],
    );
  }

  Widget _buildWaiting(
    GrokDeviceCodeController controller,
    AppLocalizations l10n,
    ColorScheme cs,
  ) {
    final text = controller.status == GrokAuthStatus.polling
        ? l10n.grokLoginStatusPolling
        : l10n.grokLoginStatusWaiting;
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
    GrokDeviceCodeController controller,
    AppLocalizations l10n,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.grokLoginSignOutButton),
        content: Text(l10n.grokLoginSignOutConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.grokLoginCancelButton),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.grokLoginSignOutButton),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!context.mounted) return;
    try {
      await controller.signOut();
    } catch (e, st) {
      debugPrint('[GrokOAuth] signOut failed: $e\n$st');
      if (!context.mounted) return;
      showAppSnackBar(
        context,
        message: l10n.grokLoginNetworkError,
        type: NotificationType.error,
      );
      return;
    }
    if (!context.mounted) return;
    showAppSnackBar(
      context,
      message: l10n.grokLoginSignedOutToast,
      type: NotificationType.success,
    );
  }
}
