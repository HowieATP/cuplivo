import 'dart:convert';

import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/tts/network_tts.dart';
import 'package:Cuplivo/core/services/tts/tts_text_selection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';

void main() {
  var businessPrefs = BusinessPreferences.memoryForTests();
  TestWidgetsFlutterBinding.ensureInitialized();

  test('loads and persists TTS playback settings', () async {
    businessPrefs = BusinessPreferences.memoryForTests(const {
      'tts_auto_play_assistant_replies_v1': true,
      'tts_text_selection_mode_v1': 'quotedOnly',
    });

    final settings = SettingsProvider(preferences: businessPrefs);
    await _waitUntil(() => settings.ttsAutoPlayAssistantReplies);

    expect(settings.ttsAutoPlayAssistantReplies, isTrue);
    expect(settings.ttsTextSelectionMode, TtsTextSelectionMode.quotedOnly);

    await settings.setTtsTextSelectionMode(TtsTextSelectionMode.nonItalic);
    await settings.setTtsAutoPlayAssistantReplies(false);

    final prefs = businessPrefs;
    expect(prefs.getString('tts_text_selection_mode_v1'), 'nonItalic');
    expect(prefs.getBool('tts_auto_play_assistant_replies_v1'), isFalse);
  });

  test('falls back to full text when persisted TTS mode is invalid', () async {
    businessPrefs = BusinessPreferences.memoryForTests(const {
      'tts_auto_play_assistant_replies_v1': true,
      'tts_text_selection_mode_v1': 'unknown-mode',
    });

    final settings = SettingsProvider(preferences: businessPrefs);
    await _waitUntil(() => settings.ttsAutoPlayAssistantReplies);

    expect(settings.ttsTextSelectionMode, TtsTextSelectionMode.fullText);
  });

  test(
    'migrates legacy TTS index to UUID and survives earlier deletion',
    () async {
      final services = <Map<String, dynamic>>[
        {
          'id': 'first-service',
          'kind': 'openai',
          'enabled': true,
          'name': 'First',
          'apiKey': 'key',
        },
        {
          'id': 'second-service',
          'kind': 'groq',
          'enabled': true,
          'name': 'Second',
          'apiKey': 'key',
        },
      ];
      businessPrefs = BusinessPreferences.memoryForTests({
        'tts_services_v1': jsonEncode(services),
        'tts_selected_v1': 1,
      });
      final settings = SettingsProvider(preferences: businessPrefs);
      await _waitUntil(() => settings.ttsServices.length == 2);

      expect(settings.selectedTtsServiceId, 'second-service');
      final prefs = businessPrefs;
      expect(prefs.getString('tts_selected_service_id_v1'), 'second-service');
      expect(prefs.getInt('tts_selected_v1'), isNull);

      final selected = settings.ttsServices.singleWhere(
        (service) => service.id == 'second-service',
      );
      await settings.setTtsServices(<TtsServiceOptions>[selected]);

      expect(settings.selectedTtsServiceId, 'second-service');
      expect(settings.selectedTtsService?.name, 'Second');
    },
  );

  test('persists generated UUIDs for legacy TTS rows across reloads', () async {
    businessPrefs = BusinessPreferences.memoryForTests({
      'tts_services_v1': jsonEncode(<Map<String, dynamic>>[
        {'kind': 'openai', 'enabled': true, 'name': 'First', 'apiKey': 'key'},
        {'kind': 'groq', 'enabled': true, 'name': 'Second', 'apiKey': 'key'},
      ]),
      'tts_selected_v1': 1,
    });
    final firstLoad = SettingsProvider(preferences: businessPrefs);
    await _waitUntil(() => firstLoad.selectedTtsServiceId != null);
    final selectedId = firstLoad.selectedTtsServiceId;

    expect(selectedId, isNotNull);
    expect(firstLoad.selectedTtsService?.name, 'Second');
    final prefs = businessPrefs;
    final persistedRows =
        jsonDecode(prefs.getString('tts_services_v1')!) as List<dynamic>;
    expect(
      persistedRows.every(
        (row) => ((row as Map<String, dynamic>)['id'] as String).isNotEmpty,
      ),
      isTrue,
    );

    final secondLoad = SettingsProvider(preferences: businessPrefs);
    await _waitUntil(() => secondLoad.selectedTtsServiceId == selectedId);
    expect(secondLoad.selectedTtsService?.name, 'Second');
  });
}

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for SettingsProvider condition');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
