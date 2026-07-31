import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/features/group_chat/services/assistant_private_context_builder.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeChatService extends ChatService {
  @override
  List<Map<String, dynamic>> getToolEvents(String messageId) => const [];
}

void main() {
  test('private context rewrites other speakers as prefixed user lines', () {
    final service = _FakeChatService();
    final builder = AssistantPrivateContextBuilder(chatService: service);
    final conv = Conversation(
      id: 'c1',
      title: 'g',
      conversationKind: Conversation.kindGroup,
    );
    final alice = Assistant(id: 'a1', name: 'Alice', systemPrompt: 'A');
    final bob = Assistant(id: 'a2', name: 'Bob', systemPrompt: 'B');

    final public = [
      ChatMessage(
        role: 'user',
        content: 'Hello all',
        conversationId: 'c1',
      ),
      ChatMessage(
        role: 'assistant',
        content: 'Hi from Alice',
        conversationId: 'c1',
        speakerAssistantId: 'a1',
      ),
      ChatMessage(
        role: 'assistant',
        content: 'Hi from Bob',
        conversationId: 'c1',
        speakerAssistantId: 'a2',
      ),
      ChatMessage(
        role: 'user',
        content: 'Continue',
        conversationId: 'c1',
      ),
    ];

    final private = builder.build(
      conversation: conv,
      publicMessages: public,
      speaker: alice,
      userName: 'User',
      assistantsById: {'a1': alice, 'a2': bob},
    );

    // Alice sees her own message as assistant; others as user-prefixed.
    expect(private.any((m) => m.role == 'assistant'), isTrue);
    final userJoined = private
        .where((m) => m.role == 'user')
        .map((m) => m.content)
        .join('\n');
    expect(userJoined, contains('[User]: Hello all'));
    expect(userJoined, contains('[Bob]: Hi from Bob'));
    expect(userJoined, contains('[User]: Continue'));
  });
}
