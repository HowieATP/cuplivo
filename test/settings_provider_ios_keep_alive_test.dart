import 'package:flutter_test/flutter_test.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';

import 'package:Cuplivo/core/providers/settings_provider.dart';

Future<void> _waitForSettingsLoad() async {
  for (var i = 0; i < 25; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  var businessPrefs = BusinessPreferences.memoryForTests();
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SettingsProvider iOS advanced keep-alive settings', () {
    test('defaults all keep-alive options to disabled', () async {
      businessPrefs = BusinessPreferences.memoryForTests({});
      final settings = SettingsProvider(preferences: businessPrefs);

      await _waitForSettingsLoad();

      expect(settings.iosKeepAliveEnabled, isFalse);
      expect(settings.iosSilentAudioKeepAliveEnabled, isFalse);
      expect(settings.iosLocationKeepAliveEnabled, isFalse);
      expect(settings.iosLiveActivityPrivacyMode, isFalse);
    });

    test('loads persisted keep-alive values', () async {
      businessPrefs = BusinessPreferences.memoryForTests({
        'ios_keepalive_enabled_v1': true,
        'ios_silent_audio_keepalive_enabled_v1': true,
        'ios_location_keepalive_enabled_v1': true,
        'ios_live_activity_privacy_mode_v1': true,
      });
      final settings = SettingsProvider(preferences: businessPrefs);

      await _waitForSettingsLoad();

      expect(settings.iosKeepAliveEnabled, isTrue);
      expect(settings.iosSilentAudioKeepAliveEnabled, isTrue);
      expect(settings.iosLocationKeepAliveEnabled, isTrue);
      expect(settings.iosLiveActivityPrivacyMode, isTrue);
    });

    test('silent audio / location toggles cascade master on', () async {
      businessPrefs = BusinessPreferences.memoryForTests({});
      final settings = SettingsProvider(preferences: businessPrefs);

      await _waitForSettingsLoad();
      await settings.setIosSilentAudioKeepAliveEnabled(true);
      expect(settings.iosKeepAliveEnabled, isTrue);

      await settings.setIosLocationKeepAliveEnabled(true);
      expect(settings.iosKeepAliveEnabled, isTrue);
    });

    test('master off cascades sub-toggles off', () async {
      businessPrefs = BusinessPreferences.memoryForTests({
        'ios_keepalive_enabled_v1': true,
        'ios_silent_audio_keepalive_enabled_v1': true,
        'ios_location_keepalive_enabled_v1': true,
      });
      final settings = SettingsProvider(preferences: businessPrefs);

      await _waitForSettingsLoad();
      await settings.setIosKeepAliveEnabled(false);

      expect(settings.iosKeepAliveEnabled, isFalse);
      expect(settings.iosSilentAudioKeepAliveEnabled, isFalse);
      expect(settings.iosLocationKeepAliveEnabled, isFalse);
    });

    test('persists keep-alive values to preferences', () async {
      businessPrefs = BusinessPreferences.memoryForTests({});
      final settings = SettingsProvider(preferences: businessPrefs);

      await _waitForSettingsLoad();
      await settings.setIosKeepAliveEnabled(true);
      await settings.setIosSilentAudioKeepAliveEnabled(true);
      await settings.setIosLocationKeepAliveEnabled(true);
      await settings.setIosLiveActivityPrivacyMode(true);

      final prefs = businessPrefs;
      expect(prefs.getBool('ios_keepalive_enabled_v1'), isTrue);
      expect(prefs.getBool('ios_silent_audio_keepalive_enabled_v1'), isTrue);
      expect(prefs.getBool('ios_location_keepalive_enabled_v1'), isTrue);
      expect(prefs.getBool('ios_live_activity_privacy_mode_v1'), isTrue);
    });
  });
}
