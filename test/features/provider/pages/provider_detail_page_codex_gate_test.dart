import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/codex_device_code_controller.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/provider/pages/provider_detail_page.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/codex_account_entry.dart';

Future<SettingsProvider> _createSettings(
  WidgetTester tester, {
  required bool multiKey,
}) async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsProvider();
  // Drain the async _load() kicked off by the SettingsProvider constructor so
  // the setProviderConfig below does not race an in-flight load.
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();
  await settings.setProviderConfig(
    'OpenAI',
    ProviderConfig(
      id: 'OpenAI',
      enabled: true,
      name: 'OpenAI',
      apiKey: 'test-key',
      baseUrl: 'https://api.openai.com/v1',
      providerType: ProviderKind.openai,
      multiKeyEnabled: multiKey,
      models: const ['gpt-4o'],
    ),
  );
  return settings;
}

Widget _harness(
  SettingsProvider settings,
  CodexDeviceCodeController controller,
) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<SettingsProvider>.value(value: settings),
      ChangeNotifierProvider<AssistantProvider>(
        create: (_) => AssistantProvider(),
      ),
      ChangeNotifierProvider<CodexDeviceCodeController>.value(
        value: controller,
      ),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const ProviderDetailPage(keyName: 'OpenAI', displayName: 'OpenAI'),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late CodexDeviceCodeController controller;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    controller = CodexDeviceCodeController();
    CodexDeviceCodeController.debugOverrideInstance(controller);
  });

  tearDown(() {
    controller.resetForTest();
    CodexDeviceCodeController.debugOverrideInstance(
      CodexDeviceCodeController(),
    );
  });

  testWidgets('built-in OpenAI shows the Codex account entry', (tester) async {
    // Tall viewport so the config tab's entry card is on stage: the lazy
    // ListView below the fold keeps the widget built but offstage.
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final settings = await _createSettings(tester, multiKey: false);
    addTearDown(settings.dispose);

    await tester.pumpWidget(_harness(settings, controller));
    await tester.pumpAndSettle();

    expect(find.byType(CodexAccountEntry), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('multiKey OpenAI hides the Codex account entry', (tester) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final settings = await _createSettings(tester, multiKey: true);
    addTearDown(settings.dispose);

    await tester.pumpWidget(_harness(settings, controller));
    await tester.pumpAndSettle();

    expect(find.byType(CodexAccountEntry, skipOffstage: false), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
