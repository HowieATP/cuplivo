import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../icons/lucide_adapter.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/app_font_weights.dart';
import '../widgets/ios_tactile.dart';

/// Shows the "Import from New Kelivo" migration guide.
///
/// The conversion happens on the Kelivo-helper website. After downloading the
/// converted file, the user imports it through the existing backup-file import
/// flow.
Future<void> showKelivoImportDialog({required BuildContext context}) {
  return showDialog<void>(
    context: context,
    builder: (_) => const _KelivoImportDialog(),
  );
}

Future<void> _openKelivoImportUrl(String url) async {
  final uri = Uri.parse(url);

  try {
    if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
    debugPrint('KelivoImport: external browser launch returned false');
  } catch (error) {
    debugPrint('KelivoImport: external browser launch failed: $error');
  }

  try {
    if (await launchUrl(uri, mode: LaunchMode.platformDefault)) return;
    debugPrint('KelivoImport: platform-default launch returned false');
  } catch (error) {
    debugPrint('KelivoImport: platform-default launch failed: $error');
  }

  try {
    if (!await launchUrl(uri)) {
      debugPrint('KelivoImport: final URL launch attempt returned false');
    }
  } catch (error) {
    debugPrint('KelivoImport: final URL launch attempt failed: $error');
  }
}

class _KelivoImportDialog extends StatelessWidget {
  const _KelivoImportDialog();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final steps = <String>[
      l10n.backupPageKelivoImportStep1,
      l10n.backupPageKelivoImportStep2,
      l10n.backupPageKelivoImportStep3,
      l10n.backupPageKelivoImportStep4,
      l10n.backupPageKelivoImportStep5,
    ];

    return Dialog(
      backgroundColor: cs.surface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 340, maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 12, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.backupPageImportFromKelivo,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: AppFontWeights.emphasis,
                        color: cs.onSurface,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 28,
                    height: 28,
                    child: IosIconButton(
                      icon: Lucide.X,
                      size: 20,
                      padding: EdgeInsets.zero,
                      color: cs.onSurface.withValues(alpha: 0.62),
                      semanticLabel: l10n.mcpPageClose,
                      onTap: () => Navigator.of(context).maybePop(),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Flexible(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(context).height * 0.62,
                  ),
                  child: SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.backupPageKelivoImportHint,
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.4,
                              color: cs.onSurface.withValues(alpha: 0.72),
                            ),
                          ),
                          const SizedBox(height: 10),
                          _KelivoUrlCard(url: l10n.backupPageKelivoImportUrl),
                          const SizedBox(height: 16),
                          Text(
                            l10n.backupPageKelivoImportTutorialTitle,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: AppFontWeights.semibold,
                              color: cs.onSurface.withValues(alpha: 0.9),
                            ),
                          ),
                          const SizedBox(height: 10),
                          for (var i = 0; i < steps.length; i++) ...[
                            _KelivoTutorialStep(
                              index: i + 1,
                              text: steps[i],
                              isDark: isDark,
                            ),
                            if (i != steps.length - 1)
                              const SizedBox(height: 10),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: Text(l10n.backupPageOK),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _KelivoUrlCard extends StatelessWidget {
  const _KelivoUrlCard({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return IosCardPress(
      borderRadius: BorderRadius.circular(12),
      baseColor: isDark
          ? cs.surfaceContainerHighest.withValues(alpha: 0.50)
          : cs.surfaceContainerHighest.withValues(alpha: 0.45),
      onTap: () => _openKelivoImportUrl(url),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: Row(
        children: [
          Icon(Lucide.Link2, size: 16, color: cs.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              url,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: AppFontWeights.medium,
                color: cs.primary,
                decoration: TextDecoration.underline,
                decorationColor: cs.primary.withValues(alpha: 0.5),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _KelivoTutorialStep extends StatelessWidget {
  const _KelivoTutorialStep({
    required this.index,
    required this.text,
    required this.isDark,
  });

  final int index;
  final String text;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: isDark
                ? cs.primary.withValues(alpha: 0.22)
                : cs.primary.withValues(alpha: 0.12),
            shape: BoxShape.circle,
          ),
          child: Text(
            '$index',
            style: TextStyle(
              fontSize: 12,
              fontWeight: AppFontWeights.semibold,
              color: cs.primary,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 13,
              height: 1.45,
              color: cs.onSurface.withValues(alpha: 0.85),
            ),
          ),
        ),
      ],
    );
  }
}
