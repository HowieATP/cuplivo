import 'package:Cuplivo/theme/app_semantic_colors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const ColorScheme _lightScheme = ColorScheme.light(
  primary: Color(0xFF4D5C92),
  onPrimary: Color(0xFFFFFFFF),
  surface: Color(0xFFFEFBFF),
  onSurface: Color(0xFF1A1B21),
  onSurfaceVariant: Color(0xFF45464F),
);

const ColorScheme _darkScheme = ColorScheme.dark(
  primary: Color(0xFFB6C4FF),
  onPrimary: Color(0xFF1D2D61),
  surface: Color(0xFF1A1B21),
  onSurface: Color(0xFFE3E1E9),
  onSurfaceVariant: Color(0xFFC6C6D0),
);

void main() {
  group('AppSemanticColors.light', () {
    final app = AppSemanticColors.light(_lightScheme);

    test('surfaceFill blends onSurface over surface at 0.05', () {
      expect(
        app.surfaceFill,
        Color.alphaBlend(
          _lightScheme.onSurface.withValues(alpha: 0.05),
          _lightScheme.surface,
        ),
      );
    });

    test('surfaceCard blends white over surface at 0.96', () {
      expect(
        app.surfaceCard,
        Color.alphaBlend(
          const Color(0xFFFFFFFF).withValues(alpha: 0.96),
          _lightScheme.surface,
        ),
      );
    });

    test('searchHighlight is gold at 0.55 alpha', () {
      expect(
        app.searchHighlight,
        const Color(0xFFFFD700).withValues(alpha: 0.55),
      );
    });

    test('chartSeries is the 8-color light ramp', () {
      expect(app.chartSeries, hasLength(8));
      expect(app.chartSeries.first, const Color(0xFF2563EB));
      expect(app.chartSeries.last, const Color(0xFF0891B2));
    });
  });

  group('AppSemanticColors.dark', () {
    final app = AppSemanticColors.dark(_darkScheme);

    test('surfaceFill uses the lightened 0.16 dark alpha', () {
      expect(
        app.surfaceFill,
        Color.alphaBlend(
          _darkScheme.onSurface.withValues(alpha: 0.16),
          _darkScheme.surface,
        ),
      );
      expect(app.surfaceFill.computeLuminance(), greaterThan(0.03));
    });

    test('surfaceCard blends white over surface at 0.10', () {
      expect(
        app.surfaceCard,
        Color.alphaBlend(
          const Color(0xFFFFFFFF).withValues(alpha: 0.10),
          _darkScheme.surface,
        ),
      );
    });

    test('chartSeries is the 8-color dark ramp', () {
      expect(app.chartSeries, hasLength(8));
      expect(app.chartSeries.first, const Color(0xFF60A5FA));
      expect(app.chartSeries.last, const Color(0xFF67E8F9));
    });
  });

  group('status tokens are harmonized with the primary', () {
    test('light success/warning are opaque derived colors', () {
      final app = AppSemanticColors.light(_lightScheme);
      expect(app.success.a, 1.0);
      expect(app.warning.a, 1.0);
      expect(app.successContainer, isNot(equals(app.success)));
      expect(app.warningContainer, isNot(equals(app.warning)));
    });
  });

  group('context.appColors fallback', () {
    testWidgets('derives from the ambient scheme when no extension attached', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              final app = context.appColors;
              final cs = Theme.of(context).colorScheme;
              expect(
                app.surfaceFill,
                Color.alphaBlend(
                  cs.onSurface.withValues(alpha: 0.05),
                  cs.surface,
                ),
              );
              return const SizedBox.shrink();
            },
          ),
        ),
      );
    });

    testWidgets('prefers the attached extension when present', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            colorScheme: _lightScheme,
            extensions: <ThemeExtension<dynamic>>[
              const AppSemanticColors(
                surfaceFill: Color(0xFFFF0000),
                surfaceCard: Color(0xFFFF0000),
                success: Color(0xFFFF0000),
                successContainer: Color(0xFFFF0000),
                onSuccessContainer: Color(0xFFFF0000),
                warning: Color(0xFFFF0000),
                warningContainer: Color(0xFFFF0000),
                onWarningContainer: Color(0xFFFF0000),
                searchHighlight: Color(0xFFFF0000),
                chartSeries: <Color>[Color(0xFFFF0000)],
              ),
            ],
          ),
          home: Builder(
            builder: (context) {
              expect(context.appColors.surfaceFill, const Color(0xFFFF0000));
              return const SizedBox.shrink();
            },
          ),
        ),
      );
    });
  });

  group('copyWith / lerp', () {
    test('copyWith overrides only the given field', () {
      final app = AppSemanticColors.light(_lightScheme);
      final copy = app.copyWith(surfaceFill: const Color(0xFFFF0000));
      expect(copy.surfaceFill, const Color(0xFFFF0000));
      expect(copy.surfaceCard, app.surfaceCard);
    });

    test('lerp produces intermediate values', () {
      final light = AppSemanticColors.light(_lightScheme);
      final dark = AppSemanticColors.dark(_darkScheme);
      final mid = light.lerp(dark, 0.5);
      expect(mid.surfaceFill, isA<Color>());
      expect(mid.chartSeries, hasLength(light.chartSeries.length));
    });
  });
}
