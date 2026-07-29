import 'dart:convert';

/// Index sent from the initiator (device A) to the server (device B) in round 1.
///
/// Contains per-conversation message IDs (ordered by messageOrder) and the
/// initiator's assistant IDs, so the server can compute a sync plan.
class SyncIndex {
  final Map<String, List<String>> conversations;
  final List<String> assistantIds;

  const SyncIndex({required this.conversations, required this.assistantIds});

  Map<String, dynamic> toJson() => {
    'conversations': conversations,
    'assistantIds': assistantIds,
  };

  String toJsonString() => jsonEncode(toJson());

  static SyncIndex fromJson(Map<String, dynamic> json) {
    final convsRaw = json['conversations'] as Map<String, dynamic>;
    final conversations = convsRaw.map(
      (k, v) => MapEntry(k, (v as List).cast<String>()),
    );
    return SyncIndex(
      conversations: conversations,
      assistantIds: (json['assistantIds'] as List).cast<String>(),
    );
  }

  static SyncIndex fromJsonString(String s) =>
      fromJson(jsonDecode(s) as Map<String, dynamic>);
}

/// Per-conversation divergence classification.
enum SyncConvState {
  /// Only the initiator (A) has increments after the fork point.
  initiatorOnly,

  /// Only the server (B) has increments after the fork point.
  serverOnly,

  /// Both sides have different increments after the fork point (fork).
  /// v1 detects but does not resolve.
  fork,

  /// Both sides are identical (no fork point needed).
  identical,
}

/// One conversation's sync classification in the plan.
class SyncConvPlan {
  final String conversationId;
  final String? conversationTitle;
  final SyncConvState state;

  /// The last common messageId (fork point). Null when the conversation
  /// only exists on one side or when both sides are identical with no
  /// messages after the fork.
  final String? forkPointMessageId;

  /// Number of messages the initiator (A) has after the fork point.
  final int initiatorIncrementCount;

  /// Number of messages the server (B) has after the fork point.
  final int serverIncrementCount;

  const SyncConvPlan({
    required this.conversationId,
    this.conversationTitle,
    required this.state,
    this.forkPointMessageId,
    required this.initiatorIncrementCount,
    required this.serverIncrementCount,
  });

  Map<String, dynamic> toJson() => {
    'conversationId': conversationId,
    'conversationTitle': conversationTitle,
    'state': state.name,
    'forkPointMessageId': forkPointMessageId,
    'initiatorIncrementCount': initiatorIncrementCount,
    'serverIncrementCount': serverIncrementCount,
  };
}

/// The sync plan returned from the server (B) to the initiator (A) in round 1.
class SyncPlan {
  /// Per-conversation classification.
  final List<SyncConvPlan> conversations;

  /// Assistant IDs that the server (B) is missing (should be sent by A).
  final List<String> missingAssistantIds;

  /// Assistant IDs that the initiator (A) is missing (will be sent by B).
  final List<String> remoteMissingAssistantIds;

  /// The earliest fork-point timestamp across all conversations.
  /// Used as the `since` parameter for incremental backup zip creation.
  /// Both sides use this to build their zip.
  final DateTime? since;

  /// Convenience: total conversations with initiator-only increments.
  int get initiatorOnlyCount =>
      conversations.where((c) => c.state == SyncConvState.initiatorOnly).length;

  /// Convenience: total conversations with server-only increments.
  int get serverOnlyCount =>
      conversations.where((c) => c.state == SyncConvState.serverOnly).length;

  /// Convenience: total conversations with forks.
  int get forkCount =>
      conversations.where((c) => c.state == SyncConvState.fork).length;

  const SyncPlan({
    required this.conversations,
    required this.missingAssistantIds,
    required this.remoteMissingAssistantIds,
    required this.since,
  });

  Map<String, dynamic> toJson() => {
    'conversations': conversations.map((c) => c.toJson()).toList(),
    'missingAssistantIds': missingAssistantIds,
    'remoteMissingAssistantIds': remoteMissingAssistantIds,
    'since': since?.toIso8601String(),
  };

  String toJsonString() => jsonEncode(toJson());

  static SyncPlan fromJson(Map<String, dynamic> json) {
    final convs = (json['conversations'] as List).map((c) {
      final m = c as Map<String, dynamic>;
      return SyncConvPlan(
        conversationId: m['conversationId'] as String,
        conversationTitle: m['conversationTitle'] as String?,
        state: SyncConvState.values.byName(m['state'] as String),
        forkPointMessageId: m['forkPointMessageId'] as String?,
        initiatorIncrementCount: m['initiatorIncrementCount'] as int,
        serverIncrementCount: m['serverIncrementCount'] as int,
      );
    }).toList();
    final sinceStr = json['since'] as String?;
    return SyncPlan(
      conversations: convs,
      missingAssistantIds: (json['missingAssistantIds'] as List).cast<String>(),
      remoteMissingAssistantIds: (json['remoteMissingAssistantIds'] as List)
          .cast<String>(),
      since: sinceStr != null ? DateTime.parse(sinceStr) : null,
    );
  }

  static SyncPlan fromJsonString(String s) =>
      fromJson(jsonDecode(s) as Map<String, dynamic>);
}
