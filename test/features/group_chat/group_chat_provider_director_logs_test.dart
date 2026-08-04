import 'package:Cuplivo/core/models/group_chat_director_log.dart';
import 'package:Cuplivo/core/providers/group_chat_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  GroupChatDirectorRuntimeLog log(int index) {
    final finishedAt = DateTime(2026, 1, 1).add(Duration(minutes: index));
    return GroupChatDirectorRuntimeLog(
      sourceMessageId: 'message-$index',
      trigger: GroupChatDirectorLogTrigger.user,
      startedAt: finishedAt,
      finishedAt: finishedAt,
      providerKey: 'provider',
      modelId: 'model',
      requestMessageCount: 1,
      attemptCount: 1,
      attemptErrors: const [],
    );
  }

  test('runtime logs are kept in memory and capped per group', () {
    final provider = GroupChatProvider(chatService: ChatService());

    for (
      var i = 0;
      i <= GroupChatProvider.maxRuntimeDirectorLogsPerGroup;
      i++
    ) {
      provider.recordDirectorRuntimeLog('group-1', log(i));
    }

    final logs = provider.directorRuntimeLogs('group-1');
    expect(logs, hasLength(GroupChatProvider.maxRuntimeDirectorLogsPerGroup));
    expect(logs.first.sourceMessageId, 'message-1');
    expect(logs.last.sourceMessageId, 'message-200');
    expect(() => logs.add(log(201)), throwsUnsupportedError);
    expect(provider.directorRuntimeLogs('other-group'), isEmpty);
  });
}
