import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/director_message.dart';
import '../../../core/providers/group_chat_provider.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../theme/app_font_weights.dart';

class GroupChatDirectorLogsPage extends StatefulWidget {
  const GroupChatDirectorLogsPage({super.key, required this.groupChatId});
  final String groupChatId;

  @override
  State<GroupChatDirectorLogsPage> createState() =>
      _GroupChatDirectorLogsPageState();
}

class _GroupChatDirectorLogsPageState extends State<GroupChatDirectorLogsPage> {
  late Future<List<DirectorMessage>> _future;

  @override
  void initState() {
    super.initState();
    _future = context.read<GroupChatProvider>().directorMessages(
      widget.groupChatId,
    );
  }

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
      body: FutureBuilder<List<DirectorMessage>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final messages = snap.data ?? const [];
          if (messages.isEmpty) {
            return Center(
              child: Text(
                l10n.groupChatDirectorLogsEmpty,
                style: TextStyle(color: cs.onSurface.withValues(alpha: 0.6)),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 40),
            itemCount: messages.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final m = messages[index];
              return Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color: cs.surfaceContainerHighest.withValues(alpha: 0.35),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '#${m.messageOrder}  ${m.role}',
                      style: TextStyle(
                        fontWeight: AppFontWeights.emphasis,
                        color: cs.primary,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 6),
                    SelectableText(
                      m.content,
                      style: const TextStyle(fontSize: 13, height: 1.35),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}
