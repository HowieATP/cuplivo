import '../../../core/models/assistant.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/conversation.dart';
import '../../../core/services/chat/chat_service.dart';
import 'director_context_builder.dart';

/// Builds on-the-fly private context for a member assistant (full timeline
/// role rewrite). Director is never visible.
class AssistantPrivateContextBuilder {
  AssistantPrivateContextBuilder({required this.chatService})
    : _directorCtx = DirectorContextBuilder(chatService: chatService);

  final ChatService chatService;
  final DirectorContextBuilder _directorCtx;

  /// Returns logical ChatMessages for MessagePipeline (user/assistant roles
  /// from the selected speaker's POV).
  List<ChatMessage> build({
    required Conversation conversation,
    required List<ChatMessage> publicMessages,
    required Assistant speaker,
    required String userName,
    required Map<String, Assistant> assistantsById,
  }) {
    // Version collapse
    final selected = _collapseVersions(
      publicMessages,
      conversation.versionSelections,
    );

    // truncateIndex before rewrite
    var slice = selected;
    if (conversation.truncateIndex >= 0 &&
        conversation.truncateIndex < selected.length) {
      slice = selected.sublist(conversation.truncateIndex);
    }

    final buffer = <String>[];
    final out = <ChatMessage>[];
    final speakerId = speaker.id;

    void flushBufferAsUser() {
      if (buffer.isEmpty) return;
      out.add(
        ChatMessage(
          role: 'user',
          content: buffer.join('\n'),
          conversationId: conversation.id,
        ),
      );
      buffer.clear();
    }

    for (final msg in slice) {
      if (msg.role == 'user') {
        final text = _directorCtx.contentForDirector(msg);
        buffer.add('[$userName]: $text');
      } else if (msg.role == 'assistant') {
        final sid = msg.speakerAssistantId;
        final content = _directorCtx.contentForDirector(msg);
        if (sid == speakerId) {
          flushBufferAsUser();
          out.add(
            ChatMessage(
              role: 'assistant',
              content: content,
              conversationId: conversation.id,
              modelId: msg.modelId,
              providerId: msg.providerId,
              speakerAssistantId: sid,
            ),
          );
        } else {
          final name = assistantsById[sid]?.name ?? sid ?? 'Assistant';
          buffer.add('[$name]: $content');
        }
      }
    }
    flushBufferAsUser();

    // Context size limit (after rewrite)
    if (speaker.limitContextMessages &&
        speaker.contextMessageSize > 0 &&
        out.length > speaker.contextMessageSize) {
      return out.sublist(out.length - speaker.contextMessageSize);
    }
    return out;
  }

  /// Index into sorted versions; default last (matches ChatController).
  List<ChatMessage> _collapseVersions(
    List<ChatMessage> messages,
    Map<String, int> versionSelections,
  ) {
    final byGroup = <String, List<ChatMessage>>{};
    final order = <String>[];
    for (final m in messages) {
      final gid = m.groupId ?? m.id;
      final list = byGroup.putIfAbsent(gid, () {
        order.add(gid);
        return <ChatMessage>[];
      });
      list.add(m);
    }
    for (final e in byGroup.entries) {
      e.value.sort((a, b) => a.version.compareTo(b.version));
    }
    final out = <ChatMessage>[];
    for (final gid in order) {
      final vers = byGroup[gid]!;
      final sel = versionSelections[gid];
      final idx = (sel != null && sel >= 0 && sel < vers.length)
          ? sel
          : (vers.length - 1);
      out.add(vers[idx]);
    }
    return out;
  }
}
