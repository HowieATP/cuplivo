import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/features/chat/models/tool_ui_part.dart';
import 'package:Cuplivo/features/home/controllers/stream_controller.dart'
    as stream_ctrl;
import 'package:Cuplivo/features/home/webview/web_chat_snapshot.dart';

void main() {
  test('snapshot keeps compatibility transforms and live domain state', () {
    final message = ChatMessage(
      id: 'm1',
      role: 'assistant',
      content: '<think>legacy thought</think>Visible answer',
      conversationId: 'c1',
      groupId: 'g1',
      version: 1,
      translation: 'Translated answer',
      isStreaming: true,
    );
    final reasoning = stream_ctrl.ReasoningData()
      ..text = 'live thought'
      ..expanded = true;
    final snapshot = const WebChatSnapshotBuilder().build(
      renderSessionId: 's1',
      conversationId: 'c1',
      renderRevision: 2,
      actionEpoch: 3,
      messages: <ChatMessage>[message],
      byGroup: <String, List<ChatMessage>>{
        'g1': <ChatMessage>[message],
      },
      versionSelections: <String, int>{'g1': 1},
      reasoning: <String, stream_ctrl.ReasoningData>{'m1': reasoning},
      reasoningSegments:
          const <String, List<stream_ctrl.ReasoningSegmentData>>{},
      contentSplits: const <String, stream_ctrl.ContentSplitData>{},
      toolParts: const <String, List<ToolUIPart>>{
        'm1': <ToolUIPart>[
          ToolUIPart(
            id: 'tool-1',
            toolName: 'search',
            arguments: <String, dynamic>{'query': 'Cuplivo'},
            loading: true,
          ),
        ],
      },
      selectedItems: const <String>{'m1'},
      selecting: true,
      truncCollapsedIndex: 0,
      suggestions: const <String>['Continue'],
      hasMoreBefore: true,
      hasMoreAfter: false,
      strings: const <String, String>{'copy': 'Copy'},
      theme: const <String, String>{'surface': '#ffffff'},
      assistant: Assistant(id: 'a1', name: 'Assistant'),
      fontScale: 1,
      canStartMultiAI: true,
    );

    final rendered = (snapshot['messages'] as List).single as Map;
    expect(rendered['content'], 'Visible answer');
    expect(rendered['legacyThinking'], <String>['legacy thought']);
    expect((rendered['reasoning'] as List).single['text'], 'live thought');
    expect((rendered['tools'] as List).single['toolName'], 'search');
    expect(rendered['selected'], isTrue);
    expect(rendered['showContextDivider'], isTrue);
  });

  test('attachment parser emits opaque handles for local paths', () {
    final attachments = parseWebChatAttachments(
      '[image:/private/photo.png]\n[file:C:\\doc.pdf|Doc|application/pdf]',
    );

    expect(attachments, hasLength(2));
    expect(attachments.first['reference'], startsWith('local:'));
    expect(attachments.first['reference'], isNot(contains('/private')));
    expect(attachments.last['name'], 'Doc');
  });
}
