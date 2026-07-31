import '../../../core/models/assistant.dart';
import '../../../core/models/assistant_detail_injection.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/director_message.dart';
import '../../../core/models/group_chat.dart';
import '../../../core/services/chat/chat_service.dart';

/// Builds director user/system content and roster injection blocks.
class DirectorContextBuilder {
  DirectorContextBuilder({required this.chatService});

  final ChatService chatService;

  static const toolOnlyReminder =
      'Respond only by calling select_speaker or end_turn.';

  /// Tool titles only — shared with private context builder.
  String contentForDirector(ChatMessage message) {
    final body = message.content.trim();
    final events = chatService.getToolEvents(message.id);
    final toolLines = <String>[];
    for (final e in events) {
      final name = (e['name'] ?? e['toolName'] ?? e['tool'] ?? '').toString();
      if (name.isNotEmpty) toolLines.add('[tool: $name]');
    }
    if (toolLines.isEmpty) return body;
    if (body.isEmpty) return toolLines.join('\n');
    return '$body\n${toolLines.join('\n')}';
  }

  String buildRosterBlock(List<Assistant> assistants) {
    final buf = StringBuffer('<assistant_roster>\n');
    for (final a in assistants) {
      final persona = _truncatePersona(a.systemPrompt);
      buf.writeln('- id: ${a.id}');
      buf.writeln('  name: ${a.name}');
      buf.writeln('  persona: |');
      for (final line in persona.split('\n')) {
        buf.writeln('    $line');
      }
    }
    buf.write('</assistant_roster>');
    return buf.toString();
  }

  String _truncatePersona(String raw) {
    final t = raw.trim();
    if (t.runes.length <= 4000) return t;
    return '${String.fromCharCodes(t.runes.take(4000))}\n…[truncated]';
  }

  String substituteVariables(
    String template, {
    required GroupChat group,
    required String userName,
    required List<String> memberNames,
  }) {
    final now = DateTime.now();
    final date =
        '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
    final time =
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}';
    return template
        .replaceAll('{current_hour}', now.hour.toString())
        .replaceAll('{current_date}', date)
        .replaceAll('{current_datetime}', '$date $time')
        .replaceAll('{group_name}', group.name)
        .replaceAll('{member_names}', memberNames.join(', '))
        .replaceAll(
          '{max_assistant_messages_per_round}',
          group.maxAssistantMessagesPerRound.toString(),
        )
        .replaceAll('{user_name}', userName);
  }

  /// E1 — human user message (no pending cap).
  String buildUserTurnE1({
    required String userName,
    required String userMessageText,
  }) {
    return '[$userName]: $userMessageText\n\n'
        '接下来，请选择是否由助手发送下条消息，由哪个助手发送下一条消息。\n'
        '$toolOnlyReminder';
  }

  /// E2 — assistant spoke.
  String buildAssistantTurnE2({
    required String assistantName,
    required String assistantContent,
  }) {
    return '[$assistantName]: $assistantContent\n\n'
        '接下来，请选择由哪个助手发送下一条消息。\n'
        '$toolOnlyReminder';
  }

  /// E3 — cap merge.
  String buildCapMergeE3({
    required String assistantName,
    required String pendingAssistantContent,
    required String userName,
    required String newUserMessageText,
  }) {
    return '[$assistantName]: $pendingAssistantContent\n'
        '[$userName]: $newUserMessageText\n\n'
        '接下来，请选择是否由助手发送下条消息，由哪个助手发送下一条消息。\n'
        '$toolOnlyReminder';
  }

  bool maybeAppendRoster({
    required AssistantDetailInjectionMode mode,
    required int n,
    required bool isHumanUserTurn,
    required bool isFirstHumanUser,
    required int userTurnCount,
    required int directorUserMsgCount,
  }) {
    switch (mode) {
      case AssistantDetailInjectionMode.beforeSystemPrompt:
      case AssistantDetailInjectionMode.appendIntoSystemPrompt:
        return false;
      case AssistantDetailInjectionMode.endOfFirstUserMessage:
        return isHumanUserTurn && isFirstHumanUser;
      case AssistantDetailInjectionMode.endOfEveryUserMessage:
        return isHumanUserTurn;
      case AssistantDetailInjectionMode.endOfEveryUserAndAssistantMessage:
        return true;
      case AssistantDetailInjectionMode.everyNUserMessages:
        return isHumanUserTurn && n > 0 && userTurnCount % n == 0;
      case AssistantDetailInjectionMode.everyNUserAndAssistantMessages:
        return n > 0 && directorUserMsgCount % n == 0;
    }
  }

  /// Count human-user director turns from history (E1/E3 style markers not
  /// required — count role=user messages that look like human turns using
  /// existing rows where content contains the user choose prompt).
  int countHumanUserTurns(List<DirectorMessage> history) {
    return history
        .where((m) => m.role == 'user' && m.content.contains('请选择是否由助手发送下条消息'))
        .length;
  }

  int countDirectorUserMessages(List<DirectorMessage> history) {
    return history.where((m) => m.role == 'user').length;
  }

  /// Build API messages for one director call (system computed live + history
  /// without old system rows + new user content).
  List<Map<String, dynamic>> buildApiMessages({
    required GroupChat group,
    required List<DirectorMessage> history,
    required String newUserContent,
    required List<Assistant> rosterAssistants,
    required String userName,
    required List<String> memberNames,
  }) {
    final roster = buildRosterBlock(rosterAssistants);
    final prompt = substituteVariables(
      group.directorSystemPrompt,
      group: group,
      userName: userName,
      memberNames: memberNames,
    );
    final mode = group.assistantDetailInjectionMode;
    final api = <Map<String, dynamic>>[];

    if (mode == AssistantDetailInjectionMode.beforeSystemPrompt) {
      api.add({'role': 'system', 'content': roster});
      api.add({'role': 'system', 'content': prompt});
    } else if (mode == AssistantDetailInjectionMode.appendIntoSystemPrompt) {
      api.add({'role': 'system', 'content': '$prompt\n\n$roster'});
    } else {
      api.add({'role': 'system', 'content': prompt});
    }

    for (final m in history) {
      if (m.role == 'system') continue;
      api.add({'role': m.role, 'content': m.content});
    }
    api.add({'role': 'user', 'content': newUserContent});
    return api;
  }
}
