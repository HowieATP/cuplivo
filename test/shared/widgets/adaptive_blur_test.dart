import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/shared/widgets/adaptive_blur.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Watches the provider so the builder re-runs once SettingsProvider's
  /// asynchronous load completes (prefs are applied after construction).
  Widget harness({
    required void Function(bool enabled, Color? blended) onResult,
    Map<String, Object>? preferences,
  }) {
    SharedPreferences.setMockInitialValues(preferences ?? const {});
    return ChangeNotifierProvider(
      create: (_) => SettingsProvider(),
      child: Builder(
        builder: (context) {
          context.watch<SettingsProvider>();
          onResult(
            adaptiveBlurEnabled(context),
            Theme.of(context).colorScheme.surface,
          );
          return const SizedBox();
        },
      ),
    );
  }

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });
  Future<bool> readEnabled(
    WidgetTester tester,
    Map<String, Object> preferences,
  ) async {
    bool? result;
    await tester.pumpWidget(
      harness(
        preferences: preferences,
        onResult: (enabled, _) {
          result = enabled;
        },
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    return result!;
  }

  group('adaptiveBlurEnabled', () {
    testWidgets('returns false on mobile when blur effects are off', (
      tester,
    ) async {
      expect(
        await readEnabled(tester, const {
          'display_mobile_blur_effects_v1': false,
        }),
        isFalse,
      );
    });

    testWidgets('returns true on mobile when blur effects are on', (
      tester,
    ) async {
      expect(
        await readEnabled(tester, const {
          'display_mobile_blur_effects_v1': true,
        }),
        isTrue,
      );
    });

    testWidgets('desktop keeps blur even when the mobile toggle is off', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        expect(
          await readEnabled(tester, const {
            'display_mobile_blur_effects_v1': false,
          }),
          isTrue,
        );
      } finally {
        // Must be reset inside the test body: the binding's invariant check
        // runs before addTearDown callbacks.
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('AdaptiveBlurFilter', () {
    Widget probe({required bool prefEnabled}) {
      SharedPreferences.setMockInitialValues(
        prefEnabled ? const {'display_mobile_blur_effects_v1': true} : const {},
      );
      return ChangeNotifierProvider(
        create: (_) => SettingsProvider(),
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                context.watch<SettingsProvider>();
                return AdaptiveBlurFilter(
                  enabled: adaptiveBlurEnabled(context),
                  filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                  child: const ColoredBox(
                    key: ValueKey('blur-probe-child'),
                    color: Colors.white,
                  ),
                );
              },
            ),
          ),
        ),
      );
    }

    Future<void> pumpProbe(WidgetTester tester, bool prefEnabled) async {
      await tester.pumpWidget(probe(prefEnabled: prefEnabled));
      await tester.pump(const Duration(milliseconds: 100));
    }

    testWidgets('renders BackdropFilter when enabled', (tester) async {
      await pumpProbe(tester, true);
      expect(find.byType(BackdropFilter), findsOneWidget);
      expect(find.byKey(const ValueKey('blur-probe-child')), findsOneWidget);
    });

    testWidgets('renders the child without BackdropFilter when disabled', (
      tester,
    ) async {
      await pumpProbe(tester, false);
      expect(find.byType(BackdropFilter), findsNothing);
      expect(find.byKey(const ValueKey('blur-probe-child')), findsOneWidget);
    });

    testWidgets('keeps the tree identical on desktop when toggled off', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await pumpProbe(tester, false);
        expect(find.byType(BackdropFilter), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('preblendedBlurColor', () {
    testWidgets('produces an opaque pre-blended surface color', (tester) async {
      Color? blended;
      await tester.pumpWidget(
        ChangeNotifierProvider(
          create: (_) => SettingsProvider(),
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) {
                  blended = preblendedBlurColor(
                    context,
                    Colors.white.withValues(alpha: 0.6),
                  );
                  return const SizedBox();
                },
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(blended, isNotNull);
      expect(blended!.a, 1.0);
    });
  });
}
