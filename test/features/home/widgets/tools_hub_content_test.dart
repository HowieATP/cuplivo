import 'dart:io';

import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/mcp_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/providers/workspace_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/features/home/widgets/tools_hub_content.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/ios_form_text_field.dart';
import 'package:Cuplivo/shared/widgets/ios_switch.dart';
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
  int setDirectoryOverrideCalls = 0;
  int clearDirectoryOverrideCalls = 0;

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
    setDirectoryOverrideCalls++;
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
    clearDirectoryOverrideCalls++;
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

  Future<_FakeChatService> pumpHub(
    WidgetTester tester, {
    required Assistant assistant,
    required Conversation conversation,
    required String? conversationId,
  }) async {
    late BuildContext providerContext;
    final chatService = _FakeChatService(conversation);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(
            value: await assistantProvider(assistant),
          ),
          ChangeNotifierProvider.value(value: SettingsProvider()),
          ChangeNotifierProvider.value(value: workspaces),
          ChangeNotifierProvider<ChatService>.value(value: chatService),
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
    return chatService;
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
    expect(find.text(l10n.workspaceAutoLoadAgentsMdTitle), findsOneWidget);
    expect(find.text(l10n.workspaceDirectoryBrowse), findsOneWidget);
    expect(find.text(l10n.workspaceDirectorySave), findsOneWidget);
    expect(find.text(l10n.workspaceEnableTitle), findsNothing);
  });

  testWidgets('AGENTS.md loading switch saves the assistant setting', (
    tester,
  ) async {
    final workspace = workspaces.defaultWorkspace!;
    final assistant = Assistant(
      id: 'a1',
      name: 'Assistant',
      workspaceEnabled: true,
      workspaceId: workspace.id,
    );
    final conversation = Conversation(id: 'c1', title: 'Conversation');
    await pumpHub(
      tester,
      assistant: assistant,
      conversation: conversation,
      conversationId: conversation.id,
    );
    final context = tester.element(find.byType(ToolsHubContent));
    final l10n = AppLocalizations.of(context)!;

    await tester.tap(find.text(l10n.workspaceDirectoryPickerTitle));
    await tester.pumpAndSettle();

    final agentsSwitch = find.byWidgetPredicate(
      (widget) =>
          widget is IosSwitch &&
          widget.semanticLabel == l10n.workspaceAutoLoadAgentsMdTitle,
    );
    expect(agentsSwitch, findsOneWidget);
    expect(tester.widget<IosSwitch>(agentsSwitch).value, isTrue);

    await tester.tap(agentsSwitch);
    await tester.pumpAndSettle();

    expect(
      context.read<AssistantProvider>().getById(assistant.id)!.autoLoadAgentsMd,
      isFalse,
    );
    final prefs = await SharedPreferences.getInstance();
    expect(
      Assistant.decodeList(
        prefs.getString('assistants_v1')!,
      ).single.autoLoadAgentsMd,
      isFalse,
    );
  });

  for (final override in <String>[
    '/workspace/project',
    '/workspace/project/./src/..',
  ]) {
    testWidgets(
      'equivalent conversation directory $override is inherited and pruned',
      (tester) async {
        final workspace = workspaces.defaultWorkspace!;
        final assistant = Assistant(
          id: 'a1',
          name: 'Assistant',
          workspaceEnabled: true,
          workspaceId: workspace.id,
          workspaceDefaultDirectories: {workspace.id: '/workspace/project'},
        );
        final conversation = Conversation(
          id: 'c1',
          title: 'Conversation',
          workspaceDirectoryOverrides: {workspace.id: override},
        );
        await pumpHub(
          tester,
          assistant: assistant,
          conversation: conversation,
          conversationId: conversation.id,
        );
        final context = tester.element(find.byType(ToolsHubContent));
        final l10n = AppLocalizations.of(context)!;

        await tester.tap(find.text(l10n.workspaceDirectoryPickerTitle));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(find.text(l10n.workspaceDirectoryInherited), findsOneWidget);
        expect(find.text(l10n.workspaceDirectoryOverride), findsNothing);
        expect(
          find.text(l10n.workspaceDirectoryUseAssistantDefault),
          findsNothing,
        );
        expect(
          conversation.workspaceDirectoryOverrides.containsKey(workspace.id),
          isFalse,
        );
      },
    );
  }

  testWidgets('invalid conversation directory remains an explicit override', (
    tester,
  ) async {
    final workspace = workspaces.defaultWorkspace!;
    final assistant = Assistant(
      id: 'a1',
      name: 'Assistant',
      workspaceEnabled: true,
      workspaceId: workspace.id,
      workspaceDefaultDirectories: {workspace.id: '/workspace/project'},
    );
    final conversation = Conversation(
      id: 'c1',
      title: 'Conversation',
      workspaceDirectoryOverrides: {workspace.id: '/tmp/outside'},
    );
    await pumpHub(
      tester,
      assistant: assistant,
      conversation: conversation,
      conversationId: conversation.id,
    );
    final context = tester.element(find.byType(ToolsHubContent));
    final l10n = AppLocalizations.of(context)!;

    await tester.tap(find.text(l10n.workspaceDirectoryPickerTitle));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text(l10n.workspaceDirectoryOverride), findsOneWidget);
    expect(
      find.text(l10n.workspaceDirectoryUseAssistantDefault),
      findsOneWidget,
    );
    expect(
      conversation.workspaceDirectoryOverrides[workspace.id],
      '/tmp/outside',
    );
  });

  testWidgets(
    'saving the assistant default clears a different conversation override',
    (tester) async {
      final workspace = workspaces.defaultWorkspace!;
      final assistant = Assistant(
        id: 'a1',
        name: 'Assistant',
        workspaceEnabled: true,
        workspaceId: workspace.id,
        workspaceDefaultDirectories: {workspace.id: '/workspace/project'},
      );
      final conversation = Conversation(
        id: 'c1',
        title: 'Conversation',
        workspaceDirectoryOverrides: {workspace.id: '/workspace/other'},
      );
      final chatService = await pumpHub(
        tester,
        assistant: assistant,
        conversation: conversation,
        conversationId: conversation.id,
      );
      final context = tester.element(find.byType(ToolsHubContent));
      final l10n = AppLocalizations.of(context)!;

      await tester.tap(find.text(l10n.workspaceDirectoryPickerTitle));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.text(l10n.workspaceDirectoryUseAssistantDefault),
        findsOneWidget,
      );

      final directoryField = find.descendant(
        of: find.byType(IosFormTextField),
        matching: find.byType(TextField),
      );
      expect(directoryField, findsOneWidget);
      await tester.enterText(directoryField, '/workspace/project/./src/..');
      expect(
        tester.widget<TextField>(directoryField).controller!.text,
        '/workspace/project/./src/..',
      );
      await tester.tap(find.text(l10n.workspaceDirectorySave));
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();

      expect(chatService.clearDirectoryOverrideCalls, 1);
      expect(
        conversation.workspaceDirectoryOverrides.containsKey(workspace.id),
        isFalse,
      );
      expect(find.text(l10n.workspaceDirectoryInherited), findsOneWidget);
      expect(
        find.text(l10n.workspaceDirectoryUseAssistantDefault),
        findsNothing,
      );
    },
  );
}
