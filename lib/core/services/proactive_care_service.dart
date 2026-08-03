import '../models/assistant_memory.dart';

/// Pure logic for the proactive care ("Ta的来信") decision flow.
///
/// After each completed assistant reply, the full conversation context plus
/// the decision prompt built here is sent silently to the decision model.
/// The model answers by calling one of the decision tools
/// (`update_care_time` / `keep_care_time`); see
/// `ProactiveCareDecisionTools`.
class ProactiveCareService {
  /// Built-in tool-only reminder appended to the final user message of the
  /// decision request (LLM only). Mirrors DirectorContextBuilder's
  /// tool-only reminder.
  static const String builtinDecisionToolReminder =
      '请只通过调用工具给出决策：需要修改时间时调用 update_care_time，'
      '保持不变时调用 keep_care_time。不要输出其他内容。';

  /// Prefix before the assistant persona in the decision request (LLM only).
  static const String personaReferencePrefix = '以下是供你参考的助手人设';

  /// Prefix before the memory block in the decision request (LLM only).
  static const String memoriesReferencePrefix = '以下是供你参考的助手记忆';

  /// Prefix inserted as a separate user message before chat history (LLM only).
  static const String chatHistoryPrefix = '以下是用户与助手的聊天记录';

  /// Built-in suffix appended to the user-configured care prompt when the
  /// proactive care time arrives (LLM only, never shown in UI).
  static const String builtinCareTimePrompt = '当前系统时间：{current_system_time}';

  /// Builds the time footer placed after chat history in the decision request.
  static String buildDecisionTimeFooter({
    required DateTime now,
    required DateTime? currentNextCareTime,
  }) {
    return '''
当前已设定的下次主动关怀时间：${currentNextCareTime?.toIso8601String() ?? '未设定'}
当前系统时间：${now.toIso8601String()}'''
        .trim();
  }

  /// Assembles the full silent decision API message list (Pipeline ①):
  ///
  /// 1. `system`: user decision prompt (when non-empty)
  /// 2. `user` (optional): persona reference prefix + assistant system prompt
  /// 3. `user` (optional): memories reference prefix + memory block
  /// 4. `user`: chat history header (when [history] is non-empty)
  /// 5. ...[history] (user/assistant turns, unchanged)
  /// 6. `user`: next care time + current system time + tool reminder
  ///    (always last)
  static List<Map<String, dynamic>> buildDecisionApiMessages({
    required String decisionPrompt,
    required DateTime? currentNextCareTime,
    required DateTime now,
    required List<Map<String, dynamic>> history,
    String personaPrompt = '',
    String memoriesBlock = '',
  }) {
    final messages = <Map<String, dynamic>>[];

    final prompt = decisionPrompt.trim();
    if (prompt.isNotEmpty) {
      messages.add({'role': 'system', 'content': prompt});
    }

    final persona = personaPrompt.trim();
    if (persona.isNotEmpty) {
      messages.add({
        'role': 'user',
        'content': '$personaReferencePrefix\n\n$persona',
      });
    }

    final memories = memoriesBlock.trim();
    if (memories.isNotEmpty) {
      messages.add({
        'role': 'user',
        'content': '$memoriesReferencePrefix\n\n$memories',
      });
    }

    if (history.isNotEmpty) {
      messages.add({'role': 'user', 'content': chatHistoryPrefix});
      messages.addAll(history);
    }

    messages.add({
      'role': 'user',
      'content':
          '${buildDecisionTimeFooter(now: now, currentNextCareTime: currentNextCareTime)}'
          '\n\n$builtinDecisionToolReminder',
    });

    return messages;
  }

  /// Formats assistant memories the same way as the normal send pipeline's
  /// `<memories>` block, but without the memory tool instructions (the
  /// silent requests carry no tools). Returns an empty string when there are
  /// no memories.
  static String buildMemoriesBlock(List<AssistantMemory> mems) {
    if (mems.isEmpty) return '';
    final buf = StringBuffer();
    buf.writeln('## Memories');
    buf.writeln(
      'These are memories that you can reference in the future conversations.',
    );
    buf.writeln('<memories>');
    for (final m in mems) {
      buf.writeln('<record>');
      buf.writeln('<id>${m.id}</id>');
      buf.writeln('<content>${m.content}</content>');
      buf.writeln('</record>');
    }
    buf.writeln('</memories>');
    return buf.toString().trim();
  }

  /// Builds the silent user-role message sent when the proactive care time
  /// arrives: the user-configured care prompt plus the current system time.
  static String buildCareUserMessage({
    required String carePrompt,
    required DateTime now,
  }) {
    final time = builtinCareTimePrompt.replaceAll(
      '{current_system_time}',
      now.toIso8601String(),
    );
    final head = carePrompt.trim();
    if (head.isEmpty) return time;
    return '$head\n\n$time';
  }
}
