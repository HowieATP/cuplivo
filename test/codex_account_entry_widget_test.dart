import 'dart:async';
import 'dart:convert';

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
import 'package:Cuplivo/shared/widgets/codex_device_code_flow.dart';
import 'package:Cuplivo/shared/widgets/snackbar.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';

var businessPrefs = BusinessPreferences.memoryForTests();

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

/// Scripted client that answers the device-code flow's usercode / poll /
/// exchange requests in order.
class _ScriptedFlowClient extends http.BaseClient {
  final List<http.Response Function(http.Request)> handlers = [];
  // Records poll requests that have no scripted handler so a sequence drift
  // can be asserted separately from the flow's terminal error state.
  final List<String> unexpectedPolls = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final req = http.Request(request.method, request.url)
      ..headers.addAll(request.headers);
    if (request is http.Request) {
      req.body = request.body;
    }
    if (handlers.isEmpty) {
      if (req.url.toString() == kCodexPollEndpoint) {
        unexpectedPolls.add(req.url.toString());
      }
      throw StateError('No scripted handler for ${req.url}');
    }
    final resp = await Future.value(handlers.removeAt(0)(req));
    return http.StreamedResponse(
      Stream<List<int>>.fromIterable([utf8.encode(resp.body)]),
      resp.statusCode,
      headers: resp.headers,
    );
  }
}

/// SettingsProvider whose initial provider-config write fails, then parks a
/// retry until the test releases it. This makes duplicate retry taps
/// observable while the first retry is still in flight.
class _RetryGatedSettingsProvider extends SettingsProvider {
  _RetryGatedSettingsProvider({required super.preferences});
  int calls = 0;
  final Completer<void> retryGate = Completer<void>();

  @override
  Future<void> setProviderConfig(String key, ProviderConfig config) async {
    calls++;
    if (calls == 1) throw Exception('disk full');
    await retryGate.future;
    throw Exception('disk full');
  }
}

http.Response _flowJson(int status, Map<String, dynamic> body) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

String _jwtWithAccount(String accountId) {
  final payload = base64Url
      .encode(
        utf8.encode(
          jsonEncode({
            'iss': 'https://auth.openai.com',
            'https://api.openai.com/auth': {'chatgpt_account_id': accountId},
          }),
        ),
      )
      .replaceAll('=', '');
  return 'eyJhbGciOiJub25lIn0.$payload.c2ln';
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
      Provider<BusinessPreferences>.value(value: businessPrefs),
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
    businessPrefs = BusinessPreferences.memoryForTests();
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
    expect(find.text('${_l10n.codexLoginAccountLabel}: acc-1'), findsOneWidget);
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

  testWidgets('failed state shows the error message and re-login button', (
    tester,
  ) async {
    controller.status = CodexAuthStatus.failed;
    controller.errorMessage = 'Codex device auth was denied or expired';

    await tester.pumpWidget(_harness(controller));
    await tester.pump();

    expect(find.text(_l10n.codexLoginStatusFailed), findsOneWidget);
    expect(
      find.text('Codex device auth was denied or expired'),
      findsOneWidget,
    );
    expect(find.text(_l10n.codexLoginSignInButton), findsOneWidget);
  });

  testWidgets(
    'flow opened while the controller is already polling renders the local '
    'failed fallback with a retry button',
    (tester) async {
      // Pre-existing flow state (e.g. a stale poll loop from a previous
      // attempt): the reentrancy guard rejects the new startFlow, and the
      // widget must fall back to a local failed view with a reachable retry
      // instead of wedging on a permanent waiting spinner.
      controller.status = CodexAuthStatus.polling;

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<CodexDeviceCodeController>.value(
              value: controller,
            ),
            ChangeNotifierProvider<SettingsProvider>(
              create: (_) => SettingsProvider(preferences: businessPrefs),
            ),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: CodexDeviceCodeFlow(cfg: codexProviderConfig()),
            ),
          ),
        ),
      );
      await tester.pump();
      // Non-zero pumps: the deferred startFlow call (Future.delayed
      // Duration.zero) only fires when the fake clock actually advances.
      await tester.pump(const Duration(milliseconds: 10));
      await tester.pump(const Duration(milliseconds: 10));

      expect(find.text(_l10n.codexLoginStatusFailed), findsOneWidget);
      expect(find.text(_l10n.codexLoginSignInButton), findsOneWidget);

      // Dispose the flow so its countdown timer and cancel signal are
      // cleaned up before the test ends.
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

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
    final settings = SettingsProvider(preferences: businessPrefs);
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

  testWidgets(
    'provider-config write failure keeps the flow open with a retry view',
    (tester) async {
      final flowClient = _ScriptedFlowClient()
        ..handlers.add(
          (_) => _flowJson(200, {
            'device_auth_id': 'da-1',
            'user_code': 'ABC-DEF',
            'interval': '1',
          }),
        )
        ..handlers.add(
          (_) => _flowJson(200, {
            'authorization_code': 'ac-1',
            'code_verifier': 'cv-1',
          }),
        )
        ..handlers.add(
          (_) => _flowJson(200, {
            'access_token': _jwtWithAccount('acc-1'),
            'refresh_token': 'rt-1',
            'expires_in': 3600,
          }),
        );
      final flowController = CodexDeviceCodeController(
        clientFactory: (_) => flowClient,
      );
      CodexDeviceCodeController.debugOverrideInstance(flowController);
      addTearDown(flowController.resetForTest);
      final settings = _RetryGatedSettingsProvider(preferences: businessPrefs);
      addTearDown(settings.dispose);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<CodexDeviceCodeController>.value(
              value: flowController,
            ),
            ChangeNotifierProvider<SettingsProvider>.value(value: settings),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: CodexDeviceCodeFlow(cfg: codexProviderConfig()),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      // Let the periodic countdown timer observe signedIn and cancel itself.
      await tester.pump(const Duration(seconds: 1));

      // The credential landed but the provider write failed: the flow stays
      // open on the error view instead of popping into an orphan state. The
      // view shows only the localized failure copy, never the raw exception.
      expect(flowController.status, CodexAuthStatus.signedIn);
      expect(flowController.credential, isNotNull);
      expect(find.text(_l10n.codexLoginStatusFailed), findsOneWidget);

      // While the first retry is still writing, a second tap must be ignored.
      await tester.tap(find.text(_l10n.codexLoginSignInButton));
      await tester.pump();
      await tester.tap(find.text(_l10n.codexLoginSignInButton));
      await tester.pump();
      expect(settings.calls, 2); // initial write + exactly one retry
      settings.retryGate.complete();
      await tester.pump();
      expect(find.text(_l10n.codexLoginStatusFailed), findsOneWidget);

      // No poll request may have drifted onto the pending fallback: a
      // sequence mismatch would surface here instead of silently polling.
      expect(flowClient.unexpectedPolls, isEmpty);
    },
  );
}
