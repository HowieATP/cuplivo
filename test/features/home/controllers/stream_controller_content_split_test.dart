import 'package:flutter_test/flutter_test.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/features/chat/widgets/chat_message_widget.dart'
    show ToolUIPart;
import 'package:Cuplivo/features/home/controllers/stream_controller.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';

void main() {
  var businessPrefs = BusinessPreferences.memoryForTests();
  TestWidgetsFlutterBinding.ensureInitialized();
  businessPrefs = BusinessPreferences.memoryForTests(const {});

  StreamController buildController({
    SettingsProvider? settings,
    String? currentConversationId,
  }) {
    final settingsProvider =
        settings ?? SettingsProvider(preferences: businessPrefs);
    return StreamController(
      chatService: ChatService(),
      onStateChanged: () {},
      getSettingsProvider: () => settingsProvider,
      getCurrentConversationId: () => currentConversationId,
    );
  }

  test('v2 reasoning payload preserves content split metadata', () {
    final controller = buildController();
    final segment = ReasoningSegmentData()
      ..text = 'thinking'
      ..expanded = false
      ..toolStartIndex = 0;

    final json = serializeReasoningSegmentsWithSplits(
      [segment],
      contentSplitOffsets: const [12],
      reasoningCountAtSplit: const [1],
      toolCountAtSplit: const [2],
    );

    final restoredSegments = controller.deserializeReasoningSegments(json);
    final restoredSplits = controller.deserializeContentSplits(json);

    expect(restoredSegments, hasLength(1));
    expect(restoredSegments.single.text, 'thinking');
    expect(restoredSplits, isNotNull);
    expect(restoredSplits!.offsets, const [12]);
    expect(restoredSplits.reasoningCounts, const [1]);
    expect(restoredSplits.toolCounts, const [2]);
  });

  test('v1 reasoning payload remains compatible without content splits', () {
    final controller = buildController();
    final segment = ReasoningSegmentData()
      ..text = 'legacy'
      ..expanded = true
      ..toolStartIndex = 0;

    final json = controller.serializeReasoningSegments([segment]);

    expect(controller.deserializeReasoningSegments(json), hasLength(1));
    expect(controller.deserializeContentSplits(json), isNull);
  });

  test(
    'restoreMessageUiState restores tool parts and empty v2 split metadata',
    () {
      final controller = buildController();
      final message = ChatMessage(
        id: 'assistant-1',
        role: 'assistant',
        content: '让我帮你搜索一下',
        conversationId: 'conversation-1',
        reasoningSegmentsJson: serializeReasoningSegmentsWithSplits(
          const [],
          contentSplitOffsets: const [],
          reasoningCountAtSplit: const [],
          toolCountAtSplit: const [],
        ),
      );

      controller.restoreMessageUiState(
        message,
        getToolEventsFromDb: (_) => const [
          {
            'id': 'tool-1',
            'name': 'search_web',
            'arguments': {'query': 'Kelivo'},
            'content': null,
          },
        ],
        getGeminiThoughtSigFromDb: (_) => null,
      );

      expect(controller.contentSplits[message.id], isNotNull);
      expect(controller.contentSplits[message.id]!.offsets, isEmpty);
      expect(controller.toolParts[message.id], hasLength(1));
      expect(controller.toolParts[message.id]!.single.loading, isTrue);
    },
  );

  test('restoreMessageUiState skips STREAMING messages (live state is owned by '
      'the in-flight pipeline — issue: thinking stuck at 0.0s + forced collapse '
      'after switching conversations mid-stream)', () {
    final controller = buildController();
    final streaming = ChatMessage(
      id: 'assistant-streaming',
      role: 'assistant',
      content: '',
      conversationId: 'conversation-1',
      isStreaming: true,
      reasoningText: 'deep thinking in progress',
      reasoningStartAt: DateTime.now(),
      reasoningFinishedAt: null,
    );

    controller.restoreMessageUiState(
      streaming,
      getToolEventsFromDb: (_) => const [
        {
          'id': 'tool-1',
          'name': 'search_web',
          'arguments': {'query': 'Kelivo'},
          'content': null,
        },
      ],
      getGeminiThoughtSigFromDb: (_) => 'sig',
    );

    // Nothing restored: no bogus finishedAt=startAt reasoning entry, no
    // forced-collapse expanded flag, no tool parts overwrite.
    expect(controller.getReasoningData(streaming.id), isNull);
    expect(controller.getReasoningSegments(streaming.id), isNull);
    expect(controller.getToolParts(streaming.id), isNull);
    expect(controller.geminiThoughtSigs[streaming.id], isNull);

    // The non-streaming path keeps its existing behavior.
    final finished = ChatMessage(
      id: 'assistant-finished',
      role: 'assistant',
      content: 'done',
      conversationId: 'conversation-1',
      isStreaming: false,
      reasoningText: 'finished thinking',
      reasoningStartAt: DateTime.now().subtract(const Duration(seconds: 3)),
      reasoningFinishedAt: DateTime.now(),
    );
    controller.restoreMessageUiState(
      finished,
      getToolEventsFromDb: (_) => const [],
      getGeminiThoughtSigFromDb: (_) => null,
    );
    final rd = controller.getReasoningData(finished.id);
    expect(rd, isNotNull);
    expect(rd!.text, 'finished thinking');
    expect(rd.expanded, isFalse);
    expect(rd.finishedAt!.isAfter(rd.startAt!), isTrue);
  });

  test(
    'dedupeToolPartsList keeps completed no-id tool results with different content',
    () {
      final controller = buildController();

      final parts = controller.dedupeToolPartsList(const [
        ToolUIPart(
          id: '',
          toolName: 'builtin_search',
          arguments: {},
          content: '{"items":[{"title":"First"}]}',
        ),
        ToolUIPart(
          id: '',
          toolName: 'builtin_search',
          arguments: {},
          content: '{"items":[{"title":"Second"}]}',
        ),
      ]);

      expect(parts, hasLength(2));
      expect(parts.map((part) => part.content), [
        '{"items":[{"title":"First"}]}',
        '{"items":[{"title":"Second"}]}',
      ]);
    },
  );

  test(
    'dedupeToolEvents keeps completed no-id tool results with different content',
    () {
      final events = dedupeToolEvents(const [
        {
          'id': '',
          'name': 'builtin_search',
          'arguments': <String, dynamic>{},
          'content': '{"items":[{"title":"First"}]}',
        },
        {
          'id': '',
          'name': 'builtin_search',
          'arguments': <String, dynamic>{},
          'content': '{"items":[{"title":"Second"}]}',
        },
      ]);

      expect(events, hasLength(2));
      expect(events.map((event) => event['content']), [
        '{"items":[{"title":"First"}]}',
        '{"items":[{"title":"Second"}]}',
      ]);
    },
  );

  test(
    'dedupeToolPartsList keeps latest completed result for the same non-empty id',
    () {
      final controller = buildController();

      final parts = controller.dedupeToolPartsList(const [
        ToolUIPart(
          id: 'builtin_search',
          toolName: 'builtin_search',
          arguments: {},
          content: '{"items":[{"title":"First"}]}',
        ),
        ToolUIPart(
          id: 'builtin_search',
          toolName: 'builtin_search',
          arguments: {},
          content: '{"items":[{"title":"First"},{"title":"Second"}]}',
        ),
      ]);

      expect(parts, hasLength(1));
      expect(
        parts.single.content,
        '{"items":[{"title":"First"},{"title":"Second"}]}',
      );
    },
  );

  test(
    'dedupeToolEvents keeps latest completed result for the same non-empty id',
    () {
      final events = dedupeToolEvents(const [
        {
          'id': 'builtin_search',
          'name': 'builtin_search',
          'arguments': <String, dynamic>{},
          'content': '{"items":[{"title":"First"}]}',
        },
        {
          'id': 'builtin_search',
          'name': 'builtin_search',
          'arguments': <String, dynamic>{},
          'content': '{"items":[{"title":"First"},{"title":"Second"}]}',
        },
      ]);

      expect(events, hasLength(1));
      expect(
        events.single['content'],
        '{"items":[{"title":"First"},{"title":"Second"}]}',
      );
    },
  );

  test(
    'dedupeToolPartsList drops stale no-id placeholders when a completed result exists',
    () {
      final controller = buildController();

      final parts = controller.dedupeToolPartsList(const [
        ToolUIPart(
          id: '',
          toolName: 'builtin_search',
          arguments: {},
          loading: true,
        ),
        ToolUIPart(
          id: '',
          toolName: 'builtin_search',
          arguments: {},
          content: '{"items":[{"title":"Finished"}]}',
        ),
      ]);

      expect(parts, hasLength(1));
      expect(parts.single.loading, isFalse);
      expect(parts.single.content, '{"items":[{"title":"Finished"}]}');
    },
  );

  test(
    'dedupeToolEvents drops stale no-id placeholders when a completed result exists',
    () {
      final events = dedupeToolEvents(const [
        {
          'id': '',
          'name': 'builtin_search',
          'arguments': <String, dynamic>{},
          'content': null,
        },
        {
          'id': '',
          'name': 'builtin_search',
          'arguments': <String, dynamic>{},
          'content': '{"items":[{"title":"Finished"}]}',
        },
      ]);

      expect(events, hasLength(1));
      expect(events.single['content'], '{"items":[{"title":"Finished"}]}');
    },
  );
}
