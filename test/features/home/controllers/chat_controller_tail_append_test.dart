import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/features/home/controllers/chat_controller.dart';

class _FakeTailChatService extends ChatService {
  _FakeTailChatService(this._messages);

  final List<ChatMessage> _messages;

  @override
  int getMessageCount(String conversationId) => _messages.length;

  @override
  List<ChatMessage> getRecentMessages(
    String conversationId, {
    int minMessages = ChatService.defaultInitialMessageMin,
    int textBudget = ChatService.defaultInitialTextBudget,
    int maxMessages = ChatService.defaultInitialMessageMax,
  }) {
    final start = (_messages.length - minMessages).clamp(0, _messages.length);
    return _messages.sublist(start);
  }

  @override
  List<ChatMessage> getMessagesRange(
    String conversationId, {
    required int start,
    required int limit,
  }) {
    final end = (start + limit).clamp(0, _messages.length);
    return _messages.sublist(start, end);
  }

  @override
  Map<String, int> getVersionSelections(String conversationId) =>
      const <String, int>{};
}

ChatMessage _message(String id, String role, {bool isStreaming = false}) {
  return ChatMessage(
    id: id,
    role: role,
    content: 'content-$id',
    conversationId: 'conversation-1',
    isStreaming: isStreaming,
  );
}

void main() {
  group('ChatController reload after tail append', () {
    late List<ChatMessage> messages;
    late ChatController controller;

    void openConversation(int count) {
      messages = List<ChatMessage>.generate(count, _messageIndexed);
      controller.dispose();
      controller = ChatController(chatService: _FakeTailChatService(messages));
      controller.setCurrentConversation(
        Conversation(
          id: 'conversation-1',
          title: 'Group chat',
          messageIds: messages.map((message) => message.id).toList(),
        ),
      );
    }

    setUp(() {
      messages = <ChatMessage>[
        _message('user-1', 'user'),
        _message('assistant-1', 'assistant'),
      ];
      controller = ChatController(chatService: _FakeTailChatService(messages));
      controller.setCurrentConversation(
        Conversation(
          id: 'conversation-1',
          title: 'Group chat',
          messageIds: messages.map((message) => message.id).toList(),
        ),
      );
    });

    tearDown(() {
      controller.dispose();
    });

    test('reload after ChatService append re-anchors the tail window so new '
        'messages are visible (group chat refresh)', () {
      // Group chat writes user message + streaming placeholder straight to
      // ChatService; the page then refreshes its window from storage.
      messages.add(_message('user-2', 'user'));
      messages.add(_message('assistant-2', 'assistant', isStreaming: true));

      controller.reloadMessages();

      expect(
        controller.messages.map((message) => message.id),
        containsAll(<String>['user-2', 'assistant-2']),
      );
      expect(controller.messages.last.isStreaming, isTrue);
    });

    test('reload keeps a mid-history window anchored', () {
      openConversation(500);
      controller.loadStartWindow();

      final before = controller.messages.first.id;
      final beforeStart = controller.loadedStartIndex;

      messages.add(_message('user-500', 'user'));
      controller.reloadMessages();

      expect(controller.loadedStartIndex, beforeStart);
      expect(controller.messages.first.id, before);
      expect(
        controller.messages.map((message) => message.id),
        isNot(contains('user-500')),
      );
    });
  });
}

ChatMessage _messageIndexed(int index) {
  return _message('message-$index', index.isEven ? 'user' : 'assistant');
}
