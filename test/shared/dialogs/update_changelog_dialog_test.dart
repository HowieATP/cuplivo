import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/providers/update_provider.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/dialogs/update_changelog_dialog.dart';
import 'package:Cuplivo/shared/widgets/snackbar.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:provider/provider.dart';

var businessPrefs = BusinessPreferences.memoryForTests();

const _urlLauncherChannel = MethodChannel('plugins.flutter.io/url_launcher');

UpdateInfo _info({
  // 'universal' resolves on every platform in bestDownloadUrl(), keeping the
  // fixture deterministic on Windows/Linux/macOS hosts (CI runs on Linux).
  Map<String, String> downloads = const {
    'universal': 'https://example.com/cuplivo-universal',
  },
}) {
  return UpdateInfo(
    app: 'cuplivo',
    version: '2.0.0',
    build: 5,
    notes: '## What is new\n- Faster startup',
    downloads: downloads,
  );
}

/// Lets benign framework system calls pass while failing on unexpected ones.
void _allowBenignSystemCalls(MethodCall call) {
  switch (call.method) {
    case 'Clipboard.setData':
    case 'Clipboard.getData':
    case 'SystemChrome.setApplicationSwitcherDescription':
    case 'SystemSound.play':
    case 'HapticFeedback.vibrate':
      return;
    default:
      fail('Unexpected platform call: ${call.method}');
  }
}

Future<void> _pumpSheet(WidgetTester tester, UpdateInfo info) async {
  await tester.pumpWidget(
    ChangeNotifierProvider(
      create: (_) => SettingsProvider(preferences: businessPrefs),
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AppSnackBarOverlay(
          child: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () =>
                      UpdateChangelogDialog.showSheet(context, info: info),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_urlLauncherChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('shows version title, release notes and download button', (
    tester,
  ) async {
    await _pumpSheet(tester, _info());

    expect(find.text('New version: 2.0.0 (5)'), findsOneWidget);
    expect(find.byType(GptMarkdown), findsOneWidget);
    expect(find.text('Download'), findsOneWidget);
  });

  testWidgets('tapping download launches the platform download url', (
    tester,
  ) async {
    String? launchedUrl;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _urlLauncherChannel,
      (call) async {
        if (call.method == 'launch') {
          launchedUrl =
              (call.arguments as Map<Object?, Object?>)['url'] as String?;
          return true;
        }
        fail('Unexpected url_launcher call: ${call.method}');
      },
    );

    await _pumpSheet(tester, _info());
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();

    expect(launchedUrl, 'https://example.com/cuplivo-universal');
  });

  testWidgets('download failure copies the url and shows a snackbar', (
    tester,
  ) async {
    String? copiedText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _urlLauncherChannel,
      (call) async {
        throw PlatformException(code: 'launch_failed');
      },
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copiedText =
                (call.arguments as Map<Object?, Object?>)['text'] as String?;
            return null;
          }
          _allowBenignSystemCalls(call);
          return null;
        });

    await _pumpSheet(tester, _info());
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();

    expect(copiedText, 'https://example.com/cuplivo-universal');
    expect(find.text('Link copied'), findsOneWidget);

    // Drain the snackbar's 3s auto-dismiss timer + 300ms exit animation
    // (same pattern as codex_account_entry_widget_test.dart).
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('hides download button when no platform download url exists', (
    tester,
  ) async {
    await _pumpSheet(tester, _info(downloads: const {}));

    expect(find.text('New version: 2.0.0 (5)'), findsOneWidget);
    expect(find.text('Download'), findsNothing);
  });

  testWidgets('close button dismisses the sheet', (tester) async {
    await _pumpSheet(tester, _info());

    await tester.tap(find.byIcon(Lucide.X));
    await tester.pumpAndSettle();

    expect(find.byType(GptMarkdown), findsNothing);
  });
}
