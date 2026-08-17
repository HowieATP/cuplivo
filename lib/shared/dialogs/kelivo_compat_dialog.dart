import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_localizations.dart';
import '../../core/services/backup/kelivo_v2_exception.dart';

/// Returns `true` when [error] is a [KelivoV2BackupException] and a compat
/// dialog was shown. Otherwise returns `false` and the caller should treat
/// [error] as a normal restore failure.
///
/// Every restore catch site (local import + WebDAV/S3 remote restore) calls
/// this first so a Kelivo v2 backup redirects to the kelivo-helper compat
/// page instead of being reported as a generic import failure.
Future<bool> maybeShowKelivoCompatError(
  BuildContext context,
  Object error,
) async {
  if (error is! KelivoV2BackupException) return false;
  if (!context.mounted) return true;
  await showKelivoCompatDialog(context);
  return true;
}

/// Explains that the selected file is an upstream Kelivo v2 backup that this
/// build cannot import, and opens the kelivo-helper compat page so the user
/// can downgrade it first.
Future<void> showKelivoCompatDialog(BuildContext context) {
  final l10n = AppLocalizations.of(context)!;
  final cs = Theme.of(context).colorScheme;
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      backgroundColor: cs.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(l10n.backupPageKelivoCompatTitle),
      content: Text(l10n.backupPageKelivoCompatContent),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(l10n.backupPageCancel),
        ),
        FilledButton.icon(
          onPressed: () => _openCompatUrl(l10n.backupPageKelivoCompatUrl),
          icon: const Icon(Icons.open_in_new, size: 16),
          label: Text(l10n.backupPageKelivoCompatOpen),
        ),
      ],
    ),
  );
}

Future<void> _openCompatUrl(String url) async {
  final uri = Uri.parse(url);
  try {
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      await launchUrl(uri, mode: LaunchMode.platformDefault);
    }
  } catch (_) {
    await launchUrl(uri);
  }
}
