import 'package:Cuplivo/core/providers/hotkey_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/settings/pages/new/behavior_settings_page.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _buildHarness(Widget home) {
  final settings = SettingsProvider();
  addTearDown(settings.dispose);
  final hotkeys = HotkeyProvider();
  addTearDown(hotkeys.dispose);
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<SettingsProvider>.value(value: settings),
      ChangeNotifierProvider<HotkeyProvider>.value(value: hotkeys),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    ),
  );
}

AppLocalizations _l10nOf(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(BehaviorSettingsPage)))!;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(const {});
  });

  testWidgets('desktop-only section renders hotkeys and tray switches', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await tester.pumpWidget(_buildHarness(const BehaviorSettingsPage()));
      await tester.pumpAndSettle();

      final l10n = _l10nOf(tester);
      await tester.scrollUntilVisible(find.text(l10n.settingsPageHotkeys), 200);

      expect(find.text(l10n.settingsPageHotkeys), findsOneWidget);
      expect(
        find.text(l10n.displaySettingsPageTrayShowTrayTitle),
        findsOneWidget,
      );
      expect(
        find.text(l10n.displaySettingsPageTrayMinimizeOnCloseTitle),
        findsOneWidget,
      );
      expect(
        find.text(l10n.displaySettingsPageAndroidBackgroundChatTitle),
        findsNothing,
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('mobile platform shows background chat row without desktop-only '
      'section', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await tester.pumpWidget(_buildHarness(const BehaviorSettingsPage()));
      await tester.pumpAndSettle();

      final l10n = _l10nOf(tester);
      await tester.scrollUntilVisible(
        find.text(l10n.displaySettingsPageAndroidBackgroundChatTitle),
        200,
      );

      expect(
        find.text(l10n.displaySettingsPageAndroidBackgroundChatTitle),
        findsOneWidget,
      );
      expect(find.text(l10n.settingsPageHotkeys), findsNothing);
      expect(
        find.text(l10n.displaySettingsPageTrayShowTrayTitle),
        findsNothing,
      );
      expect(
        find.text(l10n.displaySettingsPageTrayMinimizeOnCloseTitle),
        findsNothing,
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
