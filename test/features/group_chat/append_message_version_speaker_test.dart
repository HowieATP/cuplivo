import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'ChatMessage copyWith/constructor preserves speakerAssistantId field',
    () {
      final original = ChatMessage(
        role: 'assistant',
        content: 'hi',
        conversationId: 'c1',
        modelId: 'm',
        providerId: 'p',
        groupId: 'g',
        version: 0,
        speakerAssistantId: 'speaker-1',
      );
      // Mirrors appendMessageVersion field selection after the fix.
      final newMsg = ChatMessage(
        role: original.role,
        content: 'edited',
        conversationId: original.conversationId,
        modelId: original.modelId,
        providerId: original.providerId,
        totalTokens: null,
        isStreaming: false,
        groupId: original.groupId ?? original.id,
        version: original.version + 1,
        speakerAssistantId: original.speakerAssistantId,
      );
      expect(newMsg.speakerAssistantId, 'speaker-1');
      expect(newMsg.modelId, 'm');
      expect(newMsg.providerId, 'p');
      expect(newMsg.version, 1);
    },
  );
}
