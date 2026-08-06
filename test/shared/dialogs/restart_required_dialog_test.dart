import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/dialogs/restart_required_dialog.dart';

Widget _buildHarness() {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Builder(
      builder: (context) => Center(
        child: ElevatedButton(
          onPressed: () => showRestartRequiredDialog(context),
          child: const Text('open'),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('restart dialog cannot be dismissed by the system back button', (
    tester,
  ) async {
    await tester.pumpWidget(_buildHarness());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('OK'), findsOneWidget);

    // Simulate the Android back button / desktop Esc: the dialog must stay
    // open because the restore contract is "restart to take effect".
    final handled = await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(handled, isTrue);
    expect(find.text('OK'), findsOneWidget);
  });
}
