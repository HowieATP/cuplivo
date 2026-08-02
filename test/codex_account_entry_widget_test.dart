import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/providers/codex_device_code_controller.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/l10n/app_localizations_en.dart';
import 'package:Cuplivo/shared/widgets/codex_account_entry.dart';
import 'package:Cuplivo/shared/widgets/snackbar.dart';

final AppLocalizations _l10n = AppLocalizationsEn();

// showAppSnackBar default duration is 3s plus a 300ms exit animation. The
// pumps below intentionally carry a margin: the exit animation only starts
// ticking when the 3s timer fires, and fake_async gives the first tick a
// zero elapsed, so an exact 3s+300ms drain can leave the ticker running.
const _snackbarDrain = Duration(seconds: 4);
const _snackbarExitAnimation = Duration(milliseconds: 400);

class _HangingClient extends http.BaseClient {
  final List<Completer<http.StreamedResponse>> _pending = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final completer = Completer<http.StreamedResponse>();
    _pending.add(completer);
    return completer.future;
  }

  /// Completes every pending request with an error so in-flight timeouts and
  /// the flow's poll loop wind down before the test tears the tree down.
  void releaseAll() {
    for (final c in _pending) {
      if (!c.isCompleted) {
        c.completeError(http.ClientException('cancelled by test'));
      }
    }
    _pending.clear();
  }
}

class _ThrowingSignOutController extends CodexDeviceCodeController {
  @override
  Future<void> signOut() async {
    throw Exception('signOut boom');
  }
}

CodexOAuthCredential _cred(String accountId) => CodexOAuthCredential(
  accessToken: 'at-1',
  refreshToken: 'rt-1',
  expiresAt: DateTime.now().add(const Duration(hours: 1)),
  accountId: accountId,
);

