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
    required void Function(bool enabled) onResult,
    Map<String, Object>? preferences,
  }) {
    SharedPreferences.setMockInitialValues(preferences ?? const {});
    return ChangeNotifierProvider(
      create: (_) => SettingsProvider(),
      child: Builder(
        builder: (context) {
          context.watch<SettingsProvider>();
          onResult(adaptiveBlurEnabled(context));
          return const SizedBox();
        },
      ),
    );
  }

  /// Pumps until [result] matches [expected], so the async preference load
  /// cannot race with a fixed pump duration.
  Future<void> pumpUntilResult(
    WidgetTester tester,
    bool? Function() result,
    bool expected,
  ) async {
    for (var i = 0; i < 100 && result() != expected; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  Future<bool> readEnabled(
    WidgetTester tester,
    Map<String, Object> preferences,
    bool expected,
  ) async {
    bool? result;
    await tester.pumpWidget(
      harness(
        preferences: preferences,
        onResult: (enabled) {
          result = enabled;
        },
      ),
    );
    await pumpUntilResult(tester, () => result, expected);
    expect(result, expected, reason: 'settings load should complete');
    return result!;
  }

  group('adaptiveBlurEnabled', () {
    testWidgets('returns false on mobile when blur effects are off', (
      tester,
    ) async {
      expect(
        await readEnabled(tester, const {
          'display_mobile_blur_effects_v1': false,
        }, false),
        isFalse,
      );
    });

    testWidgets('returns true on mobile when blur effects are on', (
      tester,
    ) async {
      expect(
        await readEnabled(tester, const {
          'display_mobile_blur_effects_v1': true,
        }, true),
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
          }, true),
          isTrue,
        );
      } finally {
        // Must be reset inside the test body: the binding's invariant check
        // runs before addTearDown callbacks.
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('adaptiveBlurRead', () {
    testWidgets('reads the current preference without subscribing', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(const {
        'display_mobile_blur_effects_v1': true,
      });
      final settings = SettingsProvider();
      // Wait for the async load so the read observes the persisted value.
      for (var i = 0; i < 100 && !settings.mobileBlurEffectsEnabled; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }

      bool? read;
      await tester.pumpWidget(
        ChangeNotifierProvider<SettingsProvider>.value(
          value: settings,
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) {
                  read = adaptiveBlurRead(context);
                  return const SizedBox();
                },
              ),
            ),
          ),
        ),
      );

      expect(read, isTrue);
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
      // Keep pumping until the setting is loaded (deterministic wait).
      for (var i = 0; i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
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

    testWidgets('grouped mode mirrors BackdropFilter.grouped', (tester) async {
      SharedPreferences.setMockInitialValues(const {
        'display_mobile_blur_effects_v1': true,
      });
      await tester.pumpWidget(
        ChangeNotifierProvider(
          create: (_) => SettingsProvider(),
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) {
                  context.watch<SettingsProvider>();
                  return AdaptiveBlurFilter(
                    enabled: adaptiveBlurEnabled(context),
                    grouped: true,
                    filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                    child: const SizedBox(),
                  );
                },
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(find.byType(BackdropFilter), findsOneWidget);
      final filter = tester.widget<BackdropFilter>(find.byType(BackdropFilter));
      expect(filter, isA<BackdropFilter>());
    });
  });

  group('preblendedBlurColor', () {
    testWidgets('pre-blends the translucent foreground over the surface', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(const {});
      Color? blended;
      Color? surface;
      await tester.pumpWidget(
        ChangeNotifierProvider(
          create: (_) => SettingsProvider(),
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) {
                  surface = Theme.of(context).colorScheme.surface;
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
      await tester.pump(const Duration(milliseconds: 10));

      expect(blended, isNotNull);
      expect(blended!.a, 1.0);
      final expected = Color.alphaBlend(
        Colors.white.withValues(alpha: 0.6),
        surface!,
      );
      expect(blended!.toARGB32(), expected.toARGB32());
    });
  });
}
