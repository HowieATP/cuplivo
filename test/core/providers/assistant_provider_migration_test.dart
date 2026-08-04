import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:drift/native.dart';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/models/assistant.dart';

/// A minimal [ChatService] subclass backed by an in-memory database.
/// Only overrides the members [AssistantProvider] actually touches.
class _InMemoryChatService extends ChatService {
  late final AppDatabase db;
  late final ChatDatabaseRepository _testRepo;

  _InMemoryChatService() {
    db = AppDatabase(NativeDatabase.memory());
    _testRepo = ChatDatabaseRepository(db);
  }

  @override
  bool get initialized => true;

  @override
  ChatDatabaseRepository get repo => _testRepo;

  @override
  Future<List<Assistant>> getAllAssistants() => _testRepo.getAllAssistants();

  @override
  Future<void> putAssistants(List<Assistant> list) =>
      _testRepo.putAssistants(list);

  Future<void> closeDb() async {
    await _testRepo.close();
  }
}

/// [ChatDatabaseRepository] whose `putAssistants` can be made to throw, to
/// exercise the migration retry path (`_doLoad` writes through the repository,
/// not the service).
class _FlakyPutRepository extends ChatDatabaseRepository {
  _FlakyPutRepository(super.db);

  bool failPutAssistants = false;

  @override
  Future<void> putAssistants(List<Assistant> assistants) {
    if (failPutAssistants) {
      throw Exception('simulated write failure');
    }
    return super.putAssistants(assistants);
  }
}

class _FlakyPutChatService extends _InMemoryChatService {
  _FlakyPutChatService() {
    _flakyRepo = _FlakyPutRepository(db);
  }

  late final _FlakyPutRepository _flakyRepo;

  @override
  ChatDatabaseRepository get repo => _flakyRepo;

  bool get failPutAssistants => _flakyRepo.failPutAssistants;

  set failPutAssistants(bool value) => _flakyRepo.failPutAssistants = value;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AssistantProvider — SharedPreferences → DB migration', () {
    late _InMemoryChatService chatService;

    setUp(() {
      chatService = _InMemoryChatService();
    });

    tearDown(() async {
      await chatService.closeDb();
    });

