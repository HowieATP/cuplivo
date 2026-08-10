import 'dart:convert';

import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/search/search_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('legacy search common JSON enables fallback fetch by default', () {
    final options = SearchCommonOptions.fromJson({
      'resultSize': 7,
      'timeout': 9000,
    });

    expect(options.enableFetchForUnsupportedProviders, isTrue);
  });

  test('fallback fetch setting round-trips and copyWith preserves it', () {
    final disabled = const SearchCommonOptions(
      resultSize: 7,
      timeout: 9000,
      enableFetchForUnsupportedProviders: false,
    );
    final decoded = SearchCommonOptions.fromJson(disabled.toJson());

    expect(decoded.enableFetchForUnsupportedProviders, isFalse);
    expect(
      decoded.copyWith(resultSize: 8).enableFetchForUnsupportedProviders,
      isFalse,
    );
    expect(
      decoded.copyWith(timeout: 10000).enableFetchForUnsupportedProviders,
      isFalse,
    );
  });

  test('SettingsProvider persists an explicitly disabled fallback', () async {
    SharedPreferences.setMockInitialValues({
      'search_common_v1': jsonEncode({'resultSize': 3, 'timeout': 4000}),
    });
    final settings = SettingsProvider();
    await pumpEventQueue();
    expect(
      settings.searchCommonOptions.enableFetchForUnsupportedProviders,
      isTrue,
    );

    await settings.setSearchCommonOptions(
      settings.searchCommonOptions.copyWith(
        enableFetchForUnsupportedProviders: false,
      ),
    );
    final prefs = await SharedPreferences.getInstance();
    final persisted = SearchCommonOptions.fromJson(
      jsonDecode(prefs.getString('search_common_v1')!) as Map<String, dynamic>,
    );
    expect(persisted.enableFetchForUnsupportedProviders, isFalse);
  });
}
