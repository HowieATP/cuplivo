import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/group_chat.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/features/group_chat/services/director_context_builder.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeChatService extends ChatService {
  @override
  List<Map<String, dynamic>> getToolEvents(String messageId) => const [];
}

void main() {
  test('buildApiMessagesFromPublic emits E1/E2 history and tip', () {
    final service = _FakeChatService();
    final builder = DirectorContextBuilder(chatService: service);
    final alice = Assistant(id: 'a1', name: 'Alice', systemPrompt: 'A');
    final group = GroupChat(
      id: 'g1',
      name: 'Room',
      conversationId: 'c1',
      directorSystemPrompt: 'You are the director.',
    );

    final u1 = ChatMessage(
      role: 'user',
      content: 'Hello',
      conversationId: 'c1',
    );
    final a1 = ChatMessage(
      role: 'assistant',
      content: 'Hi',
      conversationId: 'c1',
      speakerAssistantId: 'a1',
    );
    final u2 = ChatMessage(
      role: 'user',
      content: 'Again',
      conversationId: 'c1',
    );

    final tip = builder.buildUserTurnE1(
      userName: 'User',
      userMessageText: 'Again',
    );

    final api = builder.buildApiMessagesFromPublic(
      group: group,
      publicMessages: [u1, a1, u2],
      versionSelections: const {},
      newUserContent: tip,
      rosterAssistants: [alice],
      userName: 'User',
      memberNames: const ['User', 'Alice'],
      assistantsById: {'a1': alice},
      excludeTrailingUserMessageId: u2.id,
    );

    expect(api.first['role'], 'system');
    expect(api.last['content'], tip);
    final userContents = api
        .where((m) => m['role'] == 'user')
        .map((m) => m['content'] as String)
        .toList();
    expect(userContents.length, 3); // E1 history, E2, tip
    expect(userContents[0], contains('请选择是否由助手发送下条消息'));
    expect(userContents[0], contains('[User]: Hello'));
    expect(userContents[1], contains('[Alice]: Hi'));
    expect(userContents[1], contains('请选择由哪个助手发送下一条消息'));
  });

  test('collapsePublicVersions uses index default last', () {
    final service = _FakeChatService();
    final builder = DirectorContextBuilder(chatService: service);
    final gid = 'g';
    final v0 = ChatMessage(
      id: 'm0',
      role: 'assistant',
      content: 'v0',
      conversationId: 'c1',
      groupId: gid,
      version: 0,
    );
    final v1 = ChatMessage(
      id: 'm1',
      role: 'assistant',
      content: 'v1',
      conversationId: 'c1',
      groupId: gid,
      version: 1,
    );
    final collapsed = builder.collapsePublicVersions([v0, v1], const {});
    expect(collapsed.single.content, 'v1');
    final picked = builder.collapsePublicVersions([v0, v1], {gid: 0});
    expect(picked.single.content, 'v0');
  });
}
