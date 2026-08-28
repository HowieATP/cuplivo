import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:drift/native.dart';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';

/// Regression tests for PR #403 fallout:
///
/// The side drawer started forcing `GroupChatProvider.load()` on the first
/// frame, which races `ChatService.init()` against `HomePageController
/// .initChat()`. Two concurrent inits opened/migrated the same SQLite file,
/// which surfaced as: wrong conversation on launch, empty assistant lists
/// (with group chats still present), or everything gone — recoverable by
/// restart because reads raced rather than data being lost.
///
/// Fix: ChatService.init() is single-flight, AssistantProvider.ensureLoaded()
/// waits for init instead of silently bailing on an uninitialized chat
/// service, and ensureDefaults() refuses to seed defaults over a non-empty
/// assistant table (putAssistants replaces the whole table, so an empty
/// in-memory read must never turn into a disk wipe).
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

/// Repository whose first [getAllAssistants] comes back empty even though the
/// table has rows — simulating the raced/failed in-memory read that used to
/// let `ensureDefaults` wipe real assistants with defaults.
class _FlakyFirstReadRepository extends ChatDatabaseRepository {
  _FlakyFirstReadRepository(super.db);

  bool failFirstRead = false;
  bool _firstReadConsumed = false;

  @override
  Future<List<Assistant>> getAllAssistants() async {
    if (failFirstRead && !_firstReadConsumed) {
      _firstReadConsumed = true;
      return const [];
    }
    return super.getAllAssistants();
  }
}

/// Chat service exposing a ready repository without touching the filesystem.
class _ReadyChatService extends ChatService {
  _ReadyChatService(this._testRepo);

  final ChatDatabaseRepository _testRepo;

  @override
  bool get initialized => true;

  @override
  ChatDatabaseRepository get repo => _testRepo;
}

void main() {
  var businessPrefs = BusinessPreferences.memoryForTests();
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  final services = <ChatService>[];

  setUp(() async {
    businessPrefs = BusinessPreferences.memoryForTests();
    tempDir = await Directory.systemTemp.createTemp('kelivo_init_race_test_');
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
    businessPrefs = BusinessPreferences.memoryForTests({});
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
    test(
      'second init() while first is in flight reuses the same future',
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
      },
    );

    test(
      'many parallel init() calls all complete and leave a usable service',
      () async {
        final service = createService();
        await Future.wait([for (var i = 0; i < 20; i++) service.init()]);
        expect(service.initialized, isTrue);

        // The service must be fully usable afterwards (no half-initialized
        // connection from a lost race).
        final conversation = await service.createDraftConversation(
          title: 'race test',
        );
        // Drafts only enter history once the first message is persisted.
        await service.addMessage(
          conversationId: conversation.id,
          role: 'user',
          content: 'hello',
        );
        expect(service.getAllConversations().map((c) => c.id), [
          conversation.id,
        ]);
      },
    );

    test('init() after completion is a cheap no-op', () async {
      final service = createService();
      await service.init();
      await service.init();
      expect(service.initialized, isTrue);
    });
  });

  group('AssistantProvider.ensureLoaded waits for chat init', () {
    test(
      'ensureLoaded triggers init instead of bailing on empty repo',
      () async {
        final service = createService();
        expect(service.initialized, isFalse);

        final provider = AssistantProvider(
          preferences: businessPrefs,
          chatService: service,
        );
        await provider.ensureLoaded();

        expect(
          service.initialized,
          isTrue,
          reason:
              'ensureLoaded must wait for ChatService.init so the real '
              'assistant list is read, not an empty one',
        );
      },
    );

    test(
      'ensureLoaded reads assistants persisted before a later load',
      () async {
        final service = createService();
        // Simulate the production ordering problem: another subsystem inits the
        // service and writes assistants while our provider is still unloaded.
        await service.init();
        // assistants_v1 is the entity key (physical SharedPreferences +
        // legacy source); _migrateFromPrefs consumes it into the repo.
        SharedPreferences.setMockInitialValues({
          'assistants_v1':
              '[{"id":"a1","name":"Real A"},{"id":"a2","name":"Real B"}]',
        });

        final provider = AssistantProvider(
          preferences: businessPrefs,
          chatService: service,
        );
        await provider.ensureLoaded();

        expect(provider.isLoaded, isTrue);
        expect(
          provider.assistants.map((a) => a.name),
          ['Real A', 'Real B'],
          reason:
              'ensureLoaded must read the migrated real assistants, '
              'not leave the list empty for ensureDefaults to overwrite',
        );
      },
    );
  });

  group('ensureDefaults wipe guard', () {
    Future<BuildContext> pumpLocalizedContext(WidgetTester tester) async {
      await tester.pumpWidget(
        Localizations(
          locale: const Locale('en'),
          delegates: AppLocalizations.localizationsDelegates,
          child: Builder(builder: (context) => const SizedBox.shrink()),
        ),
      );
      return tester.element(find.byType(Builder));
    }

    testWidgets('SQLite-seeded assistants survive ensureDefaults untouched', (
      tester,
    ) async {
      final context = await pumpLocalizedContext(tester);
      await tester.runAsync(() async {
        // Seed the real database file with assistants, then close. A fresh
        // service opens the same file on a cold start, exactly like the
        // production ordering (initChat boot vs provider load).
        final seedService = createService();
        await seedService.init();
        await seedService.repo.putAssistants([
          Assistant(id: 'real-1', name: 'Real One'),
          Assistant(id: 'real-2', name: 'Real Two'),
        ]);
        await seedService.close();

        final service = createService();
        final provider = AssistantProvider(
          preferences: businessPrefs,
          chatService: service,
        );
        await provider.ensureDefaults(context);

        expect(
          provider.assistants.map((a) => a.name),
          ['Real One', 'Real Two'],
          reason:
              'ensureDefaults must keep the seeded assistants, not swap '
              'them for the default assistants',
        );
        expect(
          (await service.repo.getAllAssistants()).map((a) => a.name),
          ['Real One', 'Real Two'],
          reason:
              'the assistant table must never be replaced with defaults '
              'when it already has rows',
        );
      });
    });

    testWidgets(
      'empty in-memory read reloads from disk instead of wiping the table',
      (tester) async {
        final context = await pumpLocalizedContext(tester);
        await tester.runAsync(() async {
          final db = AppDatabase(NativeDatabase.memory());
          addTearDown(db.close);
          final repo = _FlakyFirstReadRepository(db);
          await repo.putAssistants([
            Assistant(id: 'real-1', name: 'Real One'),
            Assistant(id: 'real-2', name: 'Real Two'),
          ]);
          // Simulate the raced read that used to trigger the wipe: the first
          // getAllAssistants() comes back empty although the table has rows.
          repo.failFirstRead = true;

          final provider = AssistantProvider(
            preferences: businessPrefs,
            chatService: _ReadyChatService(repo),
          );
          await provider.ensureDefaults(context);

          expect(
            provider.assistants.map((a) => a.name),
            ['Real One', 'Real Two'],
            reason:
                'the wipe guard must re-read the non-empty table instead of '
                'seeding defaults over it',
          );
          expect(
            (await repo.getAllAssistants()).map((a) => a.name),
            ['Real One', 'Real Two'],
            reason:
                'the seeded assistants must survive ensureDefaults untouched',
          );
        });
      },
    );
  });
}
