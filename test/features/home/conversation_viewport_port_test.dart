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
          'pixels': 944,
          'maxExtent': 1000,
          'isUserScrolling': false,
          'anchorMessageId': 'm9',
          'anchorOffset': 4.5,
        });

      expect(port.isNearBottom(), isTrue);
      expect(port.hasEnoughContentToScroll(), isTrue);
      expect((await port.captureAnchor())?.messageId, 'm9');

      port.scrollToTop(animate: false);
      await port.scrollToMessageId(targetId: 'm3', targetIndex: 3);
      await Future<void>.delayed(Duration.zero);

      expect(commands.first['command'], 'top');
      expect(commands.last['command'], 'message');
      expect((commands.last['payload'] as Map)['messageId'], 'm3');
    },
  );
}
