import 'dart:async';

import 'package:Cuplivo/core/models/api_keys.dart';
import 'package:Cuplivo/core/services/search/search_service.dart';
import 'package:Cuplivo/features/search/pages/search_service_editor_page.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SearchServiceEditorPage discard confirmation', () {
    Widget harness(Widget child) {
      return MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: child,
      );
    }

    SearchServiceEditorPage page() {
      return SearchServiceEditorPage(
        initialService: TavilyOptions(
          id: 'tavily-1',
          apiKeys: [ApiKeyConfig.create('tvly-test')],
        ),
        commonOptions: const SearchCommonOptions(),
        autoQueryUsage: false,
      );
    }

    Future<Completer<SearchServiceEditorResult?>> pumpAndCollectResult(
      WidgetTester tester,
    ) async {
      final completer = Completer<SearchServiceEditorResult?>();
      await tester.pumpWidget(
        harness(
          Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () {
                    Navigator.of(context)
                        .push<SearchServiceEditorResult>(
                          MaterialPageRoute(builder: (_) => page()),
                        )
                        .then(completer.complete);
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      return completer;
    }

    Future<void> openEditor(WidgetTester tester) async {
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(SearchServiceEditorPage), findsOneWidget);
    }

    Future<void> tapBack(WidgetTester tester) async {
      await tester.tap(
        find.byTooltip(
          AppLocalizations.of(
            tester.element(find.byType(SearchServiceEditorPage)),
          )!.searchServicesPageBackTooltip,
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('shows discard dialog on back when a field was edited', (
      WidgetTester tester,
    ) async {
      final completer = await pumpAndCollectResult(tester);
      await openEditor(tester);

      await tester.enterText(
        find.byKey(const ValueKey('search-service-field-url')),
        'https://custom.example/search',
      );
      await tester.pump();
      await tapBack(tester);

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Discard changes?'), findsOneWidget);
      expect(find.text('Keep editing'), findsOneWidget);
      expect(find.text('Discard'), findsOneWidget);
      expect(completer.isCompleted, isFalse);
    });

    testWidgets('Keep editing dismisses the dialog and stays on the page', (
      WidgetTester tester,
    ) async {
      final completer = await pumpAndCollectResult(tester);
      await openEditor(tester);

      await tester.enterText(
        find.byKey(const ValueKey('search-service-field-url')),
        'https://custom.example/search',
      );
      await tester.pump();
      await tapBack(tester);

      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(SearchServiceEditorPage), findsOneWidget);
      expect(completer.isCompleted, isFalse);
    });

    testWidgets('Discard pops the page with a null result', (
      WidgetTester tester,
    ) async {
      final completer = await pumpAndCollectResult(tester);
      await openEditor(tester);

      await tester.enterText(
        find.byKey(const ValueKey('search-service-field-url')),
        'https://custom.example/search',
      );
      await tester.pump();
      await tapBack(tester);

      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();

      expect(find.byType(SearchServiceEditorPage), findsNothing);
      expect(await completer.future, isNull);
    });

    testWidgets('back with no edits pops immediately without a dialog', (
      WidgetTester tester,
    ) async {
      final completer = await pumpAndCollectResult(tester);
      await openEditor(tester);

      await tapBack(tester);

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(SearchServiceEditorPage), findsNothing);
      expect(await completer.future, isNull);
    });
  });
}
