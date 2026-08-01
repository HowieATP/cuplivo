import 'package:flutter/material.dart';

import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tactile.dart';

class GroupChatDirectorLogsPage extends StatelessWidget {
  const GroupChatDirectorLogsPage({super.key, required this.groupChatId});
  final String groupChatId;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        leading: IosIconButton(
          icon: Lucide.ArrowLeft,
          color: cs.onSurface,
          size: 22,
          onTap: () => Navigator.of(context).maybePop(),
        ),
        title: Text(l10n.groupChatDirectorLogs),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            l10n.groupChatDirectorLogsEphemeral,
            textAlign: TextAlign.center,
            style: TextStyle(color: cs.onSurface.withValues(alpha: 0.6)),
          ),
        ),
      ),
    );
  }
}
