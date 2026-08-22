import 'dart:async' show unawaited;
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:wakelock_plus/wakelock_plus.dart';

/// Keeps the mobile screen on while AI generation is running.
///
/// Platform-gated: only Android and iOS hold a wake lock; every other
/// platform is a no-op (desktop monitor sleep is out of scope, see
/// docs/adr/0040-screen-on-wake-lock-during-generation.md). Refcounted so
/// concurrent generation (Multi-AI N-slot rounds, sequential rounds) holds
/// the lock until the last slot settles.
class WakeLockManager {
  WakeLockManager({
    bool Function()? isMobilePlatform,
    Future<void> Function(bool enabled)? applyLock,
  }) : _isMobile = isMobilePlatform ?? _defaultMobileCheck,
       _applyLock = applyLock ?? _defaultApplyLock;

  static bool _defaultMobileCheck() => Platform.isAndroid || Platform.isIOS;

  static Future<void> _defaultApplyLock(bool enabled) =>
      WakelockPlus.toggle(enable: enabled);

  final bool Function() _isMobile;
  final Future<void> Function(bool enabled) _applyLock;

  int _refCount = 0;

  /// True while a wake lock is currently held (Android/iOS only).
  bool get isHeld => _refCount > 0;

  /// Acquires one reference to the screen-on wake lock. Safe to call
  /// repeatedly; only the first acquisition touches the platform.
  void acquire() {
    if (!_isMobile()) return;
    if (_refCount == 0) {
      unawaited(_setEnabled(true));
    }
    _refCount++;
  }

  /// Releases one reference. The lock is dropped when the last reference is
  /// released; extra releases are ignored (the count never goes negative).
  void release() {
    if (!_isMobile()) return;
    if (_refCount <= 0) return;
    _refCount--;
    if (_refCount == 0) {
      unawaited(_setEnabled(false));
    }
  }

  /// Drops every reference and forces the lock off. Used by the engine's
  /// `dispose`, where pending slot releases can no longer be awaited.
  void reset() {
    if (!_isMobile()) return;
    if (_refCount == 0) return;
    _refCount = 0;
    unawaited(_setEnabled(false));
  }

  Future<void> _setEnabled(bool enabled) async {
    try {
      await _applyLock(enabled);
    } catch (e) {
      // Recoverable: a failed wake lock must never break generation — the
      // worst case is the screen sleeping mid-stream.
      debugPrint(
        '[WakeLockManager] failed to '
        '${enabled ? 'enable' : 'disable'} wake lock: $e',
      );
    }
  }
}
