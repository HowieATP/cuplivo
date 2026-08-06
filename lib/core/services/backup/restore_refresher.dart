import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../providers/assistant_provider.dart';
import '../../providers/group_chat_provider.dart';
import '../../providers/mcp_provider.dart';
import '../chat/chat_service.dart';

/// Re-reads every provider that mirrors persisted state after a restore /
/// import rewrote SQLite or SharedPreferences, so the UI does not keep a
/// cleared or pre-restore in-memory snapshot.
///
/// Single shared refresh list for all restore entry points (mobile backup
/// page, desktop backup pane, LAN sync). Any new provider that persists state
/// must subscribe here; adding reloads at individual call sites is what let
/// the refresh list drift out of sync before.
Future<void> refreshProvidersAfterRestore(BuildContext context) async {
  final chatService = context.read<ChatService>();
  final assistantProvider = context.read<AssistantProvider>();
  final groupChatProvider = context.read<GroupChatProvider>();
  final mcpProvider = context.read<McpProvider>();
  try {
    await chatService.reloadCachesFromDb();
  } catch (e) {
    debugPrint('refreshProvidersAfterRestore: ChatService: $e');
  }
  try {
    // Reload MCP BEFORE assistants: reloading assistants fires
    // McpProvider._onAssistantsChanged -> refreshTools('kelivo_subagent'),
    // which persists the whole server list. If the old client were still
    // live at that point it would write the pre-restore list over the
    // restored mcp_servers_v1; reloading MCP first means any such refresh
    // runs against the new client (or no client) and stays harmless.
    await mcpProvider.reloadFromPrefs();
  } catch (e) {
    debugPrint('refreshProvidersAfterRestore: McpProvider: $e');
  }
  try {
    await assistantProvider.reloadFromRepo();
  } catch (e) {
    debugPrint('refreshProvidersAfterRestore: AssistantProvider: $e');
  }
  try {
    await groupChatProvider.load();
  } catch (e) {
    debugPrint('refreshProvidersAfterRestore: GroupChatProvider: $e');
  }
}