    test(
      'migrates assistants_v1 from SharedPreferences to DB when DB empty',
      () async {
        SharedPreferences.setMockInitialValues({
          'assistants_v1': jsonEncode([
            {'id': 'a1', 'name': 'Migrated A'},
            {'id': 'a2', 'name': 'Migrated B'},
          ]),
          'current_assistant_id_v1': 'a1',
        });

        final provider = AssistantProvider(chatService: chatService);
        await provider.ensureLoaded();

        expect(provider.assistants.length, 2);
        expect(provider.assistants[0].name, 'Migrated A');
        expect(provider.currentAssistantId, 'a1');

        final fromDb = await chatService.getAllAssistants();
        expect(fromDb.length, 2);

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.containsKey('assistants_v1'), isFalse);
      },
      timeout: const Timeout(Duration(seconds: 5)),
    );

    test(
      'keeps DB data when both DB and SharedPreferences have data',
      () async {
        await chatService.putAssistants([
          Assistant(id: 'db-a', name: 'DB Alpha'),
        ]);

        SharedPreferences.setMockInitialValues({
          'assistants_v1': jsonEncode([
            {'id': 'sp-a', 'name': 'SP Alpha'},
          ]),
        });

        final provider = AssistantProvider(chatService: chatService);
        await provider.ensureLoaded();

        expect(provider.assistants.length, 1);
        expect(provider.assistants[0].id, 'db-a');
      },
    );

    test('persist writes to DB when chatService is available', () async {
      SharedPreferences.setMockInitialValues({
        'assistants_v1': jsonEncode([
          {'id': 'p1', 'name': 'Persist Test'},
        ]),
      });

      final provider = AssistantProvider(chatService: chatService);
      await provider.ensureLoaded();

      await provider.updateAssistant(
        provider.assistants[0].copyWith(name: 'Persisted'),
      );

      final fromDb = await chatService.getAllAssistants();
      expect(fromDb.length, 1);
      expect(fromDb[0].name, 'Persisted');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('assistants_v1'), isFalse);
    });
  });

  group('AssistantProvider — legacy OCR toggle → ocrMode', () {
    late _InMemoryChatService chatService;

    setUp(() async {
      chatService = _InMemoryChatService();
      await chatService.putAssistants([
        Assistant(id: 'a1', name: 'Alpha'),
        Assistant(id: 'a2', name: 'Beta'),
      ]);
    });

    tearDown(() async {
      await chatService.closeDb();
    });

    test(
      'legacy true migrates all assistants to auto and removes the key',
      () async {
        SharedPreferences.setMockInitialValues({'ocr_enabled_v1': true});

        final provider = AssistantProvider(chatService: chatService);
        await provider.ensureLoaded();

        expect(provider.assistants, hasLength(2));
        expect(provider.assistants.every((a) => a.ocrMode == 'auto'), isTrue);

        final fromDb = await chatService.getAllAssistants();
        expect(fromDb.every((a) => a.ocrMode == 'auto'), isTrue);

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.containsKey('ocr_enabled_v1'), isFalse);
      },
    );

    test(
      'legacy false migrates all assistants to never and removes the key',
      () async {
        SharedPreferences.setMockInitialValues({'ocr_enabled_v1': false});

        final provider = AssistantProvider(chatService: chatService);
        await provider.ensureLoaded();

        expect(provider.assistants.every((a) => a.ocrMode == 'never'), isTrue);

        final fromDb = await chatService.getAllAssistants();
        expect(fromDb.every((a) => a.ocrMode == 'never'), isTrue);

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.containsKey('ocr_enabled_v1'), isFalse);
      },
    );

    test('removes the legacy key even with zero assistants', () async {
      final emptyChat = _InMemoryChatService();
      addTearDown(emptyChat.closeDb);

      SharedPreferences.setMockInitialValues({'ocr_enabled_v1': false});

      final provider = AssistantProvider(chatService: emptyChat);
      await provider.ensureLoaded();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('ocr_enabled_v1'), isFalse);
    });

    test('preserves manual ocrMode once the legacy key is consumed', () async {
      SharedPreferences.setMockInitialValues({'ocr_enabled_v1': false});

      final provider = AssistantProvider(chatService: chatService);
      await provider.ensureLoaded();
      await provider.updateAssistant(
        provider.assistants[0].copyWith(ocrMode: 'always'),
      );

      // Second load must NOT re-apply the legacy mapping (key already gone).
      final provider2 = AssistantProvider(chatService: chatService);
      await provider2.ensureLoaded();
      final updated = provider2.assistants.firstWhere(
        (a) => a.id == provider.assistants[0].id,
      );
      expect(updated.ocrMode, 'always');
    });

    test(
      'keeps the legacy key when the DB write fails, retries next launch',
      () async {
        final flaky = _FlakyPutChatService();
        addTearDown(flaky.closeDb);
        await flaky.putAssistants([Assistant(id: 'a1', name: 'Alpha')]);

        SharedPreferences.setMockInitialValues({'ocr_enabled_v1': false});

        flaky.failPutAssistants = true;
        final provider = AssistantProvider(chatService: flaky);
        await provider.ensureLoaded();

        // Write failed -> key retained, mapping NOT applied to the DB.
        var prefs = await SharedPreferences.getInstance();
        expect(prefs.containsKey('ocr_enabled_v1'), isTrue);
        var fromDb = await flaky.getAllAssistants();
        expect(fromDb.single.ocrMode, 'auto');

        // Next launch succeeds -> mapping applied and key consumed.
        flaky.failPutAssistants = false;
        final provider2 = AssistantProvider(chatService: flaky);
        await provider2.ensureLoaded();

        prefs = await SharedPreferences.getInstance();
        expect(prefs.containsKey('ocr_enabled_v1'), isFalse);
        fromDb = await flaky.getAllAssistants();
        expect(fromDb.single.ocrMode, 'never');
      },
    );
  });
}
