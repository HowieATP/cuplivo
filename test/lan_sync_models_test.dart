import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/services/sync/lan_sync_models.dart';

void main() {
  group('SyncPlan file payload fields', () {
    SyncPlan plan({int? serverFileCount, int? serverFileSizeBytes}) => SyncPlan(
      conversations: const [],
      missingAssistantIds: const [],
      remoteMissingAssistantIds: const [],
      since: DateTime(2026, 1, 1),
      serverFileCount: serverFileCount,
      serverFileSizeBytes: serverFileSizeBytes,
    );

    test('round-trips server file stats', () {
      final p = plan(serverFileCount: 12, serverFileSizeBytes: 3456);
      final decoded = SyncPlan.fromJsonString(p.toJsonString());
      expect(decoded.serverFileCount, 12);
      expect(decoded.serverFileSizeBytes, 3456);
      expect(decoded.since, DateTime(2026, 1, 1));
    });

    test('round-trips without file stats (null)', () {
      final p = plan();
      expect(p.toJsonString(), isNot(contains('serverFileCount')));
      final decoded = SyncPlan.fromJsonString(p.toJsonString());
      expect(decoded.serverFileCount, isNull);
      expect(decoded.serverFileSizeBytes, isNull);
    });

    test('old-format JSON without file keys parses as null', () {
      final raw = jsonEncode({
        'conversations': <dynamic>[],
        'missingAssistantIds': <dynamic>[],
        'remoteMissingAssistantIds': <dynamic>[],
        'since': '2026-01-01T00:00:00.000',
      });
      final decoded = SyncPlan.fromJsonString(raw);
      expect(decoded.serverFileCount, isNull);
      expect(decoded.serverFileSizeBytes, isNull);
      expect(decoded.since, DateTime(2026, 1, 1));
    });

    test('conversation-level plan round-trips unchanged', () {
      final p = SyncPlan(
        conversations: const [
          SyncConvPlan(
            conversationId: 'c1',
            conversationTitle: 'Chat 1',
            state: SyncConvState.initiatorOnly,
            initiatorIncrementCount: 3,
            serverIncrementCount: 0,
          ),
        ],
        missingAssistantIds: const ['a1'],
        remoteMissingAssistantIds: const <String>[],
        since: DateTime(2026, 1, 1),
        serverFileCount: 7,
        serverFileSizeBytes: 123,
      );
      final decoded = SyncPlan.fromJsonString(p.toJsonString());
      expect(decoded.initiatorOnlyCount, 1);
      expect(decoded.conversations.single.forkPointMessageId, isNull);
      expect(decoded.missingAssistantIds, ['a1']);
      expect(decoded.serverFileCount, 7);
    });
  });
}
