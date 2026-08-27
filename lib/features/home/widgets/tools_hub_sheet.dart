import 'package:flutter/material.dart';

import 'tools_hub_content.dart';

/// Shows the Tools Hub bottom sheet for the given assistant.
Future<void> showToolsHubSheet(
  BuildContext context, {
  required String assistantId,
  required String? conversationId,
}) async {
  final cs = Theme.of(context).colorScheme;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: cs.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _ToolsHubSheet(
      assistantId: assistantId,
      conversationId: conversationId,
    ),
  );
}

class _ToolsHubSheet extends StatelessWidget {
  const _ToolsHubSheet({
    required this.assistantId,
    required this.conversationId,
  });

  final String assistantId;
  final String? conversationId;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final maxHeight = MediaQuery.of(context).size.height * 0.8;

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 8),
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
              const SizedBox(height: 6),
              ToolsHubContent(
                assistantId: assistantId,
                conversationId: conversationId,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
