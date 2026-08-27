import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';

import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/providers/tts_provider.dart';
import 'package:Cuplivo/core/services/haptics.dart';
import 'package:Cuplivo/features/chat/widgets/chat_message_widget.dart';
import 'package:Cuplivo/features/home/services/ask_user_interaction_service.dart';
import 'package:Cuplivo/features/home/services/tool_approval_service.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/ios_tactile.dart';

var businessPrefs = BusinessPreferences.memoryForTests();

SettingsProvider _createSettings() {
  businessPrefs = BusinessPreferences.memoryForTests(const <String, Object>{});
  return SettingsProvider(preferences: businessPrefs);
}

Widget _buildHarness({
  required SettingsProvider settings,
  required Widget child,
}) {
  return MultiProvider(
    providers: [
      Provider<BusinessPreferences>.value(value: businessPrefs),
      ChangeNotifierProvider<SettingsProvider>.value(value: settings),
      ChangeNotifierProvider(
        create: (_) => TtsProvider(preferences: businessPrefs),
      ),
      ChangeNotifierProvider(create: (_) => ToolApprovalService()),
      ChangeNotifierProvider(create: (_) => AskUserInteractionService()),
    ],
    child: MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    ),
  );
}

const ToolUIPart _loadingCalculatePart = ToolUIPart(
  id: 'calc-1',
  toolName: 'calculate',
  arguments: {'expression': '12212/2'},
  loading: true,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('tool detail sheet stale-context race', () {
    testWidgets(
      'sheet stays healthy when the tool card is unmounted mid-animation',
      (tester) async {
        Haptics.setEnabled(false);
        final settings = _createSettings();

        Widget buildCard(Key key, List<ToolUIPart> parts) => _buildHarness(
          settings: settings,
          child: ChatMessageWidget(
            key: key,
            message: ChatMessage(
              role: 'assistant',
              content: '',
              conversationId: 'conv-calc',
            ),
            showModelIcon: false,
            toolParts: parts,
          ),
        );

        await tester.pumpWidget(
          buildCard(const ValueKey('card'), const [_loadingCalculatePart]),
        );
        await tester.pump();

        final title = find.text('计算器');
        expect(title, findsOneWidget);
        await tester.tap(
          find.ancestor(of: title, matching: find.byType(IosCardPress)).first,
        );
        await tester.pump();

        await tester.pumpWidget(
          buildCard(const ValueKey('card-replaced'), const <ToolUIPart>[]),
        );
        await tester.pump();

        await tester.pump(const Duration(milliseconds: 120));
        await tester.pump(const Duration(milliseconds: 120));
        await tester.pump(const Duration(milliseconds: 200));

        expect(tester.takeException(), isNull);
        expect(find.byType(BottomSheet), findsOneWidget);
      },
    );
  });

  group('Haptics', () {
    testWidgets('soft haptic swallows async platform channel errors', (
      tester,
    ) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          throw PlatformException(code: 'boom');
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      Haptics.setEnabled(true);
      Haptics.soft();
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });
}
