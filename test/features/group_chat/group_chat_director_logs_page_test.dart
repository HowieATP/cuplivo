import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/models/group_chat.dart';
import 'package:Cuplivo/core/models/group_chat_director_log.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/group_chat_provider.dart';
import 'package:Cuplivo/core/providers/user_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/features/group_chat/pages/group_chat_director_logs_page.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeChatService extends ChatService {
  _FakeChatService(this.messages, this.conversation);

  final List<ChatMessage> messages;
  final Conversation conversation;

  @override
  List<ChatMessage> getMessages(String conversationId) => messages;

  @override
  Conversation? getConversation(String conversationId) => conversation;

  @override
  List<Map<String, dynamic>> getToolEvents(String messageId) => const [];
}

class _FakeGroupChatProvider extends GroupChatProvider {
  _FakeGroupChatProvider({
    required super.chatService,
    required this.group,
    required this.assistantIds,
    this.runtimeLogs = const [],
  });

  final GroupChat group;
  final List<String> assistantIds;
  final List<GroupChatDirectorRuntimeLog> runtimeLogs;

  @override
  GroupChat? getById(String id) => id == group.id ? group : null;

  @override
  List<String> assistantIdsOf(String groupChatId) => assistantIds;

  @override
  List<GroupChatDirectorRuntimeLog> directorRuntimeLogs(String groupChatId) {
    return runtimeLogs;
  }
}

class _FakeAssistantProvider extends AssistantProvider {
  _FakeAssistantProvider(this.items) : super();

  final List<Assistant> items;

  @override
  List<Assistant> get assistants => items;
}

class _FakeUserProvider extends UserProvider {
  _FakeUserProvider(this.value) : super();

  final String value;

  @override
  String get name => value;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('cards start collapsed and reveal context and runtime details', (
    tester,
  ) async {
    final assistant = Assistant(id: 'a1', name: 'Alpha');
    final group = GroupChat(
      id: 'g1',
      name: 'Room',
      conversationId: 'c1',
      directorSystemPrompt: 'You are the director.',
    );
    final userMessage = ChatMessage(
      id: 'u1',
      role: 'user',
      content: 'Hello',
      conversationId: 'c1',
    );
    final assistantMessage = ChatMessage(
      id: 'a1-message',
      role: 'assistant',
      content: 'Hi',
      conversationId: 'c1',
      speakerAssistantId: assistant.id,
    );
    final chatService = _FakeChatService(
      [userMessage, assistantMessage],
      Conversation(
        id: 'c1',
        title: 'Room',
        conversationKind: Conversation.kindGroup,
      ),
    );
    final runtimeLog = GroupChatDirectorRuntimeLog(
      sourceMessageId: userMessage.id,
      trigger: GroupChatDirectorLogTrigger.user,
      startedAt: DateTime(2026),
      finishedAt: DateTime(2026, 1, 1, 0, 1),
      providerKey: 'provider',
      modelId: 'model',
      requestMessageCount: 2,
      attemptCount: 1,
      attemptErrors: const [],
      decisionKind: 'selectSpeaker',
      assistantId: assistant.id,
      reason: 'because',
    );

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ChatService>.value(value: chatService),
          ChangeNotifierProvider<GroupChatProvider>.value(
            value: _FakeGroupChatProvider(
              chatService: chatService,
              group: group,
              assistantIds: [assistant.id],
              runtimeLogs: [runtimeLog],
            ),
          ),
          ChangeNotifierProvider<AssistantProvider>.value(
            value: _FakeAssistantProvider([assistant]),
          ),
          ChangeNotifierProvider<UserProvider>.value(
            value: _FakeUserProvider('User'),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const GroupChatDirectorLogsPage(groupChatId: 'g1'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Reconstructed director context'), findsNothing);
    expect(find.text('Runtime details'), findsNothing);

    await tester.tap(find.text('Director call 1'));
    await tester.pumpAndSettle();

    expect(find.text('Reconstructed director context'), findsOneWidget);
    expect(find.text('Runtime details'), findsOneWidget);
    expect(find.text('Reason: because', findRichText: true), findsOneWidget);
  });
}
