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
  testWidgets(
    'content: grip-only drag zone, tap-safe switch, localized labels',
    (tester) async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
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

      // One visible grip per tile (lazy list: viewport-built subset only).
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
}
