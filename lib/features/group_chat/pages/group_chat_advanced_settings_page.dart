import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/assistant_detail_injection.dart';
import '../../../core/models/group_chat.dart';
import '../../../core/providers/group_chat_provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_form_text_field.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../theme/app_font_weights.dart';
import '../../model/widgets/model_select_sheet.dart';

class GroupChatAdvancedSettingsPage extends StatefulWidget {
  const GroupChatAdvancedSettingsPage({super.key, required this.groupChatId});
  final String groupChatId;

  @override
  State<GroupChatAdvancedSettingsPage> createState() =>
      _GroupChatAdvancedSettingsPageState();
}

class _GroupChatAdvancedSettingsPageState
    extends State<GroupChatAdvancedSettingsPage> {
  late TextEditingController _promptCtrl;
  late TextEditingController _maxCtrl;
  late TextEditingController _nCtrl;

  @override
  void initState() {
    super.initState();
    final g = context.read<GroupChatProvider>().getById(widget.groupChatId);
    _promptCtrl = TextEditingController(
      text: g?.directorSystemPrompt ?? GroupChat.defaultDirectorSystemPrompt,
    );
    _maxCtrl = TextEditingController(
      text: (g?.maxAssistantMessagesPerRound ?? 3).toString(),
    );
    _nCtrl = TextEditingController(
      text: (g?.assistantDetailInjectionN ?? 5).toString(),
    );
  }

  @override
  void dispose() {
    _promptCtrl.dispose();
    _maxCtrl.dispose();
    _nCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final gp = context.watch<GroupChatProvider>();
    final settings = context.watch<SettingsProvider>();
    final group = gp.getById(widget.groupChatId);
    if (group == null) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.groupChatAdvancedSettings)),
        body: Center(child: Text(l10n.groupChatNotFound)),
      );
    }

    final modelLabel =
        (group.directorModelProvider == null || group.directorModelId == null)
        ? l10n.groupChatDirectorModelFollowGlobal
        : '${group.directorModelProvider}/${group.directorModelId}';

    return Scaffold(
      appBar: AppBar(
        leading: IosIconButton(
          icon: Lucide.ArrowLeft,
          color: cs.onSurface,
          size: 22,
          onTap: () => Navigator.of(context).maybePop(),
        ),
        title: Text(l10n.groupChatAdvancedSettings),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
        children: [
          Text(
            l10n.groupChatDirectorModel,
            style: TextStyle(fontWeight: AppFontWeights.emphasis),
          ),
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(modelLabel),
            trailing: const Icon(Lucide.ChevronRight, size: 18),
            onTap: () async {
              final selected = await showModelSelector(context);
              if (selected == null || !context.mounted) return;
              if (selected.providerKey.isEmpty || selected.modelId.isEmpty) {
                await gp.updateGroup(group.copyWith(clearDirectorModel: true));
              } else {
                await gp.updateGroup(
                  group.copyWith(
                    directorModelProvider: selected.providerKey,
                    directorModelId: selected.modelId,
                  ),
                );
              }
            },
          ),
          TextButton(
            onPressed: () async {
              await gp.updateGroup(group.copyWith(clearDirectorModel: true));
            },
            child: Text(l10n.groupChatDirectorModelClear),
          ),
          const SizedBox(height: 16),
          IosFormTextField(
            label: l10n.groupChatDirectorSystemPrompt,
            controller: _promptCtrl,
            maxLines: 12,
            minLines: 6,
            onChanged: (v) async {
              await gp.updateGroup(group.copyWith(directorSystemPrompt: v));
            },
          ),
          const SizedBox(height: 8),
          Text(
            l10n.groupChatAvailableVariables,
            style: TextStyle(
              fontSize: 12,
              color: cs.onSurface.withValues(alpha: 0.6),
            ),
          ),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: GroupChat.directorPromptVariables
                .map(
                  (v) => ActionChip(
                    label: Text(v, style: const TextStyle(fontSize: 11)),
                    onPressed: () {
                      final t = _promptCtrl.text;
                      _promptCtrl.text = '$t$v';
                      _promptCtrl.selection = TextSelection.collapsed(
                        offset: _promptCtrl.text.length,
                      );
                      gp.updateGroup(
                        group.copyWith(directorSystemPrompt: _promptCtrl.text),
                      );
                    },
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 16),
          IosFormTextField(
            label: l10n.groupChatMaxAssistantMessages,
            controller: _maxCtrl,
            keyboardType: TextInputType.number,
            onChanged: (v) async {
              final n = int.tryParse(v) ?? 3;
              await gp.updateGroup(
                group.copyWith(maxAssistantMessagesPerRound: n.clamp(1, 20)),
              );
            },
          ),
          const SizedBox(height: 16),
          Text(
            l10n.groupChatInjectionMode,
            style: TextStyle(fontWeight: AppFontWeights.emphasis),
          ),
          const SizedBox(height: 8),
          ...AssistantDetailInjectionMode.values.map((mode) {
            final selected = group.assistantDetailInjectionMode == mode;
            return ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                selected ? Lucide.Check : Lucide.ChevronRight,
                size: 18,
                color: selected
                    ? cs.primary
                    : cs.onSurface.withValues(alpha: 0.35),
              ),
              title: Text(
                _modeLabel(l10n, mode),
                style: const TextStyle(fontSize: 14),
              ),
              onTap: () async {
                await gp.updateGroup(
                  group.copyWith(assistantDetailInjectionMode: mode),
                );
              },
            );
          }),
          if (group.assistantDetailInjectionMode.needsN) ...[
            const SizedBox(height: 8),
            IosFormTextField(
              label: l10n.groupChatInjectionN,
              controller: _nCtrl,
              keyboardType: TextInputType.number,
              onChanged: (v) async {
                final n = int.tryParse(v) ?? 5;
                await gp.updateGroup(
                  group.copyWith(assistantDetailInjectionN: n.clamp(1, 100)),
                );
              },
            ),
          ],
          const SizedBox(height: 12),
          Text(
            '${l10n.groupChatDirectorModelFollowGlobal}: '
            '${settings.currentModelProvider}/${settings.currentModelId}',
            style: TextStyle(
              fontSize: 12,
              color: cs.onSurface.withValues(alpha: 0.55),
            ),
          ),
        ],
      ),
    );
  }

  String _modeLabel(AppLocalizations l10n, AssistantDetailInjectionMode mode) {
    switch (mode) {
      case AssistantDetailInjectionMode.beforeSystemPrompt:
        return l10n.groupChatInjectionBeforeSystem;
      case AssistantDetailInjectionMode.appendIntoSystemPrompt:
        return l10n.groupChatInjectionAppendSystem;
      case AssistantDetailInjectionMode.endOfFirstUserMessage:
        return l10n.groupChatInjectionEndFirstUser;
      case AssistantDetailInjectionMode.endOfEveryUserMessage:
        return l10n.groupChatInjectionEndEveryUser;
      case AssistantDetailInjectionMode.endOfEveryUserAndAssistantMessage:
        return l10n.groupChatInjectionEndEveryUserAndAssistant;
      case AssistantDetailInjectionMode.everyNUserMessages:
        return l10n.groupChatInjectionEveryNUser;
      case AssistantDetailInjectionMode.everyNUserAndAssistantMessages:
        return l10n.groupChatInjectionEveryNUserAndAssistant;
    }
  }
}
