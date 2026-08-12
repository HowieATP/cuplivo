import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/providers/settings_provider.dart';

/// Whether frosted-glass blur should be rendered on the current platform.
///
/// Desktop platforms always keep their existing frosted-glass visuals.
/// On Android/iOS the behavior follows
/// [SettingsProvider.mobileBlurEffectsEnabled] (default off) to avoid the
/// expensive backdrop blur that hurts long chat scroll performance.
bool adaptiveBlurEnabled(BuildContext context) {
  if (!kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS)) {
    return context.watch<SettingsProvider>().mobileBlurEffectsEnabled;
  }
  return true;
}

/// Pre-blends a translucent foreground over the theme surface color so that
/// disabling blur still renders an opaque, visually similar surface.
Color preblendedBlurColor(BuildContext context, Color foreground) {
  return Color.alphaBlend(foreground, Theme.of(context).colorScheme.surface);
}

/// [BackdropFilter] that can be disabled on mobile for performance.
///
/// When [enabled] is false the child is rendered directly without any blur;
/// callers should substitute the translucent fill with
/// [preblendedBlurColor] so the surface stays opaque and close to the
/// frosted-glass look. Borders, corner radius, shadows and press feedback
/// are untouched, so the tree stays identical to the desktop one when
/// enabled.
class AdaptiveBlurFilter extends StatelessWidget {
  const AdaptiveBlurFilter({
    super.key,
    required this.enabled,
    required this.filter,
    required this.child,
    this.grouped = false,
  });

  /// When false the blur is skipped and [child] is returned as-is.
  final bool enabled;

  final ui.ImageFilter filter;

  final Widget child;

  /// Mirrors [BackdropFilter.grouped] semantics.
  final bool grouped;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return grouped
        ? BackdropFilter.grouped(filter: filter, child: child)
        : BackdropFilter(filter: filter, child: child);
  }
}
