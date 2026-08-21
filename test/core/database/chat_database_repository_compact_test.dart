import 'dart:io';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/models/assistant.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ChatDatabaseRepository.compactDatabase', () {
    late Directory tempDir;
    late File dbFile;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('compact_db_test_');
      dbFile = File('${tempDir.path}/kelivo.sqlite');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test(
      'shrinks the database file after bulk deletes leave freelist holes',
      () async {
        final db = AppDatabase(NativeDatabase(dbFile));
        final repo = ChatDatabaseRepository(db, databaseFile: dbFile);
        addTearDown(() => repo.close());

        // Mirror production (AppDatabase._openExecutor): the connection runs
        // in WAL mode, where VACUUM writes into the WAL and the file only
        // shrinks on a subsequent TRUNCATE checkpoint.
        await db.customStatement('PRAGMA journal_mode = WAL;');

        // Insert enough rows that deleting them all leaves a measurable
        // amount of freelist pages behind.
        for (var i = 0; i < 500; i++) {
          await repo.putAssistant(
            Assistant(
              id: 'a$i',
              name: 'Assistant $i ${'x' * 200}',
              systemPrompt: 'prompt ${'y' * 200}',
            ),
          );
        }
        await repo.checkpoint();
        final sizeAfterInsert = dbFile.lengthSync();

        // Delete everything: pages are freed but, without VACUUM, the file
        // must NOT shrink yet.
        for (var i = 0; i < 500; i++) {
          await repo.deleteAssistant('a$i');
        }
        await repo.checkpoint();
        final sizeAfterDelete = dbFile.lengthSync();
        expect(
          sizeAfterDelete,
          greaterThanOrEqualTo(sizeAfterInsert),
          reason: 'delete-only must keep the file size (freelist retained)',
        );

        final result = await repo.compactDatabase();

        expect(
          result.savedBytes,
          greaterThan(0),
          reason: 'VACUUM should reclaim the freelist holes',
        );
        expect(result.afterBytes, lessThan(sizeAfterDelete));
        expect(result.beforeBytes, sizeAfterDelete);

        // The TRUNCATE checkpoint must have emptied the WAL file.
        final walFile = File('${dbFile.path}-wal');
        final walBytes = walFile.existsSync() ? walFile.lengthSync() : 0;
        expect(walBytes, 0, reason: 'TRUNCATE checkpoint must zero the WAL');

        // The repository must still be usable (main + reopened sync connection).
        expect(await repo.getAllAssistants(), isEmpty);
        await repo.putAssistant(Assistant(id: 'z', name: 'After compact'));
        expect((await repo.getAllAssistants()).single.id, 'z');

        // The reopened sync connection must be functional too, not just the
        // Drift main connection.
        expect(repo.getAllCompleteConversationsSync(), isEmpty);
      },
    );

    test('throws when no database file path is available', () {
      final db = AppDatabase(NativeDatabase.memory());
      final repo = ChatDatabaseRepository(db);
      addTearDown(() => repo.close());
      expect(repo.compactDatabase(), throwsStateError);
    });
  });
}
