import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';

import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/codex_device_code_controller.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/provider/pages/provider_detail_page.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/codex_account_entry.dart';

var businessPrefs = BusinessPreferences.memoryForTests();

Future<SettingsProvider> _createSettings(
  WidgetTester tester, {
  required String keyName,
  required ProviderKind kind,
  required String baseUrl,
  bool multiKey = false,
}) async {
  businessPrefs = BusinessPreferences.memoryForTests({});
  final settings = SettingsProvider(preferences: businessPrefs);
  // Drain the async _load() kicked off by the SettingsProvider constructor so
  // the setProviderConfig below does not race an in-flight load.
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();
  await settings.setProviderConfig(
    keyName,
    ProviderConfig(
      id: keyName,
      enabled: true,
      name: keyName,
      apiKey: 'test-key',
      baseUrl: baseUrl,
      providerType: kind,
      multiKeyEnabled: multiKey,
      models: const ['gpt-4o'],
    ),
  );
  return settings;
}

Widget _harness(
  SettingsProvider settings,
  CodexDeviceCodeController controller, {
  required String keyName,
  required String displayName,
}) {
  return MultiProvider(
    providers: [
      Provider<BusinessPreferences>.value(value: businessPrefs),
      ChangeNotifierProvider<SettingsProvider>.value(value: settings),
      ChangeNotifierProvider<AssistantProvider>(
        create: (_) => AssistantProvider(preferences: businessPrefs),
      ),
      ChangeNotifierProvider<CodexDeviceCodeController>.value(
        value: controller,
      ),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ProviderDetailPage(keyName: keyName, displayName: displayName),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late CodexDeviceCodeController controller;

  setUp(() {
    businessPrefs = BusinessPreferences.memoryForTests();
    businessPrefs = BusinessPreferences.memoryForTests({});
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
    final settings = await _createSettings(
      tester,
      keyName: 'OpenAI',
      kind: ProviderKind.openai,
      baseUrl: 'https://api.openai.com/v1',
    );
    addTearDown(settings.dispose);

    await tester.pumpWidget(
      _harness(settings, controller, keyName: 'OpenAI', displayName: 'OpenAI'),
    );
    await tester.pumpAndSettle();

    expect(find.byType(CodexAccountEntry, skipOffstage: false), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('multiKey OpenAI hides the Codex account entry', (tester) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final settings = await _createSettings(
      tester,
      keyName: 'OpenAI',
      kind: ProviderKind.openai,
      baseUrl: 'https://api.openai.com/v1',
      multiKey: true,
    );
    addTearDown(settings.dispose);

    await tester.pumpWidget(
      _harness(settings, controller, keyName: 'OpenAI', displayName: 'OpenAI'),
    );
    await tester.pumpAndSettle();

    expect(find.byType(CodexAccountEntry, skipOffstage: false), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('claude provider never shows the Codex account entry', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final settings = await _createSettings(
      tester,
      keyName: 'Claude',
      kind: ProviderKind.claude,
      baseUrl: 'https://api.anthropic.com/v1',
    );
    addTearDown(settings.dispose);

    await tester.pumpWidget(
      _harness(settings, controller, keyName: 'Claude', displayName: 'Claude'),
    );
    await tester.pumpAndSettle();

    expect(find.byType(CodexAccountEntry, skipOffstage: false), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('gemini provider never shows the Codex account entry', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final settings = await _createSettings(
      tester,
      keyName: 'Gemini',
      kind: ProviderKind.google,
      baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
    );
    addTearDown(settings.dispose);

    await tester.pumpWidget(
      _harness(settings, controller, keyName: 'Gemini', displayName: 'Gemini'),
    );
    await tester.pumpAndSettle();

    expect(find.byType(CodexAccountEntry, skipOffstage: false), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'custom openai provider on a codex host shows the account entry',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final settings = await _createSettings(
        tester,
        keyName: 'MyCodex',
        kind: ProviderKind.openai,
        baseUrl: 'https://chatgpt.com/backend-api/codex',
      );
      addTearDown(settings.dispose);

      await tester.pumpWidget(
        _harness(
          settings,
          controller,
          keyName: 'MyCodex',
          displayName: 'MyCodex',
        ),
      );
      await tester.pumpAndSettle();

      // A user-added openai provider pointed at the codex host is treated
      // like the built-in codex provider.
      expect(
        find.byType(CodexAccountEntry, skipOffstage: false),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'custom openai provider on a non-codex host hides the account entry',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final settings = await _createSettings(
        tester,
        keyName: 'MyProxy',
        kind: ProviderKind.openai,
        baseUrl: 'https://myproxy.example.com/v1',
      );
      addTearDown(settings.dispose);

      await tester.pumpWidget(
        _harness(
          settings,
          controller,
          keyName: 'MyProxy',
          displayName: 'MyProxy',
        ),
      );
      await tester.pumpAndSettle();

      // A user-added openai provider on an ordinary proxy host is neither
      // the built-in OpenAI id nor a codex host: no account entry may appear.
      expect(find.byType(CodexAccountEntry, skipOffstage: false), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'built-in Codex provider shows the account entry on a non-codex host',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final settings = await _createSettings(
        tester,
        keyName: 'Codex',
        kind: ProviderKind.openai,
        baseUrl: 'https://api.openai.com/v1',
      );
      addTearDown(settings.dispose);

      await tester.pumpWidget(
        _harness(settings, controller, keyName: 'Codex', displayName: 'Codex'),
      );
      await tester.pumpAndSettle();

      // The provider id itself grants the entry even when the baseUrl is not
      // a codex host: the id branch of showEntryFor.
      expect(
        find.byType(CodexAccountEntry, skipOffstage: false),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'custom openai provider on a trailing-slash codex host shows the entry',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final settings = await _createSettings(
        tester,
        keyName: 'MyCodexSlash',
        kind: ProviderKind.openai,
        baseUrl: 'https://chatgpt.com/backend-api/codex/',
      );
      addTearDown(settings.dispose);

      await tester.pumpWidget(
        _harness(
          settings,
          controller,
          keyName: 'MyCodexSlash',
          displayName: 'MyCodexSlash',
        ),
      );
      await tester.pumpAndSettle();

      // isCodexHost tolerates a trailing slash on the codex path.
      expect(
        find.byType(CodexAccountEntry, skipOffstage: false),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'custom openai provider on a near-codex path hides the account entry',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final settings = await _createSettings(
        tester,
        keyName: 'MyCodexNear',
        kind: ProviderKind.openai,
        baseUrl: 'https://chatgpt.com/backend-api/notcodex',
      );
      addTearDown(settings.dispose);

      await tester.pumpWidget(
        _harness(
          settings,
          controller,
          keyName: 'MyCodexNear',
          displayName: 'MyCodexNear',
        ),
      );
      await tester.pumpAndSettle();

      // The path match must be exact: a sibling path on the same host is not
      // a codex endpoint and must not show the entry.
      expect(find.byType(CodexAccountEntry, skipOffstage: false), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
