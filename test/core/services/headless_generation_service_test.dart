import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/services/api/chat_api_service.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/headless_generation_service.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';

class _FakeChatService extends ChatService {
  final messagesByConversation = <String, List<ChatMessage>>{};
  int _nextMessageId = 1;

  @override
  Future<ChatMessage> addMessage({
    required String conversationId,
    required String role,
    required String content,
    String? modelId,
    String? providerId,
    int? totalTokens,
    bool isStreaming = false,
    String? reasoningText,
    DateTime? reasoningStartAt,
    DateTime? reasoningFinishedAt,
    String? groupId,
    String? subgroupId,
    int? version,
    bool isPreset = false,
    String? speakerAssistantId,
  }) async {
    final message = ChatMessage(
      id: 'msg-${_nextMessageId++}',
      role: role,
      content: content,
      conversationId: conversationId,
      totalTokens: totalTokens,
      isStreaming: isStreaming,
    );
    (messagesByConversation[conversationId] ??= []).add(message);
    return message;
  }

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
    for (final list in messagesByConversation.values) {
      for (int i = 0; i < list.length; i++) {
        if (list[i].id == messageId) {
          list[i] = list[i].copyWith(
            content: content,
            totalTokens: totalTokens,
            isStreaming: isStreaming,
          );
        }
      }
    }
  }
}

