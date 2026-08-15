import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';

/// Regression tests for PR #403 fallout:
///
/// The side drawer started forcing `GroupChatProvider.load()` on the first
/// frame, which races `ChatService.init()` against `HomePageController
/// .initChat()`. Two concurrent inits opened/migrated the same SQLite file,
/// which surfaced as: wrong conversation on launch, empty assistant lists
/// (with group chats still present), or everything gone — recoverable by
/// restart because reads raced rather than data being lost.
///
/// Fix: ChatService.init() is single-flight, and AssistantProvider
/// .ensureLoaded() waits for init instead of silently bailing on an
/// uninitialized chat service (which would let ensureDefaults() wipe the
/// real assistant table with defaults via putAssistants).
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  final services = <ChatService>[];

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('kelivo_init_race_test_');
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
    SharedPreferences.setMockInitialValues({});
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

  group('ChatService init single-flight', () {
    test('second init() while first is in flight reuses the same future',
        () async {
      final service = createService();
      final f1 = service.init();
      final f2 = service.init();
      expect(
        identical(f1, f2),
        isTrue,
        reason: 'concurrent init() calls must share one initialization',
      );
      await Future.wait([f1, f2]);
      expect(service.initialized, isTrue);
    });

    test('many parallel init() calls all complete and leave a usable service',
        () async {
      final service = createService();
      await Future.wait([for (var i = 0; i < 20; i++) service.init()]);
      expect(service.initialized, isTrue);

      // The service must be fully usable afterwards (no half-initialized
      // connection from a lost race).
      final conversation = await service.createDraftConversation(
        title: 'race test',
      );
      expect(service.getAllConversations().map((c) => c.id), [
        conversation.id,
      ]);
    });

    test('init() after completion is a cheap no-op', () async {
      final service = createService();
      await service.init();
      await service.init();
      expect(service.initialized, isTrue);
    });
  });

  group('AssistantProvider.ensureLoaded waits for chat init', () {
    test('ensureLoaded triggers init instead of bailing on empty repo',
        () async {
      final service = createService();
      expect(service.initialized, isFalse);

      final provider = AssistantProvider(chatService: service);
      await provider.ensureLoaded();

      expect(
        service.initialized,
        isTrue,
        reason: 'ensureLoaded must wait for ChatService.init so the real '
            'assistant list is read, not an empty one',
      );
    });

    test('ensureLoaded reads assistants persisted before a later load',
        () async {
      final service = createService();
      // Simulate the production ordering problem: another subsystem inits the
      // service and writes assistants while our provider is still unloaded.
      await service.init();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'assistants_v1',
        '[{"id":"a1","name":"Real A"},{"id":"a2","name":"Real B"}]',
      );

      final provider = AssistantProvider(chatService: service);
      await provider.ensureLoaded();

      expect(provider.isLoaded, isTrue);
      expect(
        provider.assistants.map((a) => a.name),
        ['Real A', 'Real B'],
        reason: 'ensureLoaded must read the migrated real assistants, '
            'not leave the list empty for ensureDefaults to overwrite',
      );
    });
  });
}
