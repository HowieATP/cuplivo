import 'dart:async';
import 'dart:convert';

import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/group_chat.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/api/chat_api_service.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/features/group_chat/services/director_context_builder.dart';
import 'package:Cuplivo/features/group_chat/services/director_runner.dart';
import 'package:Cuplivo/features/group_chat/services/director_tool_protocol.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Captures the tool-call handler and lets the test drive the stream.
class _FakeDirectorTransport {
  final StreamController<ChatStreamChunk> controller =
      StreamController<ChatStreamChunk>();
  ToolCallHandler? toolCallHandler;
  bool subscriptionCancelled = false;

  _FakeDirectorTransport() {
    controller.onCancel = () {
      subscriptionCancelled = true;
    };
  }

  Stream<ChatStreamChunk> send({
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
  }) {
    toolCallHandler = onToolCall;
    return controller.stream;
  }
}

void main() {
  late _FakeDirectorTransport transport;
  late DirectorRunner runner;
  late GroupChat group;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    transport = _FakeDirectorTransport();
    runner = DirectorRunner(
      chatService: ChatService(),
      contextBuilder: DirectorContextBuilder(chatService: ChatService()),
      sendMessageStream: transport.send,
    );
    group = GroupChat(
      name: 'test group',
      conversationId: 'conversation-1',
      directorModelProvider: 'TestProvider',
      directorModelId: 'test-model',
    );
  });

  tearDown(() {
    transport.controller.close();
  });

  Future<DirectorDecision> runDirector() {
    final assistants = <Assistant>[
      Assistant(id: 'a1', name: 'Alpha'),
      Assistant(id: 'a2', name: 'Beta'),
    ];
    return runner.run(
      group: group,
      newUserContent: '[user]: hi',
      rosterAssistants: assistants,
      userName: 'user',
      memberNames: const <String>['user', 'Alpha', 'Beta'],
      settings: SettingsProvider(),
      modelSupportsTools: (providerKey, modelId) => true,
      publicMessages: const <ChatMessage>[],
      versionSelections: const <String, int>{},
      assistantsById: {for (final a in assistants) a.id: a},
    );
  }

  test('first tool call returns a neutral result and cancels the stream '
      'immediately', () async {
    final future = runDirector();

    transport.controller.add(
      ChatStreamChunk(
        content: '',
        isDone: false,
        totalTokens: 0,
        toolCalls: <ToolCallInfo>[
          ToolCallInfo(
            id: 't1',
            name: DirectorTools.selectSpeaker,
            arguments: const <String, dynamic>{'assistant_id': 'a1'},
          ),
        ],
      ),
    );
    transport.controller.add(
      ChatStreamChunk(content: '', isDone: true, totalTokens: 0),
    );

    final decision = await future.timeout(const Duration(seconds: 5));
    expect(decision.kind, DirectorDecisionKind.selectSpeaker);
    expect(decision.assistantId, 'a1');

    await pumpEventQueue();
    expect(transport.subscriptionCancelled, isTrue);

    final handler = transport.toolCallHandler;
    expect(handler, isNotNull);
    final result = await handler!(
      DirectorTools.selectSpeaker,
      const <String, dynamic>{'assistant_id': 'a1'},
      toolCallId: 't2',
    );
    final decoded = jsonDecode(result) as Map<String, dynamic>;
    expect(decoded['ok'], isTrue);
    expect(result, isNot(contains('ignored')));
  });

  test(
    'follow-up tool calls in the same stream stay neutral (no retry bait)',
    () async {
      final future = runDirector();

      transport.controller.add(
        ChatStreamChunk(
          content: '',
          isDone: false,
          totalTokens: 0,
          toolCalls: <ToolCallInfo>[
            ToolCallInfo(
              id: 't1',
              name: DirectorTools.selectSpeaker,
              arguments: const <String, dynamic>{'assistant_id': 'a1'},
            ),
          ],
        ),
      );
      final decision = await future.timeout(const Duration(seconds: 5));
      expect(decision.assistantId, 'a1');

      // Provider keeps sending follow-up calls before the cancel lands.
      final handler = transport.toolCallHandler!;
      final first = await handler(
        DirectorTools.selectSpeaker,
        const <String, dynamic>{'assistant_id': 'a2'},
        toolCallId: 't2',
      );
      final second = await handler(
        DirectorTools.endTurn,
        const <String, dynamic>{'reason': 'x'},
        toolCallId: 't3',
      );
      expect(first, isNot(contains('ignored')));
      expect(second, isNot(contains('ignored')));
      expect(jsonDecode(first)['ok'], isTrue);
      expect(jsonDecode(second)['ok'], isTrue);
    },
  );
}