Widget _harness(
  CodexDeviceCodeController controller, {
  SettingsProvider? settings,
}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<CodexDeviceCodeController>.value(
        value: controller,
      ),
      if (settings != null)
        ChangeNotifierProvider<SettingsProvider>.value(value: settings),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: AppSnackBarOverlay(
        child: Scaffold(body: CodexAccountEntry(cfg: codexProviderConfig())),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late CodexDeviceCodeController controller;

  setUp(() {
    SharedPreferences.setMockInitialValues(const {});
    controller = CodexDeviceCodeController();
    CodexDeviceCodeController.debugOverrideInstance(controller);
  });

  tearDown(() {
    controller.resetForTest();
    CodexDeviceCodeController.debugOverrideInstance(
      CodexDeviceCodeController(),
    );
  });

  testWidgets('signedOut state shows the sign-in button', (tester) async {
    await tester.pumpWidget(_harness(controller));
    await tester.pump();

    expect(controller.status, CodexAuthStatus.signedOut);
    expect(find.text(_l10n.codexLoginSignInButton), findsOneWidget);
    expect(find.text(_l10n.codexLoginSignOutButton), findsNothing);
  });

  testWidgets('signedIn state shows account id and sign-out button', (
    tester,
  ) async {
    controller.credential = _cred('acc-1');
    controller.status = CodexAuthStatus.signedIn;

    await tester.pumpWidget(_harness(controller));
    await tester.pump();

    expect(find.text(_l10n.codexLoginStatusSignedIn), findsOneWidget);
    expect(find.textContaining('acc-1'), findsOneWidget);
    expect(find.text(_l10n.codexLoginSignOutButton), findsOneWidget);
  });

  testWidgets('expired state shows expired copy and re-login button', (
    tester,
  ) async {
    controller.status = CodexAuthStatus.expired;

    await tester.pumpWidget(_harness(controller));
    await tester.pump();

    expect(find.text(_l10n.codexLoginStatusExpired), findsOneWidget);
    expect(find.text(_l10n.codexLoginSignInButton), findsOneWidget);
  });

  testWidgets('waitingForUser state shows the waiting copy', (tester) async {
    controller.status = CodexAuthStatus.waitingForUser;

    await tester.pumpWidget(_harness(controller));
    await tester.pump();

    expect(find.text(_l10n.codexLoginStatusWaiting), findsOneWidget);
    expect(find.text(_l10n.codexLoginSignInButton), findsNothing);
  });

  testWidgets('sign-out confirm dialog uses confirm copy and calls signOut', (
    tester,
  ) async {
    controller.credential = _cred('acc-1');
    controller.status = CodexAuthStatus.signedIn;

    await tester.pumpWidget(_harness(controller));
    await tester.pump();

    await tester.tap(find.text(_l10n.codexLoginSignOutButton));
    await tester.pumpAndSettle();

    expect(find.text(_l10n.codexLoginSignOutConfirm), findsOneWidget);

    await tester.tap(
      find.widgetWithText(TextButton, _l10n.codexLoginSignOutButton),
    );
    await tester.pumpAndSettle();

    expect(controller.status, CodexAuthStatus.signedOut);
    expect(controller.credential, isNull);

    // Let the success toast timer elapse so no timers are left pending.
    await tester.pump(_snackbarDrain);
    await tester.pump(_snackbarExitAnimation);
  });

  testWidgets('signOut failure shows the network-error snackbar', (
    tester,
  ) async {
    final throwing = _ThrowingSignOutController();
    CodexDeviceCodeController.debugOverrideInstance(throwing);
    addTearDown(throwing.resetForTest);
    throwing.credential = _cred('acc-1');
    throwing.status = CodexAuthStatus.signedIn;

    await tester.pumpWidget(_harness(throwing));
    await tester.pump();

    await tester.tap(find.text(_l10n.codexLoginSignOutButton));
    await tester.pumpAndSettle();

    await tester.tap(
      find.widgetWithText(TextButton, _l10n.codexLoginSignOutButton),
    );
    await tester.pumpAndSettle();

    expect(find.text(_l10n.codexLoginNetworkError), findsOneWidget);
    expect(throwing.status, CodexAuthStatus.signedIn);
    expect(throwing.credential, isNotNull);

    // Let the snackbar timer elapse so no timers are left pending.
    await tester.pump(_snackbarDrain);
    await tester.pump(_snackbarExitAnimation);
  });

  testWidgets('sign-out confirm dialog cancel keeps signed in', (tester) async {
    controller.credential = _cred('acc-1');
    controller.status = CodexAuthStatus.signedIn;

    await tester.pumpWidget(_harness(controller));
    await tester.pump();

    await tester.tap(find.text(_l10n.codexLoginSignOutButton));
    await tester.pumpAndSettle();

    await tester.tap(find.text(_l10n.codexLoginCancelButton));
    await tester.pumpAndSettle();

    expect(controller.status, CodexAuthStatus.signedIn);
    expect(controller.credential, isNotNull);
  });

  testWidgets('tapping the sign-in button opens the flow', (tester) async {
    final hangingClient = _HangingClient();
    final hanging = CodexDeviceCodeController(
      clientFactory: (_) => hangingClient,
    );
    CodexDeviceCodeController.debugOverrideInstance(hanging);
    addTearDown(hanging.resetForTest);
    final settings = SettingsProvider();
    addTearDown(settings.dispose);

    await tester.pumpWidget(_harness(hanging, settings: settings));
    await tester.pump();

    try {
      await tester.tap(find.text(_l10n.codexLoginSignInButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(hanging.status, CodexAuthStatus.waitingForUser);
      // Usercode label only exists inside the flow's waiting screen.
      expect(find.text(_l10n.codexLoginUsercodeLabel), findsOneWidget);
    } finally {
      // Dispose the flow so its countdown timer and cancel signal are
      // cleaned up, then release the in-flight usercode request so no 30s
      // timeout timer is left pending after the tree is gone.
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      hangingClient.releaseAll();
    }
    await tester.pump();
  });
}
