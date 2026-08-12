import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:Cuplivo/features/skills/pages/skills_page.dart';
import 'package:Cuplivo/features/skills/skill_manager.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.root);

  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getApplicationCachePath() async => '$root/cache';

  @override
  Future<String?> getTemporaryPath() async => '$root/tmp';
}

/// The skills list is loaded via real dart:io; each I/O event is delivered on
/// the real event loop, so pump+runAsync must cycle until the spinner goes
/// away (same pattern as mount_files_page_test).
Future<void> pumpUntilLoaded(WidgetTester tester) async {
  final end = DateTime.now().add(const Duration(seconds: 3));
  while (DateTime.now().isBefore(end)) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump();
    if (find.byType(CircularProgressIndicator).evaluate().isEmpty) return;
  }
  fail('Timed out waiting for the skills page to finish loading');
}

Widget _harness({required bool desktop}) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    home: SkillsPage(desktop: desktop),
  );
}

void main() {
  late Directory root;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('skills_page_ui_test_');
    PathProviderPlatform.instance = _FakePathProviderPlatform(root.path);
    // Pre-warm the cached root future in the framework zone: it is created
    // lazily on first page load, and a future created inside one testWidgets
    // FakeAsync zone never completes for a later test.
    await SkillManager.initRoot();
  });

  tearDownAll(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  testWidgets(
    'mobile mode: no FAB and the import menu offers file/github/manual',
    (tester) async {
      await tester.pumpWidget(_harness(desktop: false));
      await pumpUntilLoaded(tester);

      expect(find.byType(FloatingActionButton), findsNothing);

      await tester.tap(find.byIcon(Lucide.Download));
      await tester.pumpAndSettle();

      final l10n = AppLocalizations.of(
        tester.element(find.byType(SkillsPage)),
      )!;
      expect(find.text(l10n.skillsImportFromFile), findsOneWidget);
      expect(find.text(l10n.skillsImportFromGitHub), findsOneWidget);
      expect(find.text(l10n.skillsImportManualTitle), findsOneWidget);

      await tester.tap(find.text(l10n.skillsImportManualTitle));
      await tester.pumpAndSettle();
      expect(find.text(l10n.skillsImportManualTitle), findsOneWidget);

      await tester.tap(
        find.text(
          MaterialLocalizations.of(
            tester.element(find.byType(AlertDialog)),
          ).cancelButtonLabel,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    },
  );

  testWidgets(
    'desktop mode: pane layout without AppBar/FAB, import menu includes '
    'manual add',
    (tester) async {
      await tester.pumpWidget(_harness(desktop: true));
      await pumpUntilLoaded(tester);

      expect(find.byType(AppBar), findsNothing);
      expect(find.byType(FloatingActionButton), findsNothing);
      expect(find.byIcon(Lucide.Import), findsOneWidget);

      final l10n = AppLocalizations.of(
        tester.element(find.byType(SkillsPage)),
      )!;
      expect(find.text(l10n.skillsTitle), findsOneWidget);

      await tester.tap(find.byIcon(Lucide.Import));
      await tester.pumpAndSettle();

      expect(find.text(l10n.skillsImportFromFile), findsOneWidget);
      expect(find.text(l10n.skillsImportFromGitHub), findsOneWidget);
      expect(find.text(l10n.skillsImportManualTitle), findsOneWidget);

      await tester.tap(find.text(l10n.skillsImportManualTitle));
      await tester.pumpAndSettle();
      expect(find.text(l10n.skillsImportManualTitle), findsOneWidget);

      await tester.tap(
        find.text(
          MaterialLocalizations.of(
            tester.element(find.byType(AlertDialog)),
          ).cancelButtonLabel,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    },
  );
}
