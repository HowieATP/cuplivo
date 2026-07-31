import 'dart:async';

import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/api/chat_api_service.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/features/group_chat/controllers/group_chat_stream_executor.dart';
import 'package:Cuplivo/features/home/controllers/stream_controller.dart'
    as stream_ctrl;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Records persistence calls instead of touching a real database.
class _RecordingChatService extends ChatService {
  final List<({String messageId, String? content, bool? isStreaming})> updates =
      [];
  final List<({String messageId, String content})> silentContent = [];

  @override
  Future<void> updateMessage(
    String messageId, {
    String? content,
    int? totalTokens,
    bool? isStreaming,
    String? reasoningText,
    DateTime? reasoningStartAt,
    DateTime? reasoningFinishedAt,
    String? translation,
    String? reasoningSegmentsJson,
    int? promptTokens,
    int? completionTokens,
    int? cachedTokens,
    int? durationMs,
    Object? groupId = ChatMessage.sentinel,
    Object? subgroupId = ChatMessage.sentinel,
    Object? version = ChatMessage.sentinel,
  }) async {
    updates.add((
      messageId: messageId,
      content: content,
      isStreaming: isStreaming,
    ));
  }

  @override
  Future<void> updateMessageSilent(
    String messageId, {
    String? content,
    int? totalTokens,
    bool? isStreaming,
    String? reasoningText,
    DateTime? reasoningStartAt,
    DateTime? reasoningFinishedAt,
    String? translation,
    String? reasoningSegmentsJson,
    int? promptTokens,
    int? completionTokens,
    int? cachedTokens,
    int? durationMs,
  }) async {
    if (content != null) {
      silentContent.add((messageId: messageId, content: content));
    }
  }

  @override
  Future<void> setGeminiThoughtSignature(
    String messageId,
    String signature,
  ) async {}
}

