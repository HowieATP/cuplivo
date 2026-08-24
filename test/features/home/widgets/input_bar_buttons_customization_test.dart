import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/home/pages/input_bar_buttons_customization_page.dart';
import 'package:Cuplivo/features/home/utils/input_bar_button_layout.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/ios_switch.dart';

void main() {
  Future<void> pumpContent(
    WidgetTester tester, {
    Size size = const Size(800, 600),
  }) async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [ChangeNotifierProvider.value(value: SettingsProvider())],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: InputBarButtonsCustomizationContent()),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets(
    'content: grip-only drag zone, switch tap-safe, customized explicitly on first toggle',
    (tester) async {
      await pumpContent(tester);

      // No default Flutter drag handles next to our grip (the '=' + 'dots'
      // overlap bug) — GripVertical is the only drag affordance.
      expect(find.byIcon(Icons.drag_handle), findsNothing);
      expect(find.byIcon(Lucide.GripVertical), findsWidgets);
      final firstSwitch = tester.widget<IosSwitch>(
        find.byType(IosSwitch).first,
      );
      expect(firstSwitch.value, isTrue);

      // Tapping the switch toggles — the drag zone is the grip only, so the
      // switch tap never loses the gesture arena.
      final settings = tester
          .element(find.byType(InputBarButtonsCustomizationContent))
          .read<SettingsProvider>();
      await tester.tap(find.byType(IosSwitch).first);
      await tester.pump();

      expect(settings.chatInputMoreButtonIds, contains(inputBarButtonModel));
      final after = tester.widget<IosSwitch>(find.byType(IosSwitch).first);
      expect(after.value, isFalse);

      // The customize entry shows its localized title, never the raw id.
      final l10n = AppLocalizations.of(
        tester.element(find.byType(IosSwitch).first),
      )!;
      await tester.drag(
        find.byType(ReorderableListView),
        const Offset(0, -800),
      );
      await tester.pump();
      expect(find.text(l10n.chatInputBarCustomizeTitle), findsOneWidget);
      expect(find.text('customize'), findsNothing);
    },
  );

  testWidgets('customize entry defaults OFF (in More bucket) at every width', (
    tester,
  ) async {
    await pumpContent(tester, size: const Size(400, 800));

    // Phone layout, unset: customize is the last row and OFF.
    await tester.drag(find.byType(ReorderableListView), const Offset(0, -1200));
    await tester.pump();
    final switches = tester.widgetList<IosSwitch>(find.byType(IosSwitch));
    expect(switches.last.value, isFalse);
  });
}
