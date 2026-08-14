import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// Mirrors the native BackgroundKeepAliveManager status on the
/// `app.ios_keepalive` MethodChannel.
class IosKeepAliveStatus {
  const IosKeepAliveStatus({
    required this.masterEnabled,
    required this.silentAudioEnabled,
    required this.locationEnabled,
    required this.sessionActive,
    required this.appIsInBackground,
    required this.silentAudioActive,
    required this.locationUpdating,
    required this.locationArmed,
    required this.locationAuthorized,
    required this.survivalTier,
  });

  factory IosKeepAliveStatus.fromMap(Map<dynamic, dynamic>? map) {
    bool readBool(String key) => map?[key] == true;
    return IosKeepAliveStatus(
      masterEnabled: readBool('masterEnabled'),
      silentAudioEnabled: readBool('silentAudioEnabled'),
      locationEnabled: readBool('locationEnabled'),
      sessionActive: readBool('sessionActive'),
      appIsInBackground: readBool('appIsInBackground'),
      silentAudioActive: readBool('silentAudioActive'),
      locationUpdating: readBool('locationUpdating'),
      locationArmed: readBool('locationArmed'),
      locationAuthorized: readBool('locationAuthorized'),
      survivalTier: (map?['survivalTier'] as String?) ?? 'short',
    );
  }

  final bool masterEnabled;
  final bool silentAudioEnabled;
  final bool locationEnabled;
  final bool sessionActive;
  final bool appIsInBackground;
  final bool silentAudioActive;
  final bool locationUpdating;
  final bool locationArmed;
  final bool locationAuthorized;
  final String survivalTier;

  /// Long-lived keep-alive is actually effective right now.
  bool get effective => silentAudioActive || locationUpdating;
}

class IosKeepAliveService {
  IosKeepAliveService._();

  static final IosKeepAliveService instance = IosKeepAliveService._();

  static const MethodChannel _channel = MethodChannel('app.ios_keepalive');

  bool debugForceIosForTest = false;

  bool get _isIos => debugForceIosForTest || Platform.isIOS;

  /// Push the current user toggles to the native keep-alive manager.
  Future<void> configure({
    required bool masterEnabled,
    required bool silentAudioEnabled,
    required bool locationEnabled,
  }) async {
    if (!_isIos) return;
    try {
      await _channel.invokeMethod<void>('configure', <String, Object?>{
        'masterEnabled': masterEnabled,
        'silentAudioEnabled': silentAudioEnabled,
        'locationEnabled': locationEnabled,
      });
    } catch (_) {
      // Native side may be unavailable (e.g. during tests); toggles are
      // still persisted by SettingsProvider.
    }
  }

  /// Called when a generation task starts.
  Future<void> beginSession() async {
    if (!_isIos) return;
    try {
      await _channel.invokeMethod<void>('beginSession');
    } catch (_) {}
  }

  /// Called when a generation task finishes / is cancelled.
  Future<void> endSession() async {
    if (!_isIos) return;
    try {
      await _channel.invokeMethod<void>('endSession');
    } catch (_) {}
  }

  Future<IosKeepAliveStatus> getStatus() async {
    if (!_isIos) {
      return const IosKeepAliveStatus(
        masterEnabled: false,
        silentAudioEnabled: false,
        locationEnabled: false,
        sessionActive: false,
        appIsInBackground: false,
        silentAudioActive: false,
        locationUpdating: false,
        locationArmed: false,
        locationAuthorized: false,
        survivalTier: 'short',
      );
    }
    final result = await _channel.invokeMethod<dynamic>('getStatus');
    return IosKeepAliveStatus.fromMap(result as Map<dynamic, dynamic>?);
  }

  /// Request location permission (When-In-Use first, then Always on follow-up).
  Future<bool> requestLocationAuthorization() async {
    if (!_isIos) return false;
    return await _channel.invokeMethod<bool>('requestLocationAuthorization') ??
        false;
  }
}
