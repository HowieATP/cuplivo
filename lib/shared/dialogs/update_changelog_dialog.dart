import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/providers/update_provider.dart';
import '../../icons/lucide_adapter.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/app_font_weights.dart';
import '../widgets/ios_tactile.dart';
import '../widgets/snackbar.dart';

/// Update changelog dialog. Follows the "same content, different shell" pattern.
///
/// Use [show] on desktop (centered Dialog) and [showSheet] on mobile (bottom
/// sheet). Shows the pending version's release notes with a download action.
class UpdateChangelogDialog {
  /// Desktop: centered Dialog
  static Future<void> show(BuildContext context, {required UpdateInfo info}) {
    return showDialog<void>(
      context: context,
      builder: (_) => _UpdateChangelogDialogBody(info: info, isSheet: false),
    );
  }

  /// Mobile: bottom sheet
  static Future<void> showSheet(
    BuildContext context, {
    required UpdateInfo info,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        top: false,
        child: _UpdateChangelogDialogBody(info: info, isSheet: true),
      ),
    );
  }
}

class _UpdateChangelogDialogBody extends StatelessWidget {
  const _UpdateChangelogDialogBody({required this.info, required this.isSheet});

  final UpdateInfo info;
  final bool isSheet;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (isSheet) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: cs.onSurface.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            const SizedBox(height: 10),
            _buildBody(context, cs),
          ],
        ),
      );
    }
    return Dialog(
      backgroundColor: cs.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 320, maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: _buildBody(context, cs),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, ColorScheme cs) {
    final l10n = AppLocalizations.of(context)!;
    final url = info.bestDownloadUrl();
    final notes = (info.notes ?? '').trim();
    final version = info.build != null
        ? l10n.sideDrawerUpdateTitleWithBuild(info.version, info.build!)
        : l10n.sideDrawerUpdateTitle(info.version);

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.7,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IosIconButton(
                icon: Lucide.X,
                size: 18,
                color: cs.onSurface.withValues(alpha: 0.6),
                semanticLabel: l10n.updateCloseTooltip,
                onTap: () => Navigator.of(context).pop(),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  version,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: AppFontWeights.emphasis,
                    color: cs.onSurface,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              if (url != null && url.isNotEmpty) _buildDownloadButton(context),
            ],
          ),
          if (notes.isNotEmpty) ...[
            const SizedBox(height: 12),
            Flexible(
              child: SingleChildScrollView(
                child: GptMarkdown(
                  notes,
                  style: TextStyle(
                    fontSize: 13,
                    color: cs.onSurface.withValues(alpha: 0.85),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDownloadButton(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    return IosCardPress(
      borderRadius: BorderRadius.circular(8),
      baseColor: cs.primary,
      pressedBlendStrength: 0.3,
      pressedScale: 0.97,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      onTap: () => _download(context),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Lucide.Download, size: 16, color: cs.onPrimary),
          const SizedBox(width: 6),
          Text(
            l10n.updateDownloadButton,
            style: TextStyle(
              fontSize: 14,
              fontWeight: AppFontWeights.emphasis,
              color: cs.onPrimary,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _download(BuildContext context) async {
    final url = info.bestDownloadUrl();
    if (url == null || url.isEmpty) return;
    final l10n = AppLocalizations.of(context)!;
    try {
      // ignore: deprecated_member_use
      await launchUrl(Uri.parse(url));
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: url));
      if (!context.mounted) return;
      showAppSnackBar(
        context,
        message: l10n.sideDrawerLinkCopied,
        type: NotificationType.success,
      );
    }
  }
}
