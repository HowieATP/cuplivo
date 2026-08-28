import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';

import 'package:Cuplivo/core/providers/assistant_provider.dart';

var businessPrefs = BusinessPreferences.memoryForTests();

Future<AssistantProvider> _createLoadedAssistantProvider({
  required BusinessPreferences preferences,
  required List<Map<String, Object?>> assistants,
  String currentAssistantId = 'assistant-a',
  bool? legacySearchEnabled,
}) async {
  // assistants_v1 = entity key → physical SharedPreferences (legacy source).
  SharedPreferences.setMockInitialValues({
    'assistants_v1': jsonEncode(assistants),
  });
  businessPrefs = BusinessPreferences.memoryForTests({
    'current_assistant_id_v1': currentAssistantId,
    if (legacySearchEnabled != null) 'search_enabled_v1': legacySearchEnabled,
  });

  final provider = AssistantProvider(preferences: businessPrefs);
  await provider.loadFromPrefs();
  return provider;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AssistantProvider per-assistant search', () {
    test(
      'loads missing assistant search from legacy global preference',
      () async {
        final provider = await _createLoadedAssistantProvider(
          preferences: businessPrefs,
          legacySearchEnabled: true,
          assistants: const [
            {'id': 'assistant-a', 'name': 'A'},
            {'id': 'assistant-b', 'name': 'B'},
          ],
        );

        expect(provider.assistants.map((a) => a.searchEnabled), [
          isTrue,
          isTrue,
        ]);
      },
    );

    test(
      'keeps explicit assistant search value during legacy migration',
      () async {
        final provider = await _createLoadedAssistantProvider(
          preferences: businessPrefs,
          legacySearchEnabled: true,
          assistants: const [
            {'id': 'assistant-a', 'name': 'A', 'searchEnabled': false},
            {'id': 'assistant-b', 'name': 'B'},
          ],
        );

        expect(provider.getById('assistant-a')?.searchEnabled, isFalse);
        expect(provider.getById('assistant-b')?.searchEnabled, isTrue);
      },
    );

    test('updates only the current assistant search value', () async {
      final provider = await _createLoadedAssistantProvider(
        preferences: businessPrefs,
        assistants: const [
          {'id': 'assistant-a', 'name': 'A'},
          {'id': 'assistant-b', 'name': 'B'},
        ],
      );

      await provider.setSearchEnabledForCurrentAssistant(true);

      expect(provider.getById('assistant-a')?.searchEnabled, isTrue);
      expect(provider.getById('assistant-b')?.searchEnabled, isFalse);

      await provider.setCurrentAssistant('assistant-b');

      expect(provider.currentSearchEnabled, isFalse);
    });
  });
}
