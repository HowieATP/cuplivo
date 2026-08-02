import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/providers/codex_device_code_controller.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/codex_account_entry.dart';

CodexOAuthCredential _cred(String accountId) => CodexOAuthCredential(
  accessToken: 'at-1',
  refreshToken: 'rt-1',
  expiresAt: DateTime.now().add(const Duration(hours: 1)),
  accountId: accountId,
);

Future<void> _waitForSettingsLoad() async {
  for (var i = 0; i < 25; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<SettingsProvider> _buildSettings(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues(const {});
  final settings = SettingsProvider();
  await tester.runAsync(_waitForSettingsLoad);
  return settings;
}

Widget _harness(SettingsProvider settings, CodexDeviceCodeController controller) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<CodexDeviceCodeController>.value(
        value: controller,
      ),
      ChangeNotifierProvider<SettingsProvider>.value(value: settings),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: CodexAccountEntry(cfg: codexProviderConfig())),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late CodexDeviceCodeController controller;

  setUp(() {
    controller = CodexDeviceCodeController();
    CodexDeviceCodeController.debugOverrideInstance(controller);
  });

  tearDown(() {
    controller.resetForTest();
  });

  testWidgets('signedOut state shows the sign-in button', (tester) async {
    final settings = await _buildSettings(tester);
    addTearDown(settings.dispose);

    await tester.pumpWidget(_harness(settings, controller));
    await tester.pump();

    expect(controller.status, CodexAuthStatus.signedOut);
    expect(find.text('Sign in with Codex'), findsOneWidget);
    expect(find.text('Sign out'), findsNothing);
  });

  testWidgets('signedIn state shows account id and sign-out button', (
    tester,
  ) async {
    final settings = await _buildSettings(tester);
    addTearDown(settings.dispose);
    controller.credential = _cred('acc-1');
    controller.status = CodexAuthStatus.signedIn;

    await tester.pumpWidget(_harness(settings, controller));
    await tester.pump();

    expect(find.text('Signed in'), findsOneWidget);
    expect(find.textContaining('acc-1'), findsOneWidget);
    expect(find.text('Sign out'), findsOneWidget);
  });

  testWidgets('sign-out confirm dialog uses confirm copy and calls signOut', (
    tester,
  ) async {
    final settings = await _buildSettings(tester);
    addTearDown(settings.dispose);
    controller.credential = _cred('acc-1');
    controller.status = CodexAuthStatus.signedIn;

    await tester.pumpWidget(_harness(settings, controller));
    await tester.pump();

    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();

    expect(
      find.text('This removes the saved ChatGPT credentials from this device.'),
      findsOneWidget,
    );

    await tester.tap(find.text('Sign out').last);
    await tester.pumpAndSettle();

    expect(controller.status, CodexAuthStatus.signedOut);
    expect(controller.credential, isNull);

    // Let the success toast timer elapse so no timers are left pending.
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('sign-out confirm dialog cancel keeps signed in', (tester) async {
    final settings = await _buildSettings(tester);
    addTearDown(settings.dispose);
    controller.credential = _cred('acc-1');
    controller.status = CodexAuthStatus.signedIn;

    await tester.pumpWidget(_harness(settings, controller));
    await tester.pump();

    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(controller.status, CodexAuthStatus.signedIn);
    expect(controller.credential, isNotNull);
  });
}
