import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/features/home/controllers/chat_controller.dart';

ChatMessage _message({
  required String id,
  required String groupId,
  required int version,
  String content = 'answer',
}) {
  return ChatMessage(
    id: id,
    role: 'assistant',
    content: content,
    conversationId: 'conversation-1',
    groupId: groupId,
    version: version,
  );
}

void main() {
  group('ChatController.collapseWithSelections', () {
    test('picks the persisted selected version per group', () {
      final messages = [
        _message(id: 'g1-v0', groupId: 'g1', version: 0, content: 'v0'),
        _message(id: 'g1-v1', groupId: 'g1', version: 1, content: 'v1'),
      ];

      final collapsed = ChatController.collapseWithSelections(messages, const {
        'g1': 0,
      });

      expect(collapsed, hasLength(1));
      expect(collapsed.single.id, 'g1-v0');
    });

    test('falls back to the latest version without a selection', () {
      final messages = [
        _message(id: 'g1-v0', groupId: 'g1', version: 0, content: 'v0'),
        _message(id: 'g1-v1', groupId: 'g1', version: 1, content: 'v1'),
      ];

      final collapsed = ChatController.collapseWithSelections(
        messages,
        const <String, int>{},
      );

      expect(collapsed, hasLength(1));
      expect(collapsed.single.id, 'g1-v1');
    });

    test(
      'falls back to the latest version when the selection is out of range',
      () {
        final messages = [
          _message(id: 'g1-v0', groupId: 'g1', version: 0, content: 'v0'),
          _message(id: 'g1-v1', groupId: 'g1', version: 1, content: 'v1'),
        ];

        final collapsed = ChatController.collapseWithSelections(
          messages,
          const {'g1': 7},
        );

        expect(collapsed.single.id, 'g1-v1');
      },
    );

    test('groups by groupId and preserves message order', () {
      final messages = [
        _message(id: 'u1', groupId: 'u1', version: 0, content: 'q'),
        _message(id: 'g1-v1', groupId: 'g1', version: 1, content: 'v1'),
        _message(id: 'g1-v0', groupId: 'g1', version: 0, content: 'v0'),
        _message(id: 'u2', groupId: 'u2', version: 0, content: 'q2'),
      ];

      final collapsed = ChatController.collapseWithSelections(
        messages,
        const <String, int>{},
      );

      expect(collapsed.map((m) => m.id), ['u1', 'g1-v1', 'u2']);
    });
  });
}
