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
      user: const <String, dynamic>{
        'name': 'Ada',
        'avatarType': 'emoji',
        'avatarLabel': '🦊',
      },
      display: const <String, dynamic>{
        'backgroundStyle': 'frosted',
        'backgroundOwner': 'flutter',
        'showUserMessageActions': true,
        'showTokenStats': true,
      },
      topContentPadding: 72,
      bottomContentPadding: 104,
      assistant: Assistant(
        id: 'a1',
        name: 'Assistant',
        avatar: r'\\server\share\assistant.png',
        background: '/private/background.jpg',
        useAssistantAvatar: true,
      ),
      fontScale: 1,
      canStartMultiAI: true,
      autoCollapseThinking: true,
      initialViewportAnchor: const <String, dynamic>{
        'messageId': 'm1',
        'offset': -16.0,
      },
    );

    final rendered = (snapshot['messages'] as List).single as Map;
    expect(snapshot['protocolVersion'], 2);
    expect(snapshot['assetVersion'], 'web-chat-v11');
    expect(snapshot['initialViewportAnchor'], <String, dynamic>{
      'messageId': 'm1',
      'offset': -16.0,
    });
    expect((snapshot['user'] as Map)['name'], 'Ada');
    expect((snapshot['display'] as Map)['backgroundStyle'], 'frosted');
    expect((snapshot['display'] as Map)['backgroundOwner'], 'flutter');
    expect((snapshot['display'] as Map)['contentInsets'], <String, double>{
      'top': 72,
      'bottom': 104,
    });
    expect((snapshot['assistant'] as Map)['avatar'], startsWith('local:'));
    expect((snapshot['assistant'] as Map)['avatar'], isNot(contains('server')));
    expect((snapshot['assistant'] as Map)['background'], startsWith('local:'));
    expect(
      (snapshot['assistant'] as Map)['background'],
      isNot(contains('/private')),
    );
    expect(rendered['content'], 'Visible answer');
    final renderedReasoning = (rendered['reasoning'] as List).single as Map;
    expect(renderedReasoning['text'], 'live thought');
    expect(renderedReasoning['kind'], 'single');
    expect(renderedReasoning['index'], 0);
    expect(renderedReasoning['key'], 'm1:reasoning:single:0');
    expect(rendered['actions'], isEmpty);
    expect((rendered['tools'] as List).single['toolName'], 'search');
    expect(rendered['selected'], isTrue);
    expect(rendered['showContextDivider'], isTrue);
  });

  test('snapshot distinguishes segmented and local legacy reasoning', () {
    final segmented = ChatMessage(
      id: 'segment-message',
      role: 'assistant',
      content: 'Segment answer',
      conversationId: 'c1',
    );
    final legacy = ChatMessage(
      id: 'legacy-message',
      role: 'assistant',
      content: '<think>legacy thought</think>Legacy answer',
      conversationId: 'c1',
    );
    final segment = stream_ctrl.ReasoningSegmentData()
      ..text = 'segment thought'
      ..expanded = false;
    final snapshot = const WebChatSnapshotBuilder().build(
      renderSessionId: 's1',
      conversationId: 'c1',
      renderRevision: 1,
      actionEpoch: 1,
      messages: <ChatMessage>[segmented, legacy],
      byGroup: const <String, List<ChatMessage>>{},
      versionSelections: const <String, int>{},
      reasoning: const <String, stream_ctrl.ReasoningData>{},
      reasoningSegments: <String, List<stream_ctrl.ReasoningSegmentData>>{
        segmented.id: <stream_ctrl.ReasoningSegmentData>[segment],
      },
      contentSplits: const <String, stream_ctrl.ContentSplitData>{},
      toolParts: const <String, List<ToolUIPart>>{},
      selectedItems: const <String>{},
      selecting: false,
      truncCollapsedIndex: -1,
      suggestions: const <String>[],
      hasMoreBefore: false,
      hasMoreAfter: false,
      strings: const <String, String>{},
      theme: const <String, String>{},
      user: const <String, dynamic>{'name': 'User'},
      display: const <String, dynamic>{'showUserMessageActions': false},
      topContentPadding: 0,
      bottomContentPadding: 0,
      assistant: null,
      fontScale: 1,
      canStartMultiAI: false,
      autoCollapseThinking: true,
    );

    final messages = snapshot['messages'] as List;
    final segmentedReasoning =
        ((messages.first as Map)['reasoning'] as List).single as Map;
    final legacyReasoning =
        ((messages.last as Map)['reasoning'] as List).single as Map;

    expect(segmentedReasoning['kind'], 'segment');
    expect(segmentedReasoning['key'], 'segment-message:reasoning:segment:0');
    expect(segmentedReasoning['expanded'], isFalse);
    expect((messages.first as Map)['actions'], <String>[
      'copy',
      'regenerate',
      'speak',
      'translate',
      'more',
    ]);
    expect(legacyReasoning['kind'], 'legacy');
    expect(legacyReasoning['key'], 'legacy-message:reasoning:legacy:0');
    expect(legacyReasoning['expanded'], isFalse);
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

  test('media registry keeps local and bundled asset paths opaque', () {
    final message = ChatMessage(
      id: 'model-message',
      role: 'assistant',
      content: '[image:/private/photo.png]',
      conversationId: 'c1',
      modelId: 'gpt-5',
      providerId: 'openai',
    );

    final registry = buildWebChatMediaRegistry(
      <ChatMessage>[message],
      assistant: Assistant(
        id: 'assistant',
        name: 'Assistant',
        avatar: r'\\server\share\assistant.png',
        background: '/private/background.webp',
      ),
      userAvatarType: 'file',
      userAvatarValue: '/private/avatar.png',
    );

    expect(registry.keys, everyElement(isNot(contains('/private'))));
    expect(
      registry.values.any(
        (source) => source.kind == WebChatMediaSourceKind.localFile,
      ),
      isTrue,
    );
    expect(
      registry.values.any(
        (source) => source.kind == WebChatMediaSourceKind.bundledAsset,
      ),
      isTrue,
    );
    expect(
      registry.values.any(
        (source) => source.value == r'\\server\share\assistant.png',
      ),
      isTrue,
    );
    expect(
      registry.values.any(
        (source) => source.value == '/private/background.webp',
      ),
      isTrue,
    );
  });
}
