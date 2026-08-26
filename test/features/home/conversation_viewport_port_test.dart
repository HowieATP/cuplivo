import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/features/home/controllers/conversation_viewport_port.dart';

void main() {
  test(
    'Web viewport port reports metrics and routes navigation commands',
    () async {
      final commands = <Map<String, dynamic>>[];
      final port = WebConversationViewportPort()
        ..attach((command) async => commands.add(command))
        ..updateMetrics(<String, dynamic>{
          'conversationId': 'conversation-a',
          'pixels': 944,
          'maxExtent': 1000,
          'isUserScrolling': false,
          'anchorMessageId': 'm9',
          'anchorOffset': 4.5,
        });

      expect(port.isNearBottom(), isTrue);
      expect(port.hasEnoughContentToScroll(), isTrue);
      expect((await port.captureAnchor())?.messageId, 'm9');
      expect(port.savedAnchorForConversation('conversation-a')?.offset, 4.5);

      port.scrollToTop(animate: false);
      await port.scrollToMessageId(targetId: 'm3', targetIndex: 3);
      port.onStreamTick();
      await Future<void>.delayed(Duration.zero);

      expect(commands.first['command'], 'top');
      expect(commands.last['command'], 'message');
      expect((commands.last['payload'] as Map)['messageId'], 'm3');
      expect(
        commands.where((command) => command['command'] == 'bottom'),
        isEmpty,
      );
    },
  );

  test('Web viewport keeps independent anchors for each conversation', () {
    final port = WebConversationViewportPort()
      ..activateConversation('conversation-a')
      ..updateMetrics(<String, dynamic>{
        'conversationId': 'conversation-a',
        'pixels': 100,
        'maxExtent': 900,
        'anchorMessageId': 'a4',
        'anchorOffset': -12,
      });
    port
      ..activateConversation('conversation-b')
      // A delayed metric may update A's cache, but must not become B's active
      // anchor or scroll state.
      ..updateMetrics(<String, dynamic>{
        'conversationId': 'conversation-a',
        'pixels': 140,
        'maxExtent': 920,
        'isUserScrolling': true,
        'anchorMessageId': 'a5',
        'anchorOffset': -4,
      })
      ..updateMetrics(<String, dynamic>{
        'conversationId': 'conversation-b',
        'pixels': 200,
        'maxExtent': 1000,
        'anchorMessageId': 'b8',
        'anchorOffset': 6,
      });

    expect(port.savedAnchorForConversation('conversation-a')?.messageId, 'a5');
    expect(port.savedAnchorForConversation('conversation-a')?.offset, -4);
    expect(port.savedAnchorForConversation('conversation-b')?.messageId, 'b8');
    expect(port.savedAnchorForConversation('conversation-b')?.offset, 6);
    expect(port.isUserScrolling, isFalse);
    expect((port.captureAnchor()), completion(isNotNull));

    port.updateMetrics(<String, dynamic>{
      'conversationId': 'conversation-b',
      'pixels': 0,
      'maxExtent': 0,
      'anchorMessageId': null,
    });

    expect(port.savedAnchorForConversation('conversation-a'), isNotNull);
    expect(port.savedAnchorForConversation('conversation-b'), isNull);
  });

  test(
    'Web viewport reset and lifecycle commands keep the active tail pinned',
    () async {
      final commands = <Map<String, dynamic>>[];
      final port = WebConversationViewportPort()
        ..attach((command) async => commands.add(command))
        ..activateConversation('conversation-a')
        ..handleUserScrollIntent();

      expect(port.isUserScrolling, isTrue);
      port
        ..resetUserScrolling()
        ..onStreamTick()
        ..stickToBottomAfterGeneration();
      await Future<void>.delayed(Duration.zero);

      expect(port.isUserScrolling, isFalse);
      expect(commands.map((command) => command['command']), contains('bottom'));
      expect(
        commands.map((command) => command['command']),
        contains('holdBottom'),
      );
    },
  );
}
