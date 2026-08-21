import 'package:Cuplivo/core/services/search/search_service.dart';
import 'package:Cuplivo/features/search/pages/search_service_editor_page.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SearchServiceEditorPage provider switch', () {
    Widget harness(Widget child) {
      return MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: child,
      );
    }

    Future<void> pumpEditor(WidgetTester tester) async {
      await tester.pumpWidget(
        harness(
          const SearchServiceEditorPage(
            commonOptions: SearchCommonOptions(),
            autoQueryUsage: false,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('entered key pool survives a provider chip switch', (
      tester,
    ) async {
      await pumpEditor(tester);

      // Switch from the default (Bing Local, keyless) to a keyed provider.
      await tester.tap(find.text('Tavily'));
      await tester.pumpAndSettle();

      // Add a key through the key-management section.
      await tester.ensureVisible(find.text('Add Key'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add Key'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'tvly-persist-test');
      await tester.ensureVisible(find.text('Save'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('tvly-persist-test'));
      expect(find.text('tvly-persist-test'), findsOneWidget);

      // Scroll back to the provider chips (culled after scrolling down).
      await tester.scrollUntilVisible(
        find.text('Exa'),
        -200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      // Switch to a different keyed provider: the key must survive.
      await tester.ensureVisible(find.text('Exa'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Exa'));
      await tester.pumpAndSettle();

      expect(find.text('tvly-persist-test'), findsOneWidget);
      expect(find.text('1 keys'), findsOneWidget);
    });

    testWidgets('entered key pool survives a switch to a keyless provider', (
      tester,
    ) async {
      await pumpEditor(tester);

      await tester.tap(find.text('Tavily'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Add Key'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add Key'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'tvly-persist-test');
      await tester.ensureVisible(find.text('Save'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('DuckDuckGo'),
        -200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('DuckDuckGo'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('DuckDuckGo'));
      await tester.pumpAndSettle();

      // DuckDuckGo is keyless: no key UI, but switching back must restore it.
      expect(find.text('tvly-persist-test'), findsNothing);
      await tester.ensureVisible(find.text('Tavily'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tavily'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('tvly-persist-test'));
      expect(find.text('tvly-persist-test'), findsOneWidget);
    });
  });
}
