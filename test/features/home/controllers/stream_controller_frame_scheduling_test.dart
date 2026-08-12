import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/features/home/controllers/stream_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues(const {});

  StreamController buildController({
    String? currentConversationId = 'conversation-1',
    VoidCallback? onStreamTick,
  }) {
    final settings = SettingsProvider();
    return StreamController(
      chatService: ChatService(),
      onStateChanged: () {},
      getSettingsProvider: () => settings,
      getCurrentConversationId: () => currentConversationId,
      onStreamTick: onStreamTick,
    );
  }

  List<String> listenTo(StreamController controller, String messageId) {
    final updates = <String>[];
    controller.streamingContentNotifier.getNotifier(messageId).addListener(() {
      updates.add(
        controller.streamingContentNotifier
            .getNotifier(messageId)
            .value
            .content,
      );
    });
    return updates;
  }

  testWidgets('publishes at most once per displayed frame', (tester) async {
    final controller = buildController();
    final updates = listenTo(controller, 'm1');

    controller.scheduleThrottledUpdate(
      'm1',
      'conversation-1',
      'a' * 5000,
      totalTokens: 5000,
      updateMessageInList: (_, __, ___) {},
    );

    // One frame may publish at most one slice.
    await tester.pump();
    expect(updates, hasLength(1));

    await tester.pump();
    expect(updates, hasLength(2));
    controller.dispose();
  });

  testWidgets('stops scheduling once the backlog is caught up', (tester) async {
    final controller = buildController();
    final updates = listenTo(controller, 'm1');

    controller.scheduleThrottledUpdate(
      'm1',
      'conversation-1',
      'short-content',
      totalTokens: 13,
      updateMessageInList: (_, __, ___) {},
    );

    // The smooth slicer paces output by backlog size, so catch-up takes a
    // few frames.
    await tester.pump();
    expect(updates, hasLength(1));
    for (var i = 0; i < 20 && updates.last != 'short-content'; i++) {
      await tester.pump();
    }
    expect(updates.last, 'short-content');
    final caughtUpCount = updates.length;

    // Idle frames must not produce further notifications.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
    expect(updates, hasLength(caughtUpCount));
    controller.dispose();
  });

  testWidgets('backgrounding cancels pending frame work, resume re-arms', (
    tester,
  ) async {
    final controller = buildController();
    final updates = listenTo(controller, 'm1');

    controller.scheduleThrottledUpdate(
      'm1',
      'conversation-1',
      'a' * 5000,
      totalTokens: 5000,
      updateMessageInList: (_, __, ___) {},
    );
    await tester.pump();
    final beforeBackground = updates.length;
    expect(beforeBackground, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(updates, hasLength(beforeBackground));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(updates.length, greaterThan(beforeBackground));
    controller.dispose();
  });

  testWidgets('dispose leaves no pending callbacks', (tester) async {
    final controller = buildController();
    final updates = listenTo(controller, 'm1');

    controller.scheduleThrottledUpdate(
      'm1',
      'conversation-1',
      'a' * 5000,
      totalTokens: 5000,
      updateMessageInList: (_, __, ___) {},
    );
    await tester.pump();
    final beforeDispose = updates.length;
    expect(beforeDispose, 1);

    controller.dispose();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(updates, hasLength(beforeDispose));
  });

  testWidgets('switching conversations stops publishing for stale messages', (
    tester,
  ) async {
    var currentConversation = 'conversation-1';
    final settings = SettingsProvider();
    final mutable = StreamController(
      chatService: ChatService(),
      onStateChanged: () {},
      getSettingsProvider: () => settings,
      getCurrentConversationId: () => currentConversation,
    );
    final updates = listenTo(mutable, 'm1');

    mutable.scheduleThrottledUpdate(
      'm1',
      'conversation-1',
      'a' * 5000,
      totalTokens: 5000,
      updateMessageInList: (_, __, ___) {},
    );
    await tester.pump();
    expect(updates, hasLength(1));

    // Switch to another conversation: stale frames must not publish.
    currentConversation = 'conversation-2';
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(updates, hasLength(1));
    mutable.dispose();
  });

  testWidgets('cleanup forces the final content through the list callback', (
    tester,
  ) async {
    final controller = buildController();
    final listContents = <String>[];
    final updates = listenTo(controller, 'm1');

    controller.scheduleThrottledUpdate(
      'm1',
      'conversation-1',
      'final-content',
      totalTokens: 13,
      updateMessageInList: (_, content, __) => listContents.add(content),
    );

    controller.cleanupTimers('m1');

    expect(listContents, contains('final-content'));
    expect(updates, contains('final-content'));
    controller.dispose();
  });

  testWidgets('final flush still fires auto-scroll (onStreamTick)', (
    tester,
  ) async {
    var tickCount = 0;
    final settings = SettingsProvider();
    final controller = StreamController(
      chatService: ChatService(),
      onStateChanged: () {},
      getSettingsProvider: () => settings,
      getCurrentConversationId: () => 'conversation-1',
      onStreamTick: () => tickCount++,
    );
    final updates = listenTo(controller, 'm1');

    controller.scheduleThrottledUpdate(
      'm1',
      'conversation-1',
      'a' * 5000,
      totalTokens: 5000,
      updateMessageInList: (_, __, ___) {},
    );
    await tester.pump();
    final ticksAfterFrame = tickCount;
    expect(ticksAfterFrame, 1);

    // Stream ends with leftover backlog: the cleanup flush publishes the
    // remaining content and must scroll the view along with it.
    controller.cleanupTimers('m1');

    expect(updates.last, 'a' * 5000);
    expect(tickCount, ticksAfterFrame + 1);
    controller.dispose();
  });

  testWidgets('auto-scroll fires once per frame even with many messages', (
    tester,
  ) async {
    var tickCount = 0;
    final settings = SettingsProvider();
    final ticked = StreamController(
      chatService: ChatService(),
      onStateChanged: () {},
      getSettingsProvider: () => settings,
      getCurrentConversationId: () => 'conversation-1',
      onStreamTick: () => tickCount++,
    );
    final updatesA = listenTo(ticked, 'm1');
    final updatesB = listenTo(ticked, 'm2');

    ticked.scheduleThrottledUpdate(
      'm1',
      'conversation-1',
      'a' * 5000,
      totalTokens: 5000,
      updateMessageInList: (_, __, ___) {},
    );
    ticked.scheduleThrottledUpdate(
      'm2',
      'conversation-1',
      'b' * 5000,
      totalTokens: 5000,
      updateMessageInList: (_, __, ___) {},
    );

    await tester.pump();
    expect(updatesA, hasLength(1));
    expect(updatesB, hasLength(1));
    expect(tickCount, 1);
    ticked.dispose();
  });
}
