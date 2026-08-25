import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/shared/widgets/loading_dialog_card.dart';

void main() {
  group('LoadingDialogCard', () {
    testWidgets('renders activity indicator without label', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: LoadingDialogCard())),
      );

      expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('renders optional label text', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: LoadingDialogCard(label: '正在加载')),
        ),
      );

      expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
      expect(find.text('正在加载'), findsOneWidget);
    });

    testWidgets(
      'elapsedTextBuilder ticks every second and cancels on dispose',
      (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: LoadingDialogCard(
                label: 'Exporting',
                elapsedTextBuilder: _tickLabel,
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.text('tick 0'), findsOneWidget);
        expect(find.text('Exporting'), findsOneWidget);

        await tester.pump(const Duration(seconds: 1));
        expect(find.text('tick 1'), findsOneWidget);

        await tester.pump(const Duration(seconds: 1));
        expect(find.text('tick 2'), findsOneWidget);

        // Unmount — dispose must cancel the periodic timer, otherwise the test
        // framework reports a pending Timer.
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets('without elapsedTextBuilder no timer and no elapsed line', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: LoadingDialogCard(label: 'Hi')),
        ),
      );
      await tester.pump();
      expect(find.text('Hi'), findsOneWidget);
      expect(find.textContaining('tick'), findsNothing);
    });
  });
}

String _tickLabel(int seconds) => 'tick $seconds';
