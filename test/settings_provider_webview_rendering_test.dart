import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/backup/data_sync.dart' as backup_sync;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'experimental WebView rendering defaults off and persists changes',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final settings = SettingsProvider(
        preferences: BusinessPreferences.memoryForTests(),
      );
      await settings.loaded;

      expect(settings.experimentalWebViewRendering, isFalse);
      await settings.setExperimentalWebViewRendering(true);
      expect(settings.experimentalWebViewRendering, isTrue);
      expect(
        (await SharedPreferences.getInstance()).getBool(
          'experimental_webview_rendering_v1',
        ),
        isTrue,
      );
    },
  );

  test('experimental key is excluded from backup snapshots', () async {
    final prefs = BusinessPreferences.memoryForTests({
      'ordinary_setting': 'kept',
    });

    final snapshot = await backup_sync.SharedPreferencesAsync(prefs).snapshot();

    expect(snapshot, containsPair('ordinary_setting', 'kept'));
    expect(snapshot, isNot(contains('experimental_webview_rendering_v1')));
  });
}