void main() {
  late _FakeChatService chatService;
  late Map<String, StreamController<ChatStreamChunk>> streamControllers;
  late HeadlessGenerationService service;

  final config = ProviderConfig(
    id: 'test',
    enabled: true,
    name: 'test',
    apiKey: 'test',
    baseUrl: 'https://example.com',
    models: const [],
  );

  StreamController<ChatStreamChunk> controllerFor(String id) =>
      streamControllers.putIfAbsent(
        id,
        () => StreamController<ChatStreamChunk>(),
      );

  void pumpChunk(
    String id,
    String content, {
    List<ToolCallInfo>? calls,
    List<ToolResultInfo>? results,
  }) {
    controllerFor(id).add(
      ChatStreamChunk(
        content: content,
        isDone: false,
        totalTokens: 0,
        toolCalls: calls,
        toolResults: results,
      ),
    );
  }

  Future<void> closeStream(String id) => controllerFor(id).close();

  Future<void> startChild({
    required String id,
    String? parent,
    bool wait = true,
  }) async {
    service.start(
      conversationId: id,
      assistantId: 'assistant-1',
      apiMessages: const [],
      config: config,
      modelId: 'model-1',
      parentConversationId: parent,
      wait: wait,
    );
    // Let `_run` reach its `await for` (after the async addMessage) so the
    // single-subscription test stream is already being listened to.
    await pumpEventQueue();
  }

  setUp(() {
    chatService = _FakeChatService();
    streamControllers = <String, StreamController<ChatStreamChunk>>{};
    service = HeadlessGenerationService(
      chatService: chatService,
      chatStreamProvider:
          ({
            required config,
            required modelId,
            required messages,
            tools,
            onToolCall,
            thinkingBudget,
            temperature,
            topP,
            maxTokens,
            required stream,
            required requestId,
          }) {
            return (streamControllers[requestId] ??=
                    StreamController<ChatStreamChunk>())
                .stream;
          },
    );
  });

  tearDown(() async {
    for (final c in streamControllers.values) {
      await c.close();
    }
  });

  group('HeadlessGenerationService wait-mode', () {
    test(
      'waitFor resolves with the full streamed output on completion',
      () async {
        await startChild(id: 'child-1', parent: 'parent-1');
        final future = service.waitFor('child-1');

        pumpChunk('child-1', 'hello ');
        pumpChunk('child-1', 'world');
        await closeStream('child-1');

        final result = await future;
        expect(result.text, 'hello world');
        expect(result.cancelled, isFalse);
        expect(result.error, isNull);

        final job = service.jobFor('child-1');
        expect(job, isNotNull);
        expect(job!.status, SubagentJobStatus.done);
        expect(job.streamedChars, 11);
        expect(job.isWait, isTrue);
        expect(job.parentConversationId, 'parent-1');
      },
    );

    test('job tracks last tool call and result', () async {
      await startChild(id: 'child-1', parent: 'parent-1');
      final future = service.waitFor('child-1');

      pumpChunk(
        'child-1',
        '',
        calls: [ToolCallInfo(id: 'call-1', name: 'kelivo_read', arguments: {})],
      );
      pumpChunk(
        'child-1',
        '',
        results: [
          ToolResultInfo(
            id: 'call-1',
            name: 'kelivo_read',
            arguments: {},
            content: 'file content',
          ),
        ],
      );
      await closeStream('child-1');
      await future;

      final job = service.jobFor('child-1');
      expect(job!.lastStep, 'kelivo_read');
      expect(job.lastStepKind, SubagentLastStepKind.done);
    });

    test(
      'cancel resolves the waiter and unwinds the run like production',
      () async {
        await startChild(id: 'child-1', parent: 'parent-1');
        final future = service.waitFor('child-1');
        pumpChunk('child-1', 'partial');

        service.cancel('child-1');

        final result = await future;
        expect(result.cancelled, isTrue);
        expect(result.text, isEmpty);

        // Production flow: cancelRequest makes the real stream error, the
        // catch persists what streamed so far, and the record is dropped.
        streamControllers['child-1']!.addError(StateError('cancelled'));
        await pumpEventQueue();

        expect(service.jobFor('child-1'), isNull);
        final messages =
            chatService.messagesByConversation['child-1'] ?? const [];
        expect(messages, isNotEmpty);
        expect(messages.last.content, 'partial');
        expect(messages.last.isStreaming, isFalse);
      },
    );

    test('cancelling the parent cascades to wait-mode children only', () async {
      await startChild(id: 'child-wait', parent: 'parent-1', wait: true);
      await startChild(id: 'child-fire', parent: 'parent-1', wait: false);
      final childFuture = service.waitFor('child-wait');
      final orphanFuture = service.waitFor('child-fire');

      service.cancel('parent-1');

      final childResult = await childFuture;
      expect(childResult.cancelled, isTrue);

      // Fire-and-forget sub-agent keeps running: completing its stream does
      // not surface a cancelled result.
      pumpChunk('child-fire', 'still running');
      await closeStream('child-fire');
      final orphanResult = await orphanFuture;
      expect(orphanResult.cancelled, isFalse);
      expect(orphanResult.text, 'still running');
    });

    test(
      'cancelling the parent cascades recursively through the wait chain',
      () async {
        await startChild(id: 'child-wait', parent: 'parent-1', wait: true);
        await startChild(id: 'grandchild', parent: 'child-wait', wait: true);
        final grandFuture = service.waitFor('grandchild');

        service.cancel('parent-1');

        final grandResult = await grandFuture;
        expect(grandResult.cancelled, isTrue);
      },
    );

    test('stream error resolves the waiter with the error', () async {
      await startChild(id: 'child-1', parent: 'parent-1');
      final future = service.waitFor('child-1');
      pumpChunk('child-1', 'before boom');
      streamControllers['child-1']!.addError(StateError('boom'));
      await closeStream('child-1');

      final result = await future;
      expect(result.error, contains('boom'));
      expect(service.jobFor('child-1')!.status, SubagentJobStatus.error);
    });

    test('waitFor on an unknown conversation resolves with an error', () async {
      final result = await service.waitFor('nope');
      expect(result.error, isNotNull);
    });

    test('prepareJob registers the job before generation starts so waitFor '
        'never races the async pipeline', () async {
      // Simulates the engine: the started JSON travels back through pure
      // microtasks while the generation suspends on real I/O. The handler's
      // waitFor must find the record already registered.
      service.prepareJob(
        conversationId: 'child-1',
        parentConversationId: 'parent-1',
        wait: true,
        targetName: 'Research Bot',
      );
      final future = service.waitFor('child-1');

      // Generation starts late and resolves the same record.
      await startChild(id: 'child-1', parent: 'parent-1');
      pumpChunk('child-1', 'result text');
      await closeStream('child-1');

      final result = await future;
      expect(result.text, 'result text');
      expect(result.error, isNull);
      expect(service.jobFor('child-1')!.targetName, 'Research Bot');
    });

    test('cancel before _run starts aborts the generation without '
        'persisting anything', () async {
      service.prepareJob(
        conversationId: 'child-1',
        parentConversationId: 'parent-1',
        wait: true,
      );
      final future = service.waitFor('child-1');

      // User cancels during the engine-side window (between prepareJob and
      // the generation actually starting).
      service.cancel('child-1');
      final result = await future;
      expect(result.cancelled, isTrue);

      // A late start must abort: no placeholder message, job gone, and the
      // status is NOT overwritten to done.
      await startChild(id: 'child-1', parent: 'parent-1');
      expect(
        chatService.messagesByConversation['child-1'] ?? const [],
        isEmpty,
      );
      expect(service.isActive('child-1'), isFalse);
      expect(service.jobFor('child-1'), isNull);
    });

    test('waitJobsFor returns only wait-mode jobs of the parent', () async {
      await startChild(id: 'child-wait', parent: 'parent-1', wait: true);
      await startChild(id: 'child-fire', parent: 'parent-1', wait: false);
      await startChild(id: 'other', parent: 'other-parent', wait: true);

      final jobs = service.waitJobsFor('parent-1');
      expect(jobs.map((j) => j.conversationId), ['child-wait']);
    });
  });
}
