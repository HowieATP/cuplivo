import 'dart:io';

import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/mcp_provider.dart';
import 'package:Cuplivo/core/providers/workspace_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/features/home/widgets/tools_hub_content.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);

  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;
}

class _FakeChatService extends ChatService {
  _FakeChatService(this.conversation);

  final Conversation conversation;

  @override
  bool get initialized => true;

  @override
  Conversation? getConversation(String id) =>
      id == conversation.id ? conversation : null;

  @override
  Future<void> setConversationWorkspaceDirectoryOverride(
    String conversationId,
    String workspaceId,
    String directory,
  ) async {
    conversation.workspaceDirectoryOverrides = {
      ...conversation.workspaceDirectoryOverrides,
      workspaceId: directory,
    };
    notifyListeners();
  }

  @override
  Future<void> clearConversationWorkspaceDirectoryOverride(
    String conversationId,
    String workspaceId,
  ) async {
    conversation.workspaceDirectoryOverrides = {
      for (final entry in conversation.workspaceDirectoryOverrides.entries)
        if (entry.key != workspaceId) entry.key: entry.value,
    };
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late PathProviderPlatform originalPathProvider;
  late WorkspaceProvider workspaces;

  setUp(() async {
    originalPathProvider = PathProviderPlatform.instance;
    temp = await Directory.systemTemp.createTemp('tools_hub_directory_');
    PathProviderPlatform.instance = _FakePathProvider(temp.path);
    SharedPreferences.setMockInitialValues({});
    workspaces = WorkspaceProvider();
    await workspaces.init();
  });

  tearDown(() async {
    PathProviderPlatform.instance = originalPathProvider;
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<AssistantProvider> assistantProvider(Assistant assistant) async {
    SharedPreferences.setMockInitialValues({
      'assistants_v1': Assistant.encodeList([assistant]),
    });
    final provider = AssistantProvider();
    await provider.loadFromPrefs();
    return provider;
  }

  Future<void> pumpHub(
    WidgetTester tester, {
    required Assistant assistant,
    required Conversation conversation,
    required String? conversationId,
  }) async {
    late BuildContext providerContext;
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(
            value: await assistantProvider(assistant),
          ),
          ChangeNotifierProvider.value(value: workspaces),
          ChangeNotifierProvider<ChatService>.value(
            value: _FakeChatService(conversation),
          ),
          ChangeNotifierProvider(
            create: (context) {
              providerContext = context;
              return McpProvider(contextProvider: () => providerContext);
            },
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SingleChildScrollView(
              child: ToolsHubContent(
                assistantId: assistant.id,
                conversationId: conversationId,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('working-directory row follows bind and stays disabled unbound', (
    tester,
  ) async {
    final assistant = Assistant(id: 'a1', name: 'Assistant');
    final conversation = Conversation(id: 'c1', title: 'Conversation');
    await pumpHub(
      tester,
      assistant: assistant,
      conversation: conversation,
      conversationId: conversation.id,
    );
    final context = tester.element(find.byType(ToolsHubContent));
    final l10n = AppLocalizations.of(context)!;
    final bind = find.text(l10n.workspaceBindTitle);
    final directory = find.text(l10n.workspaceDirectoryPickerTitle);

    expect(bind, findsOneWidget);
    expect(directory, findsOneWidget);
    expect(
      tester.getTopLeft(bind).dy,
      lessThan(tester.getTopLeft(directory).dy),
    );
    final gestures = tester.widgetList<GestureDetector>(
      find.ancestor(of: directory, matching: find.byType(GestureDetector)),
    );
    expect(gestures.any((gesture) => gesture.onTap != null), isFalse);
  });

  testWidgets('bound row opens the conversation-only directory editor', (
    tester,
  ) async {
    final workspace = workspaces.defaultWorkspace!;
    final assistant = Assistant(
      id: 'a1',
      name: 'Assistant',
      workspaceEnabled: true,
      workspaceId: workspace.id,
      workspaceDefaultDirectories: {
        workspace.id: '/workspace/assistant-default',
      },
    );
    final conversation = Conversation(
      id: 'c1',
      title: 'Conversation',
      workspaceDirectoryOverrides: {workspace.id: '/workspace/conversation'},
    );
    await pumpHub(
      tester,
      assistant: assistant,
      conversation: conversation,
      conversationId: conversation.id,
    );
    final context = tester.element(find.byType(ToolsHubContent));
    final l10n = AppLocalizations.of(context)!;

    expect(find.text('/workspace/conversation'), findsOneWidget);
    await tester.tap(find.text(l10n.workspaceDirectoryPickerTitle));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text(l10n.workspaceDirectoryPickerTitle), findsNWidgets(2));
    expect(find.text(l10n.workspaceConversationDirectoryTitle), findsOneWidget);
    expect(find.text(l10n.workspaceDirectoryBrowse), findsOneWidget);
    expect(find.text(l10n.workspaceDirectorySave), findsOneWidget);
    expect(find.text(l10n.workspaceEnableTitle), findsNothing);
  });
}
