import 'package:flutter_test/flutter_test.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';

import 'package:Cuplivo/core/providers/settings_provider.dart';

var businessPrefs = BusinessPreferences.memoryForTests();

/// Cuplivo keeps business settings in the SQLite-backed business facade
/// (core/database/business_preferences.dart); this harness seeds its mock
/// memory store. The returned provider has already finished its asynchronous
/// [SettingsProvider._load] (a pure microtask chain under the mock
/// preferences backend), so callers can use it synchronously afterwards.
Future<SettingsProvider> createBusinessTestPreferences({
  Map<String, Object> localInitial = const <String, Object>{},
}) async {
  businessPrefs = BusinessPreferences.memoryForTests(localInitial);
  final settings = SettingsProvider(preferences: businessPrefs);
  // Microtask pumps, NOT `settings.loaded`: fake-async testWidgets bodies
  // cannot await real futures; every await in _load is a microtask under the
  // mock facade, so a pump tail settles it deterministically.
  for (var i = 0; i < 256; i++) {
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
