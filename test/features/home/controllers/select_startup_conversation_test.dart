import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/home/controllers/home_page_controller.dart';

void main() {
  Conversation conv(String id, String? assistantId) =>
      Conversation(id: id, title: id, assistantId: assistantId);

  group('selectStartupConversation', () {
    test('mostRecent mode returns the globally most-recent conversation', () {
      final list = [conv('c1', 'a1'), conv('c2', 'a2')];
      final result = selectStartupConversation(list, pinnedAssistantId: null);
      expect(result?.id, 'c1');
    });

    test('mostRecent mode returns null when there are no conversations', () {
      final result = selectStartupConversation(
        const [],
        pinnedAssistantId: null,
      );
      expect(result, isNull);
    });

    test('pinned mode picks the pinned assistant conversation, skipping an '
        'earlier conversation of another assistant', () {
      final list = [conv('c1', 'a1'), conv('c2', 'a2'), conv('c3', 'a2')];
      final result = selectStartupConversation(list, pinnedAssistantId: 'a2');
      expect(result?.id, 'c2');
    });

    test('pinned mode returns null when the pinned assistant owns no '
        'conversations', () {
      final list = [conv('c1', 'a1')];
      final result = selectStartupConversation(list, pinnedAssistantId: 'a2');
      expect(result, isNull);
    });

    test('pinned mode skips group conversations (assistantId null)', () {
      final list = [conv('g1', null), conv('c2', 'a2')];
      final result = selectStartupConversation(list, pinnedAssistantId: 'a2');
      expect(result?.id, 'c2');
    });
  });

  group('resolveStartupAssistantId', () {
    const ids = {'a1', 'a2'};

    test('mostRecent mode resolves to null even with a live pinned id', () {
      final result = resolveStartupAssistantId(
        StartupAssistantMode.mostRecent,
        'a1',
        ids,
      );
      expect(result, isNull);
    });

    test('pinned mode resolves a live pinned assistant id', () {
      final result = resolveStartupAssistantId(
        StartupAssistantMode.pinned,
        'a2',
        ids,
      );
      expect(result, 'a2');
    });

    test('pinned mode with a null pinned id resolves to null (dangling)', () {
      final result = resolveStartupAssistantId(
        StartupAssistantMode.pinned,
        null,
        ids,
      );
      expect(result, isNull);
    });

    test(
      'pinned mode with an unknown pinned id resolves to null (dangling)',
      () {
        final result = resolveStartupAssistantId(
          StartupAssistantMode.pinned,
          'ghost',
          ids,
        );
        expect(result, isNull);
      },
    );
  });
}
