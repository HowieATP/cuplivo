import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path/path.dart' as p;
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/backup.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/models/incremental_backup.dart';
import 'package:Cuplivo/core/services/backup/data_sync.dart';
import 'package:Cuplivo/core/services/backup/kelivo_v2_exception.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/search/search_service.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.root);

  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getApplicationCachePath() async => '$root/cache';

  @override
  Future<String?> getTemporaryPath() async => '$root/tmp';
}

/// An initialized [ChatService] backed by an in-memory database, for restore
/// paths that require `chatService.initialized`.
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

  @override
  Future<void> reloadCachesFromDb() async {}

  Future<void> closeDb() async {
    await _testRepo.close();
  }
}

void main() {
  group('DataSync backup file', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('kelivo_data_sync_test_');
      PathProviderPlatform.instance = _FakePathProviderPlatform(root.path);
      SharedPreferences.setMockInitialValues({'backup_test_key': 'value'});
    });

    tearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    test(
      'packs files as deflated zip entries and removes staging files',
      () async {
        final uploadDir = Directory('${root.path}/upload');
        await uploadDir.create(recursive: true);
        final uploadFile = File('${uploadDir.path}/large.bin');
        await uploadFile.writeAsBytes(List<int>.filled(1024 * 1024, 7));
        final fontsDir = Directory('${root.path}/fonts');
        await fontsDir.create(recursive: true);
        final fontFile = File('${fontsDir.path}/custom.ttf');
        await fontFile.writeAsBytes(List<int>.filled(256, 9));

        final tmpDir = Directory('${root.path}/tmp');
        final staleWorkDir = Directory('${tmpDir.path}/kelivo_backup_stale');
        await staleWorkDir.create(recursive: true);
        await File('${staleWorkDir.path}/orphan.zip').writeAsString('old');
        await File('${tmpDir.path}/kelivo_backup_old.zip').writeAsString('old');
        await File('${tmpDir.path}/_bk_chats.json').writeAsString('{}');

        final sync = DataSync(chatService: ChatService());
        final backupFile = await sync.prepareBackupFile(
          const WebDavConfig(includeChats: false, includeFiles: true),
        );

        expect(await staleWorkDir.exists(), isFalse);
        expect(
          await File('${tmpDir.path}/kelivo_backup_old.zip').exists(),
          isFalse,
        );
        expect(await File('${tmpDir.path}/_bk_chats.json').exists(), isFalse);

        final input = InputFileStream(backupFile.path);
        Archive? archive;
        try {
          archive = ZipDecoder().decodeStream(input);
          final settingsEntry = archive.findFile('settings.json');
          final uploadEntry = archive.findFile('upload/large.bin');
          final fontEntry = archive.findFile('fonts/custom.ttf');

          expect(settingsEntry, isNotNull);
          expect(uploadEntry, isNotNull);
          expect(fontEntry, isNotNull);
          expect(settingsEntry!.compression, CompressionType.deflate);
          expect(uploadEntry!.compression, CompressionType.deflate);
          expect(fontEntry!.compression, CompressionType.deflate);
          expect(uploadEntry.readBytes(), List<int>.filled(1024 * 1024, 7));
          expect(fontEntry.readBytes(), List<int>.filled(256, 9));
        } finally {
          archive?.clearSync();
          input.closeSync();
        }

        expect(
          await File('${backupFile.parent.path}/_bk_settings.json').exists(),
          isFalse,
        );

        await DataSync.cleanupTemporaryBackupFile(backupFile);

        expect(await backupFile.exists(), isFalse);
        expect(await backupFile.parent.exists(), isFalse);
      },
    );

    test('restores managed font files in overwrite and merge modes', () async {
      final sourceDir = Directory('${root.path}/source_fonts');
      await sourceDir.create(recursive: true);
      final sourceFile = File('${sourceDir.path}/custom.ttf');
      await sourceFile.writeAsBytes(List<int>.filled(128, 5));

      final zipFile = File('${root.path}/fonts_backup.zip');
      final encoder = ZipFileEncoder();
      encoder.create(zipFile.path);
      encoder.addFileSync(sourceFile, 'fonts/custom.ttf');
      encoder.closeSync();

      final fontsDir = Directory('${root.path}/fonts');
      await fontsDir.create(recursive: true);
      final existingFile = File('${fontsDir.path}/existing.ttf');
      await existingFile.writeAsBytes(List<int>.filled(64, 3));

      final sync = DataSync(chatService: ChatService());
      await sync.restoreFromLocalFile(
        zipFile,
        const WebDavConfig(includeChats: false, includeFiles: true),
        mode: RestoreMode.merge,
      );

      expect(await existingFile.exists(), isTrue);
      expect(
        await File('${fontsDir.path}/custom.ttf').readAsBytes(),
        List<int>.filled(128, 5),
      );

      await sync.restoreFromLocalFile(
        zipFile,
        const WebDavConfig(includeChats: false, includeFiles: true),
        mode: RestoreMode.overwrite,
      );

      expect(await existingFile.exists(), isFalse);
      expect(
        await File('${fontsDir.path}/custom.ttf').readAsBytes(),
        List<int>.filled(128, 5),
      );
    });

    test('restores skill files in overwrite and merge modes', () async {
      final sourceDir = Directory('${root.path}/source_skills');
      await sourceDir.create(recursive: true);
      final sourceFile = File('${sourceDir.path}/pdf-processing/SKILL.md');
      await sourceFile.create(recursive: true);
      await sourceFile.writeAsString('---\nname: pdf-processing\n---\nbody');

      final zipFile = File('${root.path}/skills_backup.zip');
      final encoder = ZipFileEncoder();
      encoder.create(zipFile.path);
      encoder.addFileSync(sourceFile, 'skills/pdf-processing/SKILL.md');
      encoder.closeSync();

      final skillsDir = Directory('${root.path}/skills');
      await skillsDir.create(recursive: true);
      final existingFile = File('${skillsDir.path}/local-skill/SKILL.md');
      await existingFile.create(recursive: true);
      await existingFile.writeAsString('---\nname: local-skill\n---\nbody');

      final sync = DataSync(chatService: ChatService());
      await sync.restoreFromLocalFile(
        zipFile,
        const WebDavConfig(includeChats: false, includeFiles: true),
        mode: RestoreMode.merge,
      );

      expect(await existingFile.exists(), isTrue);
      expect(
        await File('${skillsDir.path}/pdf-processing/SKILL.md').readAsString(),
        contains('name: pdf-processing'),
      );

      await sync.restoreFromLocalFile(
        zipFile,
        const WebDavConfig(includeChats: false, includeFiles: true),
        mode: RestoreMode.overwrite,
      );

      expect(await existingFile.exists(), isFalse);
      expect(
        await File('${skillsDir.path}/pdf-processing/SKILL.md').readAsString(),
        contains('name: pdf-processing'),
      );
    });

    test(
      'merge restore replaces skills only when the backup entry is newer',
      () async {
        final sourceDir = Directory('${root.path}/source_skills');
        await sourceDir.create(recursive: true);
        final sourceFile = File('${sourceDir.path}/pdf-processing/SKILL.md');
        await sourceFile.create(recursive: true);
        await sourceFile.writeAsString(
          '---\nname: pdf-processing\n---\nbackup version',
        );
        // Even seconds: ZIP DOS timestamps round down to 2s granularity.
        await sourceFile.setLastModified(DateTime(2026, 1, 2));

        final zipFile = File('${root.path}/skills_backup.zip');
        final encoder = ZipFileEncoder();
        encoder.create(zipFile.path);
        encoder.addFileSync(sourceFile, 'skills/pdf-processing/SKILL.md');
        encoder.closeSync();

        final skillsDir = Directory('${root.path}/skills');
        await skillsDir.create(recursive: true);
        final localFile = File('${skillsDir.path}/pdf-processing/SKILL.md');
        await localFile.create(recursive: true);
        await localFile.writeAsString(
          '---\nname: pdf-processing\n---\nlocal version',
        );
        await localFile.setLastModified(DateTime(2026, 1, 1));

        final sync = DataSync(chatService: ChatService());
        await sync.restoreFromLocalFile(
          zipFile,
          const WebDavConfig(includeChats: false, includeFiles: true),
          mode: RestoreMode.merge,
        );

        // Backup entry (Jan 2) is newer than the local copy (Jan 1) → replaced.
        expect(await localFile.readAsString(), contains('backup version'));

        // Local copy becomes newer than the backup entry (Jan 3) → kept.
        await localFile.writeAsString(
          '---\nname: pdf-processing\n---\nlocal version',
        );
        await localFile.setLastModified(DateTime(2026, 1, 3));
        await sync.restoreFromLocalFile(
          zipFile,
          const WebDavConfig(includeChats: false, includeFiles: true),
          mode: RestoreMode.merge,
        );

        expect(await localFile.readAsString(), contains('local version'));
      },
    );

    test('merge restore replaces workspaces files only when the backup entry '
        'is newer', () async {
      final sourceDir = Directory('${root.path}/source_ws');
      await sourceDir.create(recursive: true);
      final sourceFile = File('${sourceDir.path}/default/report.md');
      await sourceFile.create(recursive: true);
      await sourceFile.writeAsString('backup version');
      // Even seconds: ZIP DOS timestamps round down to 2s granularity.
      await sourceFile.setLastModified(DateTime(2026, 1, 2));

      final zipFile = File('${root.path}/ws_backup.zip');
      final encoder = ZipFileEncoder();
      encoder.create(zipFile.path);
      encoder.addFileSync(sourceFile, 'workspaces/default/report.md');
      encoder.closeSync();

      final wsDir = Directory('${root.path}/workspaces');
      await wsDir.create(recursive: true);
      final localFile = File('${wsDir.path}/default/report.md');
      await localFile.create(recursive: true);
      await localFile.writeAsString('local version');
      await localFile.setLastModified(DateTime(2026, 1, 1));

      final sync = DataSync(chatService: ChatService());
      await sync.restoreFromLocalFile(
        zipFile,
        const WebDavConfig(includeChats: false, includeFiles: true),
        mode: RestoreMode.merge,
      );

      // Backup entry (Jan 2) is newer than the local copy (Jan 1) →
      // replaced (newer-wins, same rule as skills).
      expect(await localFile.readAsString(), contains('backup version'));

      // Local copy becomes newer than the backup entry (Jan 3) → kept.
      await localFile.writeAsString('local version');
      await localFile.setLastModified(DateTime(2026, 1, 3));
      await sync.restoreFromLocalFile(
        zipFile,
        const WebDavConfig(includeChats: false, includeFiles: true),
        mode: RestoreMode.merge,
      );

      expect(await localFile.readAsString(), contains('local version'));
    });

    test(
      'countFilesForSince mirrors pack rules (mtime, dot, skills)',
      () async {
        final since = DateTime(2026, 1, 1, 12);
        // upload/: one file before since (excluded), one after (included).
        final uploadDir = Directory('${root.path}/upload');
        await uploadDir.create(recursive: true);
        final oldFile = File('${uploadDir.path}/old.bin');
        await oldFile.writeAsBytes(List<int>.filled(10, 1));
        await oldFile.setLastModified(DateTime(2026, 1, 1, 11));
        final newFile = File('${uploadDir.path}/new.bin');
        await newFile.writeAsBytes(List<int>.filled(20, 2));
        await newFile.setLastModified(DateTime(2026, 1, 2));

        // workspaces/: visible file after since (included), dot-prefixed file
        // after since (excluded — one dotfile rule, mirrors _packZipSync).
        final wsDir = Directory('${root.path}/workspaces/default');
        await wsDir.create(recursive: true);
        final wsFile = File('${wsDir.path}/note.md');
        await wsFile.writeAsBytes(List<int>.filled(30, 3));
        await wsFile.setLastModified(DateTime(2026, 1, 2));
        final dotFile = File('${wsDir.path}/.fetch_cache/x.md');
        await dotFile.create(recursive: true);
        await dotFile.writeAsBytes(List<int>.filled(40, 4));
        await dotFile.setLastModified(DateTime(2026, 1, 2));

        // skills/: one file after since (always counted).
        final skillsDir = Directory('${root.path}/skills');
        await skillsDir.create(recursive: true);
        final skillFile = File('${skillsDir.path}/pdf-processing/SKILL.md');
        await skillFile.create(recursive: true);
        await skillFile.writeAsBytes(List<int>.filled(50, 5));
        await skillFile.setLastModified(DateTime(2026, 1, 2));

        final sync = DataSync(chatService: ChatService());
        final result = await sync.countFilesForSince(since);

        // upload new.bin (20) + workspaces note.md (30) + skill (50).
        expect(result.fileCount, 3);
        expect(result.totalBytes, 100);
      },
    );

    test(
      'merge restore newer-wins survives odd-second mtimes (UT timestamp)',
      () async {
        // Round-trip through the PRODUCTION writer + extractor: a genuinely
        // newer peer copy whose mtime is an odd second (2026-01-02 00:00:57)
        // must win over a local copy 500 ms older. DOS timestamps round down
        // to even seconds (56) and would lose to 56.5; the UT (0x5455) extra
        // field must carry the true second.
        final wsDir = Directory('${root.path}/workspaces/default');
        await wsDir.create(recursive: true);
        final liveFile = File('${wsDir.path}/report.md');
        await liveFile.create(recursive: true);
        await liveFile.writeAsString('backup version');
        await liveFile.setLastModified(DateTime(2026, 1, 2, 0, 0, 57));

        final sync = DataSync(chatService: ChatService());
        final zipFile = await sync.prepareBackupFile(
          const WebDavConfig(includeChats: false, includeFiles: true),
          incremental: IncrementalBackupConfig(
            since: DateTime(2026, 1, 1),
            includeSettings: false,
            includeFiles: true,
            updateBackupTime: false,
          ),
        );

        // The live copy now becomes device B's genuinely older copy (56.5s,
        // inside the 2s DOS rounding window).
        await liveFile.writeAsString('local version');
        await liveFile.setLastModified(DateTime(2026, 1, 2, 0, 0, 56, 500));

        await sync.restoreFromLocalFile(
          zipFile,
          const WebDavConfig(includeChats: false, includeFiles: true),
          mode: RestoreMode.merge,
        );

        // Odd-second backup mtime must win (57 > 56.5).
        expect(await liveFile.readAsString(), contains('backup version'));

        // Local copy becomes genuinely newer (57.5s) → kept.
        await liveFile.writeAsString('local version');
        await liveFile.setLastModified(DateTime(2026, 1, 2, 0, 0, 57, 500));
        await sync.restoreFromLocalFile(
          zipFile,
          const WebDavConfig(includeChats: false, includeFiles: true),
          mode: RestoreMode.merge,
        );

        expect(await liveFile.readAsString(), contains('local version'));
      },
    );

    test(
      'restore progress fraction never regresses across directories',
      () async {
        // Three trees so the cumulative totalFiles jumps at directory
        // boundaries (upload → images → workspaces). The raw fraction would
        // dip to 0.5 after upload/ completes; the reported fraction must be
        // monotonic non-decreasing.
        final zipFile = File('${root.path}/progress.zip');
        final encoder = ZipFileEncoder();
        encoder.create(zipFile.path);
        final src = Directory('${root.path}/progress_src');
        for (final name in [
          'upload/a.txt',
          'images/b.txt',
          'workspaces/c.txt',
        ]) {
          final f = File('${src.path}/$name');
          await f.create(recursive: true);
          await f.writeAsString(name);
          encoder.addFileSync(f, name);
        }
        encoder.closeSync();

        final sync = DataSync(chatService: ChatService());
        final fractions = <double>[];
        await sync.restoreFromLocalFile(
          zipFile,
          const WebDavConfig(includeChats: false, includeFiles: true),
          mode: RestoreMode.merge,
          onProgress: (p) {
            if (p.stage == RestoreStage.copyingFiles && p.fraction != null) {
              fractions.add(p.fraction!);
            }
          },
        );

        expect(fractions, isNotEmpty);
        for (var i = 1; i < fractions.length; i++) {
          expect(
            fractions[i],
            greaterThanOrEqualTo(fractions[i - 1]),
            reason:
                'fraction regressed at index $i: ${fractions[i - 1]} -> '
                '${fractions[i]}',
          );
        }
      },
    );

    test(
      'skills are exported and restored regardless of includeFiles',
      () async {
        final skillsDir = Directory('${root.path}/skills');
        await skillsDir.create(recursive: true);
        final skillFile = File('${skillsDir.path}/pdf-processing/SKILL.md');
        await skillFile.create(recursive: true);
        await skillFile.writeAsString('---\nname: pdf-processing\n---\nbody');

        final sync = DataSync(chatService: ChatService());
        final backupFile = await sync.prepareBackupFile(
          const WebDavConfig(includeChats: false, includeFiles: false),
        );

        final input = InputFileStream(backupFile.path);
        Archive? archive;
        try {
          archive = ZipDecoder().decodeStream(input);
          expect(archive.findFile('skills/pdf-processing/SKILL.md'), isNotNull);
        } finally {
          archive?.clearSync();
          input.closeSync();
        }

        await skillsDir.delete(recursive: true);
        await sync.restoreFromLocalFile(
          backupFile,
          const WebDavConfig(includeChats: false, includeFiles: false),
          mode: RestoreMode.overwrite,
        );

        expect(await skillFile.exists(), isTrue);
        expect(
          await skillFile.readAsString(),
          contains('name: pdf-processing'),
        );

        await DataSync.cleanupTemporaryBackupFile(backupFile);
      },
    );

    test(
      'incremental: analyzeIncrementalScope counts skills unconditionally',
      () async {
        final chatService = ChatService();
        await chatService.init();

        final since = DateTime.now().subtract(const Duration(days: 30));
        final skillsDir = Directory('${root.path}/skills');
        await skillsDir.create(recursive: true);
        final skillFile = File('${skillsDir.path}/pdf-processing/SKILL.md');
        await skillFile.create(recursive: true);
        await skillFile.writeAsString('---\nname: pdf-processing\n---\nbody');

        final sync = DataSync(chatService: chatService);
        final scope = await sync.analyzeIncrementalScope(
          IncrementalBackupConfig(since: since, includeFiles: false),
        );

        expect(scope.newFileCount, 1);

        await chatService.close();
      },
    );

    test(
      'merge restore imports assistant memories and mcp servers without clobbering local entries',
      () async {
        SharedPreferences.setMockInitialValues({
          'assistant_memories_v1': jsonEncode([
            {'id': 1, 'assistantId': 'local', 'content': 'keep local'},
            {'id': 2, 'assistantId': 'dup', 'content': 'same memory'},
          ]),
          'mcp_servers_v1': jsonEncode([
            {
              'id': 'local-server',
              'enabled': true,
              'name': 'Local Server',
              'transport': 'sse',
              'url': 'http://local.example/sse',
              'tools': [],
            },
            {
              'id': 'shared-server',
              'enabled': true,
              'name': 'Local Shared Server',
              'transport': 'sse',
              'url': 'http://local-shared.example/sse',
              'tools': [],
            },
          ]),
        });

        final settingsFile = File('${root.path}/settings.json');
        await settingsFile.writeAsString(
          jsonEncode({
            'assistant_memories_v1': jsonEncode([
              {'id': 1, 'assistantId': 'remote', 'content': 'remote memory'},
              {'id': 2, 'assistantId': 'dup', 'content': 'same memory'},
              {'id': 4, 'assistantId': 'new', 'content': 'new memory'},
            ]),
            'mcp_servers_v1': jsonEncode([
              {
                'id': 'shared-server',
                'enabled': false,
                'name': 'Imported Shared Server',
                'transport': 'sse',
                'url': 'http://imported-shared.example/sse',
                'tools': [],
              },
              {
                'id': 'remote-server',
                'enabled': true,
                'name': 'Remote Server',
                'transport': 'http',
                'url': 'http://remote.example/mcp',
                'tools': [],
              },
            ]),
          }),
        );

        final zipFile = File('${root.path}/settings_merge_backup.zip');
        final encoder = ZipFileEncoder();
        encoder.create(zipFile.path);
        encoder.addFileSync(settingsFile, 'settings.json');
        encoder.closeSync();

        final sync = DataSync(chatService: ChatService());
        await sync.restoreFromLocalFile(
          zipFile,
          const WebDavConfig(includeChats: false, includeFiles: false),
          mode: RestoreMode.merge,
        );

        final prefs = await SharedPreferences.getInstance();
        final memories =
            jsonDecode(prefs.getString('assistant_memories_v1')!) as List;
        expect(memories, hasLength(4));
        expect(
          memories.where(
            (e) =>
                (e as Map)['assistantId'] == 'dup' &&
                e['content'] == 'same memory',
          ),
          hasLength(1),
        );
        expect(
          memories.any(
            (e) =>
                (e as Map)['assistantId'] == 'remote' &&
                e['content'] == 'remote memory' &&
                e['id'] != 1,
          ),
          isTrue,
        );
        expect(
          memories.any(
            (e) =>
                (e as Map)['assistantId'] == 'new' &&
                e['content'] == 'new memory' &&
                e['id'] == 4,
          ),
          isTrue,
        );

        final servers = jsonDecode(prefs.getString('mcp_servers_v1')!) as List;
        expect(servers, hasLength(3));
        expect(
          servers
              .where((e) => (e as Map)['id'] == 'shared-server')
              .single['name'],
          'Local Shared Server',
        );
        expect(
          servers.any(
            (e) =>
                (e as Map)['id'] == 'remote-server' &&
                e['name'] == 'Remote Server',
          ),
          isTrue,
        );
      },
    );

    test('cleans temporary restore files after a file-copy failure', () async {
      final sourceDir = Directory('${root.path}/source_upload');
      await sourceDir.create(recursive: true);
      final sourceFile = File('${sourceDir.path}/file.txt');
      await sourceFile.writeAsString('payload');

      final zipFile = File('${root.path}/restore_source.zip');
      final encoder = ZipFileEncoder();
      encoder.create(zipFile.path);
      encoder.addFileSync(sourceFile, 'upload/file.txt');
      encoder.closeSync();

      // A file occupying the upload target makes the files-restore step throw
      // (EEXIST). Since #475, that failure is logged-and-continued — the
      // restore completes and the downloaded temp file is still cleaned up.
      await File('${root.path}/upload').writeAsString('not a directory');

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        request.response.statusCode = HttpStatus.ok;
        await request.response.addStream(zipFile.openRead());
        await request.response.close();
      });

      final sync = DataSync(chatService: ChatService());
      final tmpDir = Directory('${root.path}/tmp');
      final item = BackupFileItem(
        href: Uri.parse('http://127.0.0.1:${server.port}/restore_source.zip'),
        displayName: 'restore_source.zip',
        size: await zipFile.length(),
        lastModified: null,
      );

      await sync.restoreFromWebDav(
        const WebDavConfig(includeChats: false, includeFiles: true),
        item,
      );

      expect(await File('${tmpDir.path}/restore_source.zip').exists(), isFalse);
      expect(await tmpDir.list().toList(), isEmpty);
    });

    test(
      'incremental: since param produces cuplivo_incr_ prefix and includeSettings=false excludes settings.json',
      () async {
        final sync = DataSync(chatService: ChatService());
        final backupFile = await sync.prepareBackupFile(
          const WebDavConfig(includeChats: false, includeFiles: false),
          incremental: IncrementalBackupConfig(
            since: DateTime.now().subtract(const Duration(days: 30)),
            includeSettings: false,
          ),
        );

        expect(p.basename(backupFile.path).startsWith('cuplivo_incr_'), isTrue);

        final input = InputFileStream(backupFile.path);
        Archive? archive;
        try {
          archive = ZipDecoder().decodeStream(input);
          expect(archive.findFile('settings.json'), isNull);
        } finally {
          archive?.clearSync();
          input.closeSync();
        }

        await DataSync.cleanupTemporaryBackupFile(backupFile);
      },
    );

    test(
      'incremental: no since param produces normal filename without cuplivo_incr_',
      () async {
        final sync = DataSync(chatService: ChatService());
        final backupFile = await sync.prepareBackupFile(
          const WebDavConfig(includeChats: false, includeFiles: false),
        );

        expect(
          p.basename(backupFile.path).startsWith('cuplivo_incr_'),
          isFalse,
        );
        expect(
          p.basename(backupFile.path),
          matches(RegExp(r'kelivo_backup_\d{8}T\d{6}\.\d{6}\.zip')),
        );

        await DataSync.cleanupTemporaryBackupFile(backupFile);
      },
    );

    test(
      'incremental: cuplivo_incr_ filename forces merge mode on restore',
      () async {
        final zipFile = File(
          '${root.path}/cuplivo_incr_20260703-123456-123456_20260701-000000.zip',
        );
        final encoder = ZipFileEncoder();
        encoder.create(zipFile.path);
        final settingsTmp = File('${root.path}/tmp_settings.json');
        await settingsTmp.writeAsString('{}');
        encoder.addFileSync(settingsTmp, 'settings.json');
        encoder.closeSync();

        final sync = DataSync(chatService: ChatService());
        // Should not throw: overwrite mode is silently degraded to merge
        await sync.restoreFromLocalFile(
          zipFile,
          const WebDavConfig(includeChats: false, includeFiles: false),
          mode: RestoreMode.overwrite,
        );
      },
    );

    test('incremental: includeFiles=true packs upload and fonts', () async {
      final uploadDir = Directory('${root.path}/upload');
      await uploadDir.create(recursive: true);
      await File('${uploadDir.path}/doc.txt').writeAsString('hello');
      final fontsDir = Directory('${root.path}/fonts');
      await fontsDir.create(recursive: true);
      await File(
        '${fontsDir.path}/custom.ttf',
      ).writeAsBytes(List<int>.filled(64, 9));

      final sync = DataSync(chatService: ChatService());
      final backupFile = await sync.prepareBackupFile(
        const WebDavConfig(includeChats: false, includeFiles: true),
        incremental: IncrementalBackupConfig(
          since: DateTime.now().subtract(const Duration(days: 30)),
          includeFiles: true,
        ),
      );

      final input = InputFileStream(backupFile.path);
      Archive? archive;
      try {
        archive = ZipDecoder().decodeStream(input);
        expect(archive.findFile('settings.json'), isNotNull);
        expect(archive.findFile('upload/doc.txt'), isNotNull);
        expect(archive.findFile('fonts/custom.ttf'), isNotNull);
      } finally {
        archive?.clearSync();
        input.closeSync();
      }

      await DataSync.cleanupTemporaryBackupFile(backupFile);
    });

    test('incremental: includeFiles=false excludes files', () async {
      final uploadDir = Directory('${root.path}/upload');
      await uploadDir.create(recursive: true);
      await File('${uploadDir.path}/doc.txt').writeAsString('hello');

      final sync = DataSync(chatService: ChatService());
      final backupFile = await sync.prepareBackupFile(
        const WebDavConfig(includeChats: false, includeFiles: true),
        incremental: IncrementalBackupConfig(
          since: DateTime.now().subtract(const Duration(days: 30)),
          includeSettings: false,
          includeFiles: false,
        ),
      );

      final input = InputFileStream(backupFile.path);
      Archive? archive;
      try {
        archive = ZipDecoder().decodeStream(input);
        expect(archive.findFile('settings.json'), isNull);
        expect(archive.findFile('upload/doc.txt'), isNull);
      } finally {
        archive?.clearSync();
        input.closeSync();
      }

      await DataSync.cleanupTemporaryBackupFile(backupFile);
    });

    test(
      'incremental: message-level filtering captures old conversation with new messages',
      () async {
        final chatService = ChatService();
        await chatService.init();

        final oldDate = DateTime.now().subtract(const Duration(days: 60));
        final recentDate = DateTime.now().subtract(const Duration(days: 1));
        final since = DateTime.now().subtract(const Duration(days: 30));

        final conv = Conversation(
          id: 'test-conv-1',
          title: 'Old Conversation',
          createdAt: oldDate,
          updatedAt: recentDate,
          messageIds: ['msg-old', 'msg-recent'],
        );
        final oldMsg = ChatMessage(
          id: 'msg-old',
          role: 'user',
          content: 'old message',
          timestamp: oldDate,
          conversationId: conv.id,
          isStreaming: false,
        );
        final recentMsg = ChatMessage(
          id: 'msg-recent',
          role: 'assistant',
          content: 'recent message',
          timestamp: recentDate,
          conversationId: conv.id,
          isStreaming: false,
        );
        await chatService.restoreConversation(conv, [oldMsg, recentMsg]);

        final sync = DataSync(chatService: chatService);
        final backupFile = await sync.prepareBackupFile(
          const WebDavConfig(includeChats: true, includeFiles: false),
          incremental: IncrementalBackupConfig(
            since: since,
            includeSettings: false,
            includeFiles: false,
          ),
        );

        final input = InputFileStream(backupFile.path);
        Archive? archive;
        try {
          archive = ZipDecoder().decodeStream(input);
          final chatsEntry = archive.findFile('chats.json');
          expect(chatsEntry, isNotNull);

          final data =
              jsonDecode(utf8.decode((chatsEntry!.readBytes() ?? <int>[])))
                  as Map<String, dynamic>;
          expect(data['version'], 1);
          final convs = data['conversations'] as List;
          final msgs = data['messages'] as List;
          final toolEvents = data['toolEvents'] as Map;

          expect(convs, hasLength(1));
          expect(convs[0]['id'], 'test-conv-1');
          expect(msgs, hasLength(1));
          expect(msgs[0]['id'], 'msg-recent');
          expect(toolEvents, isEmpty);
        } finally {
          archive?.clearSync();
          input.closeSync();
        }

        await DataSync.cleanupTemporaryBackupFile(backupFile);
        await chatService.close();
      },
    );

    test(
      'incremental: message-level filtering skips old conversation with no new messages',
      () async {
        final chatService = ChatService();
        await chatService.init();

        final oldDate = DateTime.now().subtract(const Duration(days: 60));
        final since = DateTime.now().subtract(const Duration(days: 30));

        final conv = Conversation(
          id: 'test-conv-2',
          title: 'Stale Conversation',
          createdAt: oldDate,
          updatedAt: oldDate,
          messageIds: ['msg-old-only'],
        );
        final oldMsg = ChatMessage(
          id: 'msg-old-only',
          role: 'user',
          content: 'old message',
          timestamp: oldDate,
          conversationId: conv.id,
          isStreaming: false,
        );
        await chatService.restoreConversation(conv, [oldMsg]);

        final sync = DataSync(chatService: chatService);
        final backupFile = await sync.prepareBackupFile(
          const WebDavConfig(includeChats: true, includeFiles: false),
          incremental: IncrementalBackupConfig(
            since: since,
            includeSettings: false,
            includeFiles: false,
          ),
        );

        final input = InputFileStream(backupFile.path);
        Archive? archive;
        try {
          archive = ZipDecoder().decodeStream(input);
          final chatsEntry = archive.findFile('chats.json');
          expect(chatsEntry, isNotNull);

          final data =
              jsonDecode(utf8.decode(chatsEntry!.readBytes() ?? <int>[]))
                  as Map<String, dynamic>;
          expect(data['version'], 1);
          final convs = data['conversations'] as List;
          final msgs = data['messages'] as List;

          expect(convs, isEmpty);
          expect(msgs, isEmpty);
        } finally {
          archive?.clearSync();
          input.closeSync();
        }

        await DataSync.cleanupTemporaryBackupFile(backupFile);
        await chatService.close();
      },
    );

    test(
      'incremental: edit-only activity exports the conversation with its full version chain',
      () async {
        final chatService = ChatService();
        await chatService.init();

        final oldDate = DateTime.now().subtract(const Duration(days: 60));
        final since = DateTime.now().subtract(const Duration(days: 30));
        const gid = 'test-group-1';

        final conv = Conversation(
          id: 'test-conv-3',
          title: 'Edited Conversation',
          createdAt: oldDate,
          updatedAt: DateTime.now(),
          messageIds: ['msg-v0', 'msg-v1'],
          versionSelections: {gid: 1},
        );
        final v0 = ChatMessage(
          id: 'msg-v0',
          role: 'assistant',
          content: 'original answer',
          timestamp: oldDate,
          conversationId: conv.id,
          isStreaming: false,
          groupId: gid,
          version: 0,
        );
        final v1 = ChatMessage(
          id: 'msg-v1',
          role: 'assistant',
          content: 'edited answer',
          // Edited versions preserve the ORIGINAL timestamp.
          timestamp: oldDate,
          conversationId: conv.id,
          isStreaming: false,
          groupId: gid,
          version: 1,
        );
        await chatService.restoreConversation(conv, [v0, v1]);

        final sync = DataSync(chatService: chatService);
        final backupFile = await sync.prepareBackupFile(
          const WebDavConfig(includeChats: true, includeFiles: false),
          incremental: IncrementalBackupConfig(
            since: since,
            includeSettings: false,
            includeFiles: false,
          ),
        );

        final input = InputFileStream(backupFile.path);
        Archive? archive;
        try {
          archive = ZipDecoder().decodeStream(input);
          final chatsEntry = archive.findFile('chats.json');
          expect(chatsEntry, isNotNull);

          final data =
              jsonDecode(utf8.decode(chatsEntry!.readBytes() ?? <int>[]))
                  as Map<String, dynamic>;
          final convs = data['conversations'] as List;
          final msgs = data['messages'] as List;

          expect(convs, hasLength(1));
          expect(convs[0]['id'], 'test-conv-3');
          expect((convs[0]['versionSelections'] as Map)[gid], 1);
          expect(msgs, hasLength(2));
          expect(msgs.map((m) => m['id']), containsAll(['msg-v0', 'msg-v1']));
        } finally {
          archive?.clearSync();
          input.closeSync();
        }

        await DataSync.cleanupTemporaryBackupFile(backupFile);
        await chatService.close();
      },
    );

    test(
      'incremental: version groups export atomically when the selected version is the original',
      () async {
        final chatService = ChatService();
        await chatService.init();

        final oldDate = DateTime.now().subtract(const Duration(days: 60));
        final since = DateTime.now().subtract(const Duration(days: 30));
        const gid = 'test-group-2';

        final conv = Conversation(
          id: 'test-conv-4',
          title: 'Reverted Conversation',
          createdAt: oldDate,
          updatedAt: DateTime.now(),
          messageIds: ['msg-rv0', 'msg-rv1'],
          // User edited to v1 but switched the selection back to v0.
          versionSelections: {gid: 0},
        );
        final v0 = ChatMessage(
          id: 'msg-rv0',
          role: 'user',
          content: 'original prompt',
          timestamp: oldDate,
          conversationId: conv.id,
          isStreaming: false,
          groupId: gid,
          version: 0,
        );
        final v1 = ChatMessage(
          id: 'msg-rv1',
          role: 'user',
          content: 'edited prompt',
          timestamp: oldDate,
          conversationId: conv.id,
          isStreaming: false,
          groupId: gid,
          version: 1,
        );
        await chatService.restoreConversation(conv, [v0, v1]);

        final sync = DataSync(chatService: chatService);
        final backupFile = await sync.prepareBackupFile(
          const WebDavConfig(includeChats: true, includeFiles: false),
          incremental: IncrementalBackupConfig(
            since: since,
            includeSettings: false,
            includeFiles: false,
          ),
        );

        final input = InputFileStream(backupFile.path);
        Archive? archive;
        try {
          archive = ZipDecoder().decodeStream(input);
          final chatsEntry = archive.findFile('chats.json');
          expect(chatsEntry, isNotNull);

          final data =
              jsonDecode(utf8.decode(chatsEntry!.readBytes() ?? <int>[]))
                  as Map<String, dynamic>;
          final convs = data['conversations'] as List;
          final msgs = data['messages'] as List;

          expect(convs, hasLength(1));
          expect(msgs, hasLength(2));
          expect(msgs.map((m) => m['id']), containsAll(['msg-rv0', 'msg-rv1']));
        } finally {
          archive?.clearSync();
          input.closeSync();
        }

        await DataSync.cleanupTemporaryBackupFile(backupFile);
        await chatService.close();
      },
    );

    test(
      'incremental: analyzeIncrementalScope returns correct counts',
      () async {
        final chatService = ChatService();
        await chatService.init();

        final since = DateTime.now().subtract(const Duration(days: 30));
        final oldDate = DateTime.now().subtract(const Duration(days: 60));
        final recentDate = DateTime.now().subtract(const Duration(days: 1));

        // New conversation (created after since)
        final newConv = Conversation(
          id: 'new-conv',
          title: 'New Chat',
          createdAt: since.add(const Duration(hours: 1)),
          updatedAt: since.add(const Duration(hours: 1)),
          messageIds: ['msg-n1', 'msg-n2'],
        );
        await chatService.restoreConversation(newConv, [
          ChatMessage(
            id: 'msg-n1',
            role: 'user',
            content: 'hello',
            timestamp: since.add(const Duration(hours: 1)),
            conversationId: newConv.id,
            isStreaming: false,
          ),
          ChatMessage(
            id: 'msg-n2',
            role: 'assistant',
            content: 'hi',
            timestamp: since.add(const Duration(hours: 2)),
            conversationId: newConv.id,
            isStreaming: false,
          ),
        ]);

        // Old conversation with new message
        final oldConv = Conversation(
          id: 'old-conv',
          title: 'Old Chat',
          createdAt: oldDate,
          updatedAt: recentDate,
          messageIds: ['msg-o1', 'msg-o2'],
        );
        await chatService.restoreConversation(oldConv, [
          ChatMessage(
            id: 'msg-o1',
            role: 'user',
            content: 'old msg',
            timestamp: oldDate,
            conversationId: oldConv.id,
            isStreaming: false,
          ),
          ChatMessage(
            id: 'msg-o2',
            role: 'user',
            content: 'recent msg',
            timestamp: recentDate,
            conversationId: oldConv.id,
            isStreaming: false,
          ),
        ]);

        // Stale conversation (no new messages)
        final staleConv = Conversation(
          id: 'stale-conv',
          title: 'Stale Chat',
          createdAt: oldDate,
          updatedAt: oldDate,
          messageIds: ['msg-s1'],
        );
        await chatService.restoreConversation(staleConv, [
          ChatMessage(
            id: 'msg-s1',
            role: 'user',
            content: 'stale',
            timestamp: oldDate,
            conversationId: staleConv.id,
            isStreaming: false,
          ),
        ]);

        final sync = DataSync(chatService: chatService);
        final scope = await sync.analyzeIncrementalScope(
          IncrementalBackupConfig(since: since, includeFiles: false),
        );

        expect(scope.newConversations.count, 1);
        expect(scope.newConversations.messageCount, 2);
        expect(scope.newConversations.oldestTitle, 'New Chat');
        expect(scope.updatedConversations.count, 1);
        expect(scope.updatedConversations.messageCount, 1);
        expect(scope.updatedConversations.oldestTitle, 'Old Chat');
        expect(scope.newFileCount, 0);

        await chatService.close();
      },
    );

    test(
      'incremental: analyzeIncrementalScope counts edit-only activity as whole version groups',
      () async {
        final chatService = ChatService();
        await chatService.init();

        final since = DateTime.now().subtract(const Duration(days: 30));
        final oldDate = DateTime.now().subtract(const Duration(days: 60));
        const gid = 'scope-group-1';

        // Edit-only conversation: all message timestamps predate since, but
        // updatedAt is fresh and a version was appended.
        final conv = Conversation(
          id: 'scope-conv',
          title: 'Edit Only',
          createdAt: oldDate,
          updatedAt: DateTime.now(),
          messageIds: ['scope-v0', 'scope-v1'],
          versionSelections: {gid: 1},
        );
        await chatService.restoreConversation(conv, [
          ChatMessage(
            id: 'scope-v0',
            role: 'assistant',
            content: 'original',
            timestamp: oldDate,
            conversationId: conv.id,
            isStreaming: false,
            groupId: gid,
            version: 0,
          ),
          ChatMessage(
            id: 'scope-v1',
            role: 'assistant',
            content: 'edited',
            timestamp: oldDate,
            conversationId: conv.id,
            isStreaming: false,
            groupId: gid,
            version: 1,
          ),
        ]);

        final sync = DataSync(chatService: chatService);
        final scope = await sync.analyzeIncrementalScope(
          IncrementalBackupConfig(since: since, includeFiles: false),
        );

        expect(scope.newConversations.count, 0);
        expect(scope.updatedConversations.count, 1);
        expect(scope.updatedConversations.oldestTitle, 'Edit Only');
        // Whole version group counts, matching the atomic export.
        expect(scope.updatedConversations.messageCount, 2);

        await chatService.close();
      },
    );
  });

  group('DataSync legacy OCR restore', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('kelivo_ocr_restore_');
      PathProviderPlatform.instance = _FakePathProviderPlatform(root.path);
      SharedPreferences.setMockInitialValues({});
    });

    tearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    Future<File> makeSettingsZip(Map<String, dynamic> settings) async {
      final settingsFile = File('${root.path}/settings.json');
      await settingsFile.writeAsString(jsonEncode(settings));
      final zipFile = File('${root.path}/backup.zip');
      final encoder = ZipFileEncoder();
      encoder.create(zipFile.path);
      encoder.addFileSync(settingsFile, 'settings.json');
      encoder.closeSync();
      return zipFile;
    }

    test(
      'pre-v15 backup with ocr_enabled_v1=false restores assistants to never '
      'and never resurrects the key',
      () async {
        final chatService = _InMemoryChatService();
        addTearDown(chatService.closeDb);
        final zipFile = await makeSettingsZip({
          'assistants_v1': jsonEncode([
            {'id': 'a1', 'name': 'Legacy A'},
            {'id': 'a2', 'name': 'Legacy B'},
          ]),
          'ocr_enabled_v1': false,
        });

        final sync = DataSync(chatService: chatService);
        await sync.restoreFromLocalFile(
          zipFile,
          const WebDavConfig(includeChats: false, includeFiles: false),
          mode: RestoreMode.overwrite,
        );

        final assistants = await chatService.getAllAssistants();
        expect(assistants, hasLength(2));
        expect(assistants.every((a) => a.ocrMode == 'never'), isTrue);

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.containsKey('ocr_enabled_v1'), isFalse);
      },
    );

    test(
      'pre-v15 backup with ocr_enabled_v1=true restores assistants to auto',
      () async {
        final chatService = _InMemoryChatService();
        addTearDown(chatService.closeDb);
        final zipFile = await makeSettingsZip({
          'assistants_v1': jsonEncode([
            {'id': 'a1', 'name': 'Legacy A'},
          ]),
          'ocr_enabled_v1': true,
        });

        final sync = DataSync(chatService: chatService);
        await sync.restoreFromLocalFile(
          zipFile,
          const WebDavConfig(includeChats: false, includeFiles: false),
          mode: RestoreMode.overwrite,
        );

        final assistants = await chatService.getAllAssistants();
        expect(assistants.single.ocrMode, 'auto');
      },
    );

    test('merge restore keeps existing per-assistant ocrMode and maps only new '
        'incoming assistants', () async {
      final chatService = _InMemoryChatService();
      addTearDown(chatService.closeDb);
      await chatService.putAssistants([
        Assistant(id: 'a1', name: 'Local Alpha', ocrMode: 'always'),
      ]);
      final zipFile = await makeSettingsZip({
        'assistants_v1': jsonEncode([
          {'id': 'a1', 'name': 'Incoming Alpha'},
          {'id': 'a2', 'name': 'New Beta'},
        ]),
        'ocr_enabled_v1': false,
      });

      final sync = DataSync(chatService: chatService);
      await sync.restoreFromLocalFile(
        zipFile,
        const WebDavConfig(includeChats: false, includeFiles: false),
        mode: RestoreMode.merge,
      );

      final byId = {
        for (final a in await chatService.getAllAssistants()) a.id: a,
      };
      expect(byId['a1']!.ocrMode, 'always');
      expect(byId['a2']!.ocrMode, 'never');
    });

    test(
      'v15-format backup preserves per-assistant ocrMode untouched',
      () async {
        final chatService = _InMemoryChatService();
        addTearDown(chatService.closeDb);
        final zipFile = await makeSettingsZip({
          'assistants_v1': jsonEncode([
            {'id': 'a1', 'name': 'Modern A', 'ocrMode': 'always'},
            {'id': 'a2', 'name': 'Modern B', 'ocrMode': 'never'},
          ]),
        });

        final sync = DataSync(chatService: chatService);
        await sync.restoreFromLocalFile(
          zipFile,
          const WebDavConfig(includeChats: false, includeFiles: false),
          mode: RestoreMode.overwrite,
        );

        final byId = {
          for (final a in await chatService.getAllAssistants()) a.id: a,
        };
        expect(byId['a1']!.ocrMode, 'always');
        expect(byId['a2']!.ocrMode, 'never');
      },
    );

    test(
      'overwrite restore keeps assistants when a later file-copy step fails',
      () async {
        // Real initialized service: the chats restore path self-initializes
        // (restoreConversationsBatch → init), which opens a real SQLite file
        // under the fake app-data dir. Using an in-memory fake here would
        // leave that file handle open and break the teardown delete.
        final chatService = ChatService();
        await chatService.init();
        addTearDown(chatService.close);

        // Occupy root/fonts with a FILE: the files-restore step's
        // Directory.create then throws (EEXIST) mid-restore. The restore
        // must log-and-continue instead of losing the assistants that were
        // already committed before the file copying (issue #475).
        final fontsBlocker = File('${root.path}/fonts');
        await fontsBlocker.writeAsString('blocker');

        final zipFile = File('${root.path}/full-with-files.zip');
        final encoder = ZipFileEncoder();
        encoder.create(zipFile.path);
        final settingsFile = File('${root.path}/settings.json');
        await settingsFile.writeAsString(
          jsonEncode({
            'assistants_v1': jsonEncode([
              {'id': 'a1', 'name': 'Alpha'},
              {'id': 'a2', 'name': 'Beta'},
            ]),
          }),
        );
        encoder.addFileSync(settingsFile, 'settings.json');
        final conv = Conversation(
          id: 'c1',
          title: 'Chat 1',
          createdAt: DateTime(2025, 1, 1),
          updatedAt: DateTime(2025, 1, 2),
          messageIds: const ['m1'],
        );
        final msg = ChatMessage(
          id: 'm1',
          role: 'user',
          content: 'hello',
          conversationId: 'c1',
          timestamp: DateTime(2025, 1, 2),
          isStreaming: false,
        );
        final chatsFile = File('${root.path}/chats.json');
        await chatsFile.writeAsString(
          jsonEncode({
            'version': 2,
            'conversations': [conv.toJson()],
            'messages': [msg.toJson()],
            'toolEvents': <String, dynamic>{},
            'geminiThoughtSigs': <String, dynamic>{},
            'groupChats': <dynamic>[],
            'groupMembers': <dynamic>[],
          }),
        );
        encoder.addFileSync(chatsFile, 'chats.json');
        final fontEntry = File('${root.path}/font.ttf');
        await fontEntry.writeAsBytes(List<int>.filled(64, 7));
        encoder.addFileSync(fontEntry, 'fonts/font.ttf');
        encoder.closeSync();

        final sync = DataSync(chatService: chatService);
        await sync.restoreFromLocalFile(
          zipFile,
          const WebDavConfig(includeChats: true, includeFiles: true),
          mode: RestoreMode.overwrite,
        );

        final assistants = await chatService.getAllAssistants();
        expect(assistants, hasLength(2));
        expect(assistants.map((a) => a.id), containsAll(['a1', 'a2']));
        expect(chatService.getAllCompleteConversations(), hasLength(1));
      },
    );

    test(
      'Kelivo v2 backup (manifest.json) throws typed exception before any write',
      () async {
        final chatService = _InMemoryChatService();
        addTearDown(chatService.closeDb);

        final zipFile = File('${root.path}/kelivo-v2.zip');
        final encoder = ZipFileEncoder();
        encoder.create(zipFile.path);
        final manifestFile = File('${root.path}/manifest.json');
        await manifestFile.writeAsString(
          jsonEncode({
            'format': 'kelivo-backup',
            'formatVersion': 2,
            'payloadKind': 'sqlite',
          }),
        );
        encoder.addFileSync(manifestFile, 'manifest.json');
        encoder.closeSync();

        final sync = DataSync(chatService: chatService);
        await expectLater(
          sync.restoreFromLocalFile(
            zipFile,
            const WebDavConfig(includeChats: true, includeFiles: true),
            mode: RestoreMode.overwrite,
          ),
          throwsA(isA<KelivoV2BackupException>()),
        );

        // No side effects: prefs untouched, DB untouched.
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.containsKey('assistants_v1'), isFalse);
        expect(await chatService.getAllAssistants(), isEmpty);
        expect(chatService.getAllCompleteConversations(), isEmpty);
      },
    );
  });

  group('DataSync Kelivo image-settings interop', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('kelivo_imgset_');
      PathProviderPlatform.instance = _FakePathProviderPlatform(root.path);
      SharedPreferences.setMockInitialValues({});
    });

    tearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    Future<File> makeSettingsZip(Map<String, dynamic> settings) async {
      final settingsFile = File('${root.path}/settings.json');
      await settingsFile.writeAsString(jsonEncode(settings));
      final zipFile = File('${root.path}/backup.zip');
      final encoder = ZipFileEncoder();
      encoder.create(zipFile.path);
      encoder.addFileSync(settingsFile, 'settings.json');
      encoder.closeSync();
      return zipFile;
    }

    test(
      'Kelivo zip overwrite translates upstream keys and strips them from prefs',
      () async {
        final sync = DataSync(chatService: ChatService());
        final zipFile = await makeSettingsZip({
          'image_upload_quality_v1': 'saver',
          'image_compress_transparent_enabled_v1': true,
        });

        await sync.restoreFromLocalFile(
          zipFile,
          const WebDavConfig(includeChats: false, includeFiles: false),
          mode: RestoreMode.overwrite,
        );

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool('one_click_compress_enabled_v1'), isTrue);
        expect(prefs.getInt('one_click_compress_max_long_edge_v1'), 1024);
        expect(prefs.getInt('one_click_compress_quality_v1'), 70);
        expect(prefs.getBool('one_click_compress_always_jpg_v1'), isTrue);
        expect(prefs.containsKey('image_upload_quality_v1'), isFalse);
        expect(prefs.containsKey('image_compress_custom_quality_v1'), isFalse);
        expect(
          prefs.containsKey('image_compress_transparent_enabled_v1'),
          isFalse,
        );
      },
    );

    test(
      'Kelivo zip overwrite with unknown enum falls back to balanced',
      () async {
        final sync = DataSync(chatService: ChatService());
        final zipFile = await makeSettingsZip({
          'image_upload_quality_v1': 'future-quality-mode',
        });

        await sync.restoreFromLocalFile(
          zipFile,
          const WebDavConfig(includeChats: false, includeFiles: false),
          mode: RestoreMode.overwrite,
        );

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool('one_click_compress_enabled_v1'), isTrue);
        expect(prefs.getInt('one_click_compress_max_long_edge_v1'), 1568);
        expect(prefs.getInt('one_click_compress_quality_v1'), 85);
      },
    );

    test('Kelivo zip merge keeps existing local one_click_* values', () async {
      SharedPreferences.setMockInitialValues({
        'one_click_compress_enabled_v1': true,
        'one_click_compress_max_long_edge_v1': 2048,
        'one_click_compress_quality_v1': 90,
        'one_click_compress_always_jpg_v1': false,
      });
      final sync = DataSync(chatService: ChatService());
      final zipFile = await makeSettingsZip({
        'image_upload_quality_v1': 'saver',
      });

      await sync.restoreFromLocalFile(
        zipFile,
        const WebDavConfig(includeChats: false, includeFiles: false),
        mode: RestoreMode.merge,
      );

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('one_click_compress_enabled_v1'), isTrue);
      expect(prefs.getInt('one_click_compress_max_long_edge_v1'), 2048);
      expect(prefs.getInt('one_click_compress_quality_v1'), 90);
      expect(prefs.containsKey('image_upload_quality_v1'), isFalse);
    });

    test(
      'Cuplivo-style zip (both key sets) restores its own long edge verbatim',
      () async {
        // A Cuplivo export carries BOTH key sets. The import must NOT
        // re-translate it: the file's own maxLongEdge (2048) wins over the
        // upstream-pinned 1568.
        final sync = DataSync(chatService: ChatService());
        final zipFile = await makeSettingsZip({
          'image_upload_quality_v1': 'custom',
          'image_compress_custom_quality_v1': 90,
          'one_click_compress_enabled_v1': true,
          'one_click_compress_max_long_edge_v1': 2048,
          'one_click_compress_quality_v1': 90,
          'one_click_compress_always_jpg_v1': false,
        });

        await sync.restoreFromLocalFile(
          zipFile,
          const WebDavConfig(includeChats: false, includeFiles: false),
          mode: RestoreMode.overwrite,
        );

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getInt('one_click_compress_max_long_edge_v1'), 2048);
        expect(prefs.getInt('one_click_compress_quality_v1'), 90);
        expect(prefs.containsKey('image_upload_quality_v1'), isFalse);
      },
    );

    test(
      'export derives upstream keys from current one_click_* values',
      () async {
        SharedPreferences.setMockInitialValues({
          'one_click_compress_enabled_v1': true,
          'one_click_compress_max_long_edge_v1': 1536,
          'one_click_compress_quality_v1': 75,
          'one_click_compress_always_jpg_v1': false,
        });
        final sync = DataSync(chatService: ChatService());
        final backupFile = await sync.prepareBackupFile(
          WebDavConfig(includeChats: false, includeFiles: false),
        );

        final input = InputFileStream(backupFile.path);
        Archive? archive;
        try {
          archive = ZipDecoder().decodeStream(input);
          final settingsEntry = archive.findFile('settings.json');
          expect(settingsEntry, isNotNull);
          final settings =
              jsonDecode(utf8.decode(settingsEntry!.readBytes()!))
                  as Map<String, dynamic>;
          expect(settings['image_upload_quality_v1'], 'custom');
          expect(settings['image_compress_custom_quality_v1'], 75);
          expect(settings['image_compress_transparent_enabled_v1'], false);
        } finally {
          archive?.clearSync();
          input.closeSync();
        }

        await DataSync.cleanupTemporaryBackupFile(backupFile);
      },
    );

    test('export of a disabled config emits original', () async {
      SharedPreferences.setMockInitialValues({
        'one_click_compress_enabled_v1': false,
        'one_click_compress_quality_v1': 95,
      });
      final sync = DataSync(chatService: ChatService());
      final backupFile = await sync.prepareBackupFile(
        WebDavConfig(includeChats: false, includeFiles: false),
      );

      final input = InputFileStream(backupFile.path);
      Archive? archive;
      try {
        archive = ZipDecoder().decodeStream(input);
        final settings =
            jsonDecode(
                  utf8.decode(archive.findFile('settings.json')!.readBytes()!),
                )
                as Map<String, dynamic>;
        expect(settings['image_upload_quality_v1'], 'original');
      } finally {
        archive?.clearSync();
        input.closeSync();
      }

      await DataSync.cleanupTemporaryBackupFile(backupFile);
    });

    test(
      'export converts search_services_v1 apiKeys to Kelivo string list',
      () async {
        SharedPreferences.setMockInitialValues({
          'search_services_v1': jsonEncode([
            {
              'type': 'tavily',
              'id': 'tavily-1',
              'url': 'https://api.tavily.com/search',
              'apiKey': 'primary-key',
              'apiKeys': [
                {
                  'id': 'k1',
                  'key': 'primary-key',
                  'isEnabled': true,
                  'priority': 5,
                },
                {
                  'id': 'k2',
                  'key': 'backup-key',
                  'isEnabled': true,
                  'priority': 6,
                },
              ],
            },
          ]),
        });
        final sync = DataSync(chatService: ChatService());
        final backupFile = await sync.prepareBackupFile(
          WebDavConfig(includeChats: false, includeFiles: false),
        );

        final input = InputFileStream(backupFile.path);
        Archive? archive;
        try {
          archive = ZipDecoder().decodeStream(input);
          final settings =
              jsonDecode(
                    utf8.decode(
                      archive.findFile('settings.json')!.readBytes()!,
                    ),
                  )
                  as Map<String, dynamic>;
          final services =
              jsonDecode(settings['search_services_v1'] as String) as List;
          final service = services.single as Map<String, dynamic>;
          expect(service['type'], 'tavily');
          expect(service['apiKey'], 'primary-key');
          expect(service['apiKeys'], ['primary-key', 'backup-key']);
          expect(service['keyConfigs'], isA<List>());
          expect(service['keyConfigs'], hasLength(2));
        } finally {
          archive?.clearSync();
          input.closeSync();
        }

        await DataSync.cleanupTemporaryBackupFile(backupFile);
      },
    );

    test('round-trip restores full keyConfigs for search services', () async {
      SharedPreferences.setMockInitialValues({
        'search_services_v1': jsonEncode([
          {
            'type': 'tavily',
            'id': 'tavily-1',
            'url': 'https://api.tavily.com/search',
            'apiKey': 'primary-key',
            'apiKeys': [
              {
                'id': 'k1',
                'key': 'primary-key',
                'isEnabled': true,
                'priority': 5,
              },
              {
                'id': 'k2',
                'key': 'backup-key',
                'isEnabled': true,
                'priority': 6,
              },
            ],
          },
        ]),
      });
      final sync = DataSync(chatService: ChatService());
      final backupFile = await sync.prepareBackupFile(
        WebDavConfig(includeChats: false, includeFiles: false),
      );

      final input = InputFileStream(backupFile.path);
      Archive? archive;
      try {
        archive = ZipDecoder().decodeStream(input);
        final settings =
            jsonDecode(
                  utf8.decode(archive.findFile('settings.json')!.readBytes()!),
                )
                as Map<String, dynamic>;
        final services =
            jsonDecode(settings['search_services_v1'] as String) as List;
        final service = services.single as Map<String, dynamic>;

        final restored = SearchServiceOptions.fromJson(service);
        expect(restored.apiKeys, hasLength(2));
        expect(restored.apiKeys.first.key, 'primary-key');
        expect(restored.apiKeys.last.key, 'backup-key');
        expect(restored.apiKeys.last.isEnabled, isTrue);
      } finally {
        archive?.clearSync();
        input.closeSync();
      }

      await DataSync.cleanupTemporaryBackupFile(backupFile);
    });
  });
}
