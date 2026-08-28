import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';

import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/mcp_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/mcp/mcp_tool_service.dart';
import 'package:Cuplivo/core/services/search/search_tool_service.dart';
import 'package:Cuplivo/features/home/services/message_builder_service.dart';
import 'package:Cuplivo/features/home/services/tool_handler_service.dart';

var businessPrefs = BusinessPreferences.memoryForTests();

class _FakeBuildContext implements BuildContext {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('per-assistant search behavior', () {
    test('does not inject search prompt (moved to tool description)', () {
      businessPrefs = BusinessPreferences.memoryForTests({});
      final service = MessageBuilderService(
        preferences: businessPrefs,
        chatService: ChatService(),
        contextProvider: _FakeBuildContext(),
      );

      final disabledMessages = <Map<String, dynamic>>[
        {'role': 'user', 'content': 'latest news'},
      ];
      service.injectSearchPrompt(
        disabledMessages,
        SettingsProvider(preferences: businessPrefs),
        Assistant(id: 'assistant-a', name: 'A'),
        false,
      );

      final enabledMessages = <Map<String, dynamic>>[
        {'role': 'user', 'content': 'latest news'},
      ];
      service.injectSearchPrompt(
        enabledMessages,
        SettingsProvider(preferences: businessPrefs),
        Assistant(id: 'assistant-b', name: 'B', searchEnabled: true),
        false,
      );

      expect(disabledMessages.length, 1);
      expect(disabledMessages.first['role'], 'user');
      expect(enabledMessages.length, 1);
      expect(enabledMessages.first['role'], 'user');
    });

    testWidgets('builds search tools only when the assistant enables search', (
      tester,
    ) async {
      businessPrefs = BusinessPreferences.memoryForTests({});
      final settings = SettingsProvider(preferences: businessPrefs);

      late List<Map<String, dynamic>> disabledTools;
      late List<Map<String, dynamic>> enabledTools;
      late List<Map<String, dynamic>> unsupportedTools;
      late List<Map<String, dynamic>> builtInSearchTools;
      late Future<String> Function(
        String name,
        Map<String, dynamic> args, {
        String? toolCallId,
      })
      handler;
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider<BusinessPreferences>.value(value: businessPrefs),
            ChangeNotifierProvider<AssistantProvider>(
              create: (_) => AssistantProvider(preferences: businessPrefs),
            ),
            ChangeNotifierProvider<McpProvider>(
              create: (_) => McpProvider(
                preferences: businessPrefs,
                contextProvider: () => throw UnimplementedError(),
              ),
            ),
            ChangeNotifierProvider<McpToolService>(
              create: (_) => McpToolService(),
            ),
          ],
          child: Builder(
            builder: (context) {
              final service = ToolHandlerService(contextProvider: context);
              disabledTools = service.buildToolDefinitions(
                settings,
                Assistant(id: 'assistant-a', name: 'A'),
                'openai',
                'gpt-4.1',
                false,
                isToolModel: (_, _) => true,
              );
              enabledTools = service.buildToolDefinitions(
                settings,
                Assistant(id: 'assistant-b', name: 'B', searchEnabled: true),
                'openai',
                'gpt-4.1',
                false,
                isToolModel: (_, _) => true,
              );
              unsupportedTools = service.buildToolDefinitions(
                settings,
                Assistant(id: 'assistant-c', name: 'C', searchEnabled: true),
                'openai',
                'gpt-no-tools',
                false,
                isToolModel: (_, _) => false,
              );
              builtInSearchTools = service.buildToolDefinitions(
                settings,
                Assistant(id: 'assistant-d', name: 'D', searchEnabled: true),
                'openai',
                'gpt-4.1',
                true,
                isToolModel: (_, _) => true,
              );
              handler = service.buildToolCallHandler(
                settings,
                Assistant(id: 'assistant-b', name: 'B', searchEnabled: true),
              )!;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(disabledTools, isEmpty);
      expect(enabledTools.map((tool) => tool['function']['name']), [
        SearchToolService.toolName,
        SearchToolService.fetchToolName,
      ]);
      expect(unsupportedTools, isEmpty);
      expect(builtInSearchTools, isEmpty);
      final fetchResult =
          jsonDecode(
                await handler(SearchToolService.fetchToolName, {
                  'url': 'not-a-url',
                }),
              )
              as Map<String, dynamic>;
      expect(fetchResult['error'], contains('Invalid URL'));
    });
  });
}
