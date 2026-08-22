import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.path);

  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;

  @override
  Future<String?> getApplicationSupportPath() async => path;

  @override
  Future<String?> getApplicationCachePath() async => '$path/cache';

  @override
  Future<String?> getTemporaryPath() async => '$path/tmp';
}

Future<({AssistantProvider provider, SettingsProvider settings})>
_createLoadedAssistantProvider({
  required ChatService chatService,
  String currentAssistantId = 'assistant-delete',
}) async {
  SharedPreferences.setMockInitialValues({
    'assistants_v1': jsonEncode(const [
      {'id': 'assistant-delete', 'name': 'Delete Me'},
      {'id': 'assistant-keep', 'name': 'Keep Me'},
    ]),
    'current_assistant_id_v1': currentAssistantId,
    'startup_assistant_mode_v1': 'pinned',
    'pinned_assistant_id_v1': 'assistant-delete',
  });

  final settings = SettingsProvider();
  await settings.loaded;
  final provider = AssistantProvider(
    chatService: chatService,
    settings: settings,
  );
  await provider.ensureLoaded();
  return (provider: provider, settings: settings);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  final services = <ChatService>[];

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'kelivo_assistant_pin_clear_test_',
    );
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
  });

  tearDown(() async {
    for (final service in services) {
      await service.close();
    }
    services.clear();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  ChatService createService() {
    final service = ChatService();
    services.add(service);
    return service;
  }

  test(
    'deleting the pinned assistant clears the pin and reverts to mostRecent',
    () async {
      final chatService = createService();
      await chatService.init();
      final loaded = await _createLoadedAssistantProvider(
        chatService: chatService,
      );
      final provider = loaded.provider;
      final settings = loaded.settings;

      expect(await provider.deleteAssistant('assistant-delete'), isTrue);

      // Live in-memory state must be cleared too (single source of truth).
      expect(settings.pinnedAssistantId, isNull);
      expect(settings.startupAssistantMode, StartupAssistantMode.mostRecent);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('startup_assistant_mode_v1'), 'mostRecent');
      expect(prefs.getString('pinned_assistant_id_v1'), isNull);
    },
  );

  test('deleting a non-pinned assistant leaves the pin untouched', () async {
    final chatService = createService();
    await chatService.init();
    final loaded = await _createLoadedAssistantProvider(
      chatService: chatService,
    );
    final provider = loaded.provider;
    final settings = loaded.settings;

    expect(await provider.deleteAssistant('assistant-keep'), isTrue);

    expect(settings.pinnedAssistantId, 'assistant-delete');
    expect(settings.startupAssistantMode, StartupAssistantMode.pinned);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('startup_assistant_mode_v1'), 'pinned');
    expect(prefs.getString('pinned_assistant_id_v1'), 'assistant-delete');
  });
}
