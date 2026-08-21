import 'package:Cuplivo/theme/app_semantic_colors.dart';
import 'package:Cuplivo/theme/theme_factory.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('getPlatformFontFallback', () {
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
    });

    test('uses Android system font stack on Android', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      expect(getPlatformFontFallback(), kAndroidFontFamilyFallback);
    });

    test('keeps CJK fallback on iOS', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

      expect(getPlatformFontFallback(), kDefaultFontFamilyFallback);
    });

    test('keeps Windows fallback on Windows', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;

      expect(getPlatformFontFallback(), kWindowsFontFamilyFallback);
    });

    test('all platform stacks end with bundled symbol fallback', () {
      for (final stack in <List<String>>[
        kAndroidFontFamilyFallback,
        kWindowsFontFamilyFallback,
        kDefaultFontFamilyFallback,
      ]) {
        expect(stack.last, kCuplivoSymbolFallbackFamily);
        expect(
          stack.where((e) => e == kCuplivoSymbolFallbackFamily),
          hasLength(1),
        );
      }
      expect(kWindowsFontFamilyFallback, contains('Segoe UI Symbol'));
    });
  });

  group('semantic color extension & surface container derivation', () {
    test(
      'buildLightTheme attaches AppSemanticColors and onSurface app bar',
      () {
        final theme = buildLightTheme(null);
        final scheme = theme.colorScheme;
        expect(theme.extension<AppSemanticColors>(), isA<AppSemanticColors>());
        expect(theme.appBarTheme.foregroundColor, scheme.onSurface);
        expect(theme.dialogTheme.backgroundColor, scheme.surface);
      },
    );

    test('buildDarkTheme attaches AppSemanticColors and onSurface app bar', () {
      final theme = buildDarkTheme(null);
      final scheme = theme.colorScheme;
      expect(theme.extension<AppSemanticColors>(), isA<AppSemanticColors>());
      expect(theme.appBarTheme.foregroundColor, scheme.onSurface);
      expect(theme.dialogTheme.backgroundColor, scheme.surface);
    });

    test(
      'buildLightThemeForScheme attaches extension and derives containers',
      () {
        const scheme = ColorScheme.light(surface: Color(0xFFF7F7F7));
        final theme = buildLightThemeForScheme(scheme);
        final cs = theme.colorScheme;
        expect(theme.extension<AppSemanticColors>(), isA<AppSemanticColors>());
        // Derived container, not the M3 purple-tinted default (0xFFE6E0E9).
        expect(cs.surfaceContainerHighest, isNot(const Color(0xFFE6E0E9)));
        expect(
          cs.surfaceContainerHigh,
          Color.alphaBlend(
            const Color(0xFFFFFFFF).withValues(alpha: 0.85),
            scheme.surface,
          ),
        );
        expect(theme.appBarTheme.foregroundColor, cs.onSurface);
      },
    );

    test(
      'buildDarkThemeForScheme attaches extension and derives containers',
      () {
        const scheme = ColorScheme.dark(surface: Color(0xFF1A1B21));
        final theme = buildDarkThemeForScheme(scheme);
        final cs = theme.colorScheme;
        expect(theme.extension<AppSemanticColors>(), isA<AppSemanticColors>());
        expect(
          cs.surfaceContainerLowest,
          Color.alphaBlend(
            const Color(0xFF000000).withValues(alpha: 0.28),
            scheme.surface,
          ),
        );
        expect(theme.appBarTheme.foregroundColor, cs.onSurface);
      },
    );

    test('pureBackground derives containers against the pure surface', () {
      final theme = buildLightThemeForScheme(
        const ColorScheme.light(surface: Color(0xFFF7F7F7)),
        pureBackground: true,
      );
      expect(theme.colorScheme.surface, const Color(0xFFFFFFFF));
      expect(theme.extension<AppSemanticColors>(), isA<AppSemanticColors>());
    });
  });
}
