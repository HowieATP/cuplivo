import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/sync/lan_sync_models.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/lan_sync_section.dart';

/// Minimal ChatService fake: the client index builder never touches the
/// repo when there are no conversations.
class _FakeChatService extends ChatService {
  @override
  List<Conversation> getAllCompleteConversations() => const [];

  @override
  Future<List<Assistant>> getAllAssistants() async => const [];
}

/// Returns a plan with zero changes and a null `since`, so the exchange
/// round never builds a zip or touches DataSync.
String _emptyPlanJson() {
  return const SyncPlan(
    conversations: [],
    missingAssistantIds: [],
    remoteMissingAssistantIds: [],
    since: null,
  ).toJsonString();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeChatService chatService;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    chatService = _FakeChatService();
  });

  Widget buildHarness(http.Client httpClient) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<ChatService>.value(value: chatService),
        // IosCardPress reads SettingsProvider for its tactile feedback.
        ChangeNotifierProvider<SettingsProvider>.value(
          value: SettingsProvider(),
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: LanSyncSection(lanSyncHttpClient: httpClient)),
      ),
    );
  }

  /// Opens the mobile client sheet and fills host/port/PIN.
  Future<void> openSheet(WidgetTester tester, http.Client httpClient) async {
    await tester.pumpWidget(buildHarness(httpClient));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connect to Server'));
    await tester.pumpAndSettle();

    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(3));
    await tester.enterText(fields.at(0), '127.0.0.1');
    await tester.enterText(fields.at(1), '9527');
    await tester.enterText(fields.at(2), '1234');
  }

  testWidgets('error during negotiate keeps the sheet open (retryable)', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final client = MockClient(
      (request) async => throw const SocketException('connection refused'),
    );

    await openSheet(tester, client);
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    // Error snackbar shown, sheet still open with all three fields.
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(3));
    expect(find.text('Client Mode'), findsOneWidget);

    // Must be reset before the binding's invariant check runs (i.e. in
    // the body itself, not in a tearDown).
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('empty exchange response closes the sheet', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final client = MockClient((request) async {
      if (request.url.path == '/sync/plan') {
        return http.Response(_emptyPlanJson(), 200);
      }
      if (request.url.path == '/sync/exchange') {
        return http.Response(
          '{"empty":true}',
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('Not found', 404);
    });

    await openSheet(tester, client);
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    expect(find.text('Start Sync'), findsOneWidget);

    await tester.tap(find.text('Start Sync'));
    await tester.pumpAndSettle();

    // noData → the sheet closes itself; the host page stays.
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Client Mode'), findsNothing);
    expect(find.byType(LanSyncSection), findsOneWidget);

    debugDefaultTargetPlatformOverride = null;
  });
}
