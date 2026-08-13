import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/providers/settings_provider.dart';

/// Cuplivo keeps business settings in SharedPreferences, so this replaces
/// Kelivo's SQLite-backed business test harness. The returned provider has
/// already finished its asynchronous [SettingsProvider._load] (a pure
/// microtask chain under the mock preferences backend), so callers can use
/// it synchronously afterwards.
Future<SettingsProvider> createBusinessTestPreferences({
  Map<String, Object> localInitial = const <String, Object>{},
}) async {
  SharedPreferences.setMockInitialValues(localInitial);
  final settings = SettingsProvider();
  for (var i = 0; i < 128; i++) {
    await Future<void>.value();
  }
  return settings;
}

/// Polls the mock clock for tests that need the async [SettingsProvider._load]
/// chain to settle inside `testWidgets` (fake-async) bodies.
Future<void> waitForSettingsLoad() async {
  for (var i = 0; i < 25; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
