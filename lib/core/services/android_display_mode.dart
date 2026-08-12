import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Result of requesting a display refresh rate change on Android.
class AndroidDisplayModeResult {
  const AndroidDisplayModeResult({
    required this.supported,
    required this.enabled,
    this.refreshRate,
    this.modeId,
  });

  /// Whether the display exposes selectable modes (i.e. the request is
  /// meaningful on this device).
  final bool supported;

  /// Whether the high refresh rate mode is currently active.
  final bool enabled;

  /// Refresh rate of the selected mode, or null when unsupported.
  final double? refreshRate;

  /// The selected Display.Mode id, or null when unsupported.
  final int? modeId;
}

/// Platform bridge for the Android `app.display_mode` method channel.
///
/// Callers must gate on Android: the Android side selects the mode with the
/// highest refresh rate among the modes that share the current resolution,
/// so enabling high refresh rate never changes the display resolution. When
/// disabled, the platform returns to the system default mode
/// (`preferredDisplayModeId = 0`).
class AndroidDisplayMode {
  AndroidDisplayMode._();

  static const MethodChannel _channel = MethodChannel('app.display_mode');

  /// Request high refresh rate.
  ///
  /// Failures are logged and rethrown so the caller can decide how to
  /// surface them; there is never a silent fallback.
  static Future<AndroidDisplayModeResult?> setHighRefreshRate(
    bool enabled,
  ) async {
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
        'setHighRefreshRate',
        <String, Object>{'enabled': enabled},
      );
      if (raw == null) {
        debugPrint(
          '[AndroidDisplayMode] setHighRefreshRate($enabled) returned null',
        );
        return null;
      }
      final supported = raw['supported'] == true;
      return AndroidDisplayModeResult(
        supported: supported,
        enabled: raw['enabled'] == true,
        refreshRate: (raw['refreshRate'] as num?)?.toDouble(),
        modeId: (raw['modeId'] as num?)?.toInt(),
      );
    } on PlatformException catch (e) {
      debugPrint(
        '[AndroidDisplayMode] setHighRefreshRate($enabled) failed: '
        '${e.code}: ${e.message}',
      );
      rethrow;
    } on MissingPluginException catch (e) {
      debugPrint('[AndroidDisplayMode] channel unavailable: ${e.message}');
      rethrow;
    }
  }
}
