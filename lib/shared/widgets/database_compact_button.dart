import 'package:flutter/material.dart';

import '../../core/database/chat_database_repository.dart';
import '../../icons/lucide_adapter.dart';
import '../../l10n/app_localizations.dart';
import '../../utils/format.dart';
import 'ios_tile_button.dart';
import 'snackbar.dart';

/// A two-tap guarded button that manually compacts the SQLite database to
/// reclaim freelist pages left by soft-deletes / trash evictions.
///
/// First tap arms the button ("tap again to confirm"), the second tap runs
/// [compact]. After completion a snackbar shows the size reduction, or a
/// "nothing to reclaim" message when the file did not shrink. [onDone] lets
/// the caller refresh its storage report afterwards.
class DatabaseCompactButton extends StatefulWidget {
  const DatabaseCompactButton({super.key, required this.compact, this.onDone});

  final Future<DbCompactResult> Function() compact;
  final Future<void> Function()? onDone;

  @override
  State<DatabaseCompactButton> createState() => _DatabaseCompactButtonState();
}

class _DatabaseCompactButtonState extends State<DatabaseCompactButton> {
  bool _confirming = false;
  bool _running = false;

  Future<void> _onTap() async {
    if (_running) return;
    final l10n = AppLocalizations.of(context)!;
    if (!_confirming) {
      setState(() => _confirming = true);
      return;
    }
    setState(() {
      _confirming = false;
      _running = true;
    });
    try {
      final result = await widget.compact();
      if (!mounted) return;
      final l10n = AppLocalizations.of(context)!;
      if (result.savedBytes > 0) {
        final pct = result.beforeBytes > 0
            ? (result.savedBytes * 100 / result.beforeBytes).round()
            : 0;
        showAppSnackBar(
          context,
          message: l10n.storageSpaceCompactDbResult(
            formatBytes(result.afterBytes),
            formatBytes(result.beforeBytes),
            '$pct',
            formatBytes(result.savedBytes),
          ),
          type: NotificationType.success,
        );
      } else {
        showAppSnackBar(
          context,
          message: l10n.storageSpaceCompactDbNone,
          type: NotificationType.info,
        );
      }
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: l10n.storageSpaceCompactDbFailed(e.toString()),
        type: NotificationType.error,
      );
      return;
    } finally {
      if (mounted) setState(() => _running = false);
    }
    // Refresh the caller's report only on success, outside the compaction
    // try/catch so a refresh failure is not mislabeled as "compact failed".
    if (mounted) {
      try {
        await widget.onDone?.call();
      } catch (e) {
        debugPrint('DatabaseCompactButton: onDone refresh failed: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final String label;
    if (_running) {
      label = l10n.storageSpaceCompactDbRunning;
    } else if (_confirming) {
      label = l10n.storageSpaceCompactDbConfirmPrompt;
    } else {
      label = l10n.storageSpaceCompactDbButton;
    }
    return IosTileButton(
      label: label,
      icon: _running ? Icons.hourglass_empty : Lucide.Database,
      backgroundColor: cs.primary,
      enabled: !_running,
      onTap: _onTap,
    );
  }
}