void main() {
  Future<SettingsProvider> makeSettings() async {
    SharedPreferences.setMockInitialValues({});
    return SettingsProvider();
  }

  stream_ctrl.GenerationContext buildCtx(
    SettingsProvider settings,
    ProviderConfig config, {
    String messageId = 'm1',
  }) {
    return stream_ctrl.GenerationContext(
      assistantMessage: ChatMessage(
        id: messageId,
        role: 'assistant',
        content: '',
        conversationId: 'c1',
      ),
      apiMessages: [
        {'role': 'user', 'content': 'hi'},
      ],
      userMediaPaths: const [],
      allowImagesApiRouting: false,
      providerKey: 'ExecutorTest',
      modelId: 'test-model',
      assistant: null,
      settings: settings,
      config: config,
      toolDefs: const [],
      supportsReasoning: false,
      enableReasoning: false,
      streamOutput: true,
    );
  }

  ProviderConfig testConfig() {
    return ProviderConfig(
      id: 'ExecutorTest',
      enabled: true,
      name: 'ExecutorTest',
      apiKey: 'test-key',
      baseUrl: 'https://example.test',
      providerType: ProviderKind.openai,
      useResponseApi: false,
    );
  }

  Future<void> waitForSilentContent(
    _RecordingChatService svc,
    String messageId,
    String target,
  ) async {
    for (var i = 0; i < 300; i++) {
      final matches = svc.silentContent
          .where((c) => c.messageId == messageId && c.content == target)
          .toList();
      if (matches.isNotEmpty) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('timed out waiting for persisted content "$target"');
  }

  test('executeStream future completes only after the stream ends and the '
      'final content is persisted', () async {
    final settings = await makeSettings();
    final fake = _RecordingChatService();
    final sc = stream_ctrl.StreamController(
      chatService: fake,
      onStateChanged: () {},
      getSettingsProvider: () => settings,
      getCurrentConversationId: () => 'c1',
    );
    final chunkStream = StreamController<ChatStreamChunk>();
    addTearDown(() => chunkStream.close());
    final executor = GroupChatStreamExecutor(
      chatService: fake,
      streamController: sc,
      sendMessageStream:
          ({
            required ProviderConfig config,
            required String modelId,
            required List<Map<String, dynamic>> messages,
            List<String>? userMediaPaths,
            int? thinkingBudget,
            double? temperature,
            double? topP,
            int? maxTokens,
            List<Map<String, dynamic>>? tools,
            ToolCallHandler? onToolCall,
            Map<String, String>? extraHeaders,
            Map<String, dynamic>? extraBody,
            bool stream = true,
            String? requestId,
            bool allowImagesApiRouting = true,
            bool ocrActive = false,
          }) => chunkStream.stream,
    );

    var completed = false;
    final running = executor
        .executeStream(
          buildCtx(settings, testConfig()),
          streamKeyOverride: 'm1',
          requestIdOverride: 'm1',
        )
        .then((_) => completed = true);

    await pumpEventQueue();
    chunkStream.add(
      ChatStreamChunk(content: 'Hello ', isDone: false, totalTokens: 0),
    );
    // Wait until the first chunk was persisted while the stream is in flight.
    await waitForSilentContent(fake, 'm1', 'Hello ');

    // Regression: the future must NOT complete before the stream ended —
    // otherwise callers (director turn builder) read the still-empty
    // placeholder content instead of the final assistant message.
    expect(completed, isFalse, reason: 'stream must still be in flight');
    expect(
      fake.updates.where((u) => u.isStreaming == false),
      isEmpty,
      reason: 'final write must not happen before the stream ends',
    );

    chunkStream.add(
      ChatStreamChunk(content: 'World', isDone: true, totalTokens: 5),
    );
    await chunkStream.close();
    await running.timeout(const Duration(seconds: 5));

    expect(completed, isTrue);
    final finalUpdate = fake.updates.lastWhere((u) => u.isStreaming == false);
    expect(finalUpdate.content, 'Hello World');
  });

  test('cancel completes the future and finalizes the message', () async {
    final settings = await makeSettings();
    final fake = _RecordingChatService();
    final sc = stream_ctrl.StreamController(
      chatService: fake,
      onStateChanged: () {},
      getSettingsProvider: () => settings,
      getCurrentConversationId: () => 'c1',
    );
    final chunkStream = StreamController<ChatStreamChunk>();
    addTearDown(() => chunkStream.close());
    final executor = GroupChatStreamExecutor(
      chatService: fake,
      streamController: sc,
      sendMessageStream:
          ({
            required ProviderConfig config,
            required String modelId,
            required List<Map<String, dynamic>> messages,
            List<String>? userMediaPaths,
            int? thinkingBudget,
            double? temperature,
            double? topP,
            int? maxTokens,
            List<Map<String, dynamic>>? tools,
            ToolCallHandler? onToolCall,
            Map<String, String>? extraHeaders,
            Map<String, dynamic>? extraBody,
            bool stream = true,
            String? requestId,
            bool allowImagesApiRouting = true,
            bool ocrActive = false,
          }) => chunkStream.stream,
    );

    final running = executor.executeStream(
      buildCtx(settings, testConfig()),
      streamKeyOverride: 'm1',
      requestIdOverride: 'm1',
    );
    await pumpEventQueue();
    chunkStream.add(
      ChatStreamChunk(content: 'Partial', isDone: false, totalTokens: 0),
    );
    await waitForSilentContent(fake, 'm1', 'Partial');

    await executor.cancel('m1');
    await running.timeout(const Duration(seconds: 5));

    expect(
      fake.updates.any((u) => u.messageId == 'm1' && u.isStreaming == false),
      isTrue,
      reason: 'cancelled message must be finalized (isStreaming: false)',
    );
  });

  test('stream error completes the future and finalizes the message', () async {
    final settings = await makeSettings();
    final fake = _RecordingChatService();
    final sc = stream_ctrl.StreamController(
      chatService: fake,
      onStateChanged: () {},
      getSettingsProvider: () => settings,
      getCurrentConversationId: () => 'c1',
    );
    final chunkStream = StreamController<ChatStreamChunk>();
    addTearDown(() => chunkStream.close());
    final executor = GroupChatStreamExecutor(
      chatService: fake,
      streamController: sc,
      sendMessageStream:
          ({
            required ProviderConfig config,
            required String modelId,
            required List<Map<String, dynamic>> messages,
            List<String>? userMediaPaths,
            int? thinkingBudget,
            double? temperature,
            double? topP,
            int? maxTokens,
            List<Map<String, dynamic>>? tools,
            ToolCallHandler? onToolCall,
            Map<String, String>? extraHeaders,
            Map<String, dynamic>? extraBody,
            bool stream = true,
            String? requestId,
            bool allowImagesApiRouting = true,
            bool ocrActive = false,
          }) => chunkStream.stream,
    );

    final running = executor.executeStream(
      buildCtx(settings, testConfig()),
      streamKeyOverride: 'm1',
      requestIdOverride: 'm1',
    );
    await pumpEventQueue();
    chunkStream.addError(Exception('boom'));
    await running.timeout(const Duration(seconds: 5));

    final finalUpdate = fake.updates.lastWhere((u) => u.isStreaming == false);
    expect(finalUpdate.content, contains('Error:'));
  });
}
