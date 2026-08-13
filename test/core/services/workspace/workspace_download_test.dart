import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/services/mcp/kelivo_filesystem/kelivo_filesystem_server.dart';
import 'package:Cuplivo/core/services/fetch/web_fetch_target_guard.dart';
import 'package:Cuplivo/core/services/workspace/workspace_download_service.dart';

Future<Map<String, dynamic>> callTool(
  KelivoFilesystemMcpServerEngine engine,
  String name,
  Map<String, dynamic> args,
) async {
  final resp = await engine.handleMessage({
    'jsonrpc': '2.0',
    'id': 1,
    'method': 'tools/call',
    'params': {'name': name, 'arguments': args},
  });
  return (resp as Map)['result'] as Map<String, dynamic>;
}

String textOf(Map<String, dynamic> result) {
  final content = result['content'] as List;
  return (content.first as Map)['text'] as String;
}

void main() {
  group('Workspace download tool', () {
    late Directory root;
    late Directory wsDir;
    late Directory docsDir;
    late List<FilesystemMount> mounts;
    late KelivoFilesystemMcpServerEngine engine;
    late HttpServer httpServer;
    late Uri baseUri;

    setUp(() async {
      WebFetchTargetGuard.blockPrivateTargets = false;
      addTearDown(() => WebFetchTargetGuard.blockPrivateTargets = true);
      root = Directory.systemTemp.createTempSync('ws_download_test_');
      wsDir = Directory('${root.path}/ws')..createSync();
      docsDir = Directory('${root.path}/docs')..createSync();
      mounts = [
        FilesystemMount(alias: 'default', path: wsDir.path, readOnly: false),
        FilesystemMount(alias: 'docs', path: docsDir.path, readOnly: true),
      ];
      engine = KelivoFilesystemMcpServerEngine(mountsProvider: () => mounts);
      httpServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      baseUri = Uri.parse('http://127.0.0.1:${httpServer.port}');
      httpServer.listen((request) async {
        if (request.uri.path == '/download.txt') {
          request.response.headers.contentType = ContentType.text;
          request.response.write('raw payload as-is');
        } else if (request.uri.path == '/gzipped.txt') {
          final compressed = gzip.encode(utf8.encode('gzipped payload'));
          request.response.headers.contentType = ContentType.text;
          request.response.headers.add('Content-Encoding', 'gzip');
          request.response.add(compressed);
        } else if (request.uri.path == '/stall') {
          request.response.headers.contentType = ContentType.text;
          request.response.write('first-chunk');
          await request.response.flush();
          await Future<void>.delayed(const Duration(seconds: 1));
        } else {
          request.response.headers.contentType = ContentType.binary;
          request.response.add(utf8.encode('BIN\u0000DATA'));
        }
        await request.response.close();
      });
    });

    tearDown(() async {
      await httpServer.close(force: true);
      engine.close();
      WorkspaceDownloadService.cacheBudgetBytes = 512 * 1024 * 1024;
      WorkspaceDownloadService.cacheTtl = const Duration(days: 7);
      WorkspaceDownloadService.partGracePeriod = const Duration(hours: 1);
      WorkspaceDownloadService.downloadChunkTimeout = const Duration(
        minutes: 1,
      );
      WorkspaceDownloadService.downloadResponseTimeout = const Duration(
        seconds: 30,
      );
      try {
        root.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('saves text bytes as-is and returns a confirmation', () async {
      final r = await callTool(engine, 'download', {
        'url': baseUri.resolve('/download.txt').toString(),
        'path': '@default/notes/sample.txt',
      });

      expect(r['isError'], false);
      final text = textOf(r);
      expect(text, contains('@default/notes/sample.txt'));
      expect(text, contains('17 bytes'));

      final file = File('${wsDir.path}/notes/sample.txt');
      expect(await file.exists(), isTrue);
      expect(await file.readAsString(), 'raw payload as-is');
    });

    test('saves binary bytes as-is', () async {
      final r = await callTool(engine, 'download', {
        'url': baseUri.resolve('/download.bin').toString(),
        'path': '@default/payload.bin',
      });

      expect(r['isError'], false);
      final file = File('${wsDir.path}/payload.bin');
      expect(await file.exists(), isTrue);
      expect(await file.readAsBytes(), utf8.encode('BIN\u0000DATA'));
    });

    test('saves the exact wire bytes when gzip content-encoded', () async {
      final expected = gzip.encode(utf8.encode('gzipped payload'));
      final r = await callTool(engine, 'download', {
        'url': baseUri.resolve('/gzipped.txt').toString(),
        'path': '@default/gz.txt',
      });

      expect(r['isError'], false);
      expect(textOf(r), contains('${expected.length} bytes'));
      final file = File('${wsDir.path}/gz.txt');
      expect(await file.readAsBytes(), expected);
    });

    test('rejects an invalid URL', () async {
      final r = await callTool(engine, 'download', {
        'url': 'ftp://example.com/file',
        'path': '@default/x.bin',
      });

      expect(r['isError'], true);
      expect(textOf(r), contains('Invalid url'));
    });

    test('rejects a mount root as the target', () async {
      final r = await callTool(engine, 'download', {
        'url': baseUri.resolve('/download.txt').toString(),
        'path': '@default',
      });

      expect(r['isError'], true);
      expect(textOf(r), contains('full file path'));
    });

    test('rejects a directory at the target path', () async {
      final dir = Directory('${wsDir.path}/notes');
      await dir.create(recursive: true);

      final r = await callTool(engine, 'download', {
        'url': baseUri.resolve('/download.txt').toString(),
        'path': '@default/notes',
      });

      expect(r['isError'], true);
      expect(textOf(r), contains('directory already exists'));
      expect(await dir.exists(), isTrue);
    });

    test('fails on a read-only mount', () async {
      final r = await callTool(engine, 'download', {
        'url': baseUri.resolve('/download.txt').toString(),
        'path': '@docs/sample.txt',
      });

      expect(r['isError'], true);
      expect(textOf(r), contains('read-only'));
    });

    test('rejects a loopback target via the SSRF guard', () async {
      WebFetchTargetGuard.blockPrivateTargets = true;
      final r = await callTool(engine, 'download', {
        'url': baseUri.resolve('/download.txt').toString(),
        'path': '@default/sample.txt',
      });

      expect(r['isError'], true);
      expect(textOf(r), contains('not an allowed web_fetch target'));
    });

    test('a stalled download stream times out instead of hanging', () async {
      WebFetchTargetGuard.blockPrivateTargets = false;
      WorkspaceDownloadService.downloadChunkTimeout = const Duration(
        milliseconds: 200,
      );
      final r = await callTool(engine, 'download', {
        'url': baseUri.resolve('/stall').toString(),
        'path': '@default/stall.bin',
      });

      expect(r['isError'], true);
      expect(textOf(r), contains('TimeoutException'));
    });

    test('downloads also run eviction: stale .part files age out', () async {
      final cacheDir = Directory('${wsDir.path}/.fetch_cache');
      await cacheDir.create(recursive: true);
      final stalePart = File('${cacheDir.path}/old.part');
      await stalePart.writeAsString('crashed download');
      await stalePart.setLastModified(
        DateTime.now().subtract(const Duration(days: 8)),
      );

      final r = await callTool(engine, 'download', {
        'url': baseUri.resolve('/download.txt').toString(),
        'path': '@default/sample.txt',
      });

      expect(r['isError'], false);
      expect(await stalePart.exists(), isFalse);
    });

    test('budget eviction never deletes fresh in-flight .part files', () async {
      final cacheDir = Directory('${wsDir.path}/.fetch_cache');
      await cacheDir.create(recursive: true);
      final oldFile = File('${cacheDir.path}/old.txt');
      await oldFile.writeAsString(List.filled(30, 'a').join());
      await oldFile.setLastModified(
        DateTime.now().subtract(const Duration(days: 2)),
      );
      final inFlight = File('${cacheDir.path}/inflight.part');
      await inFlight.writeAsString(List.filled(30, 'b').join());

      WorkspaceDownloadService.cacheBudgetBytes = 50;
      final r = await callTool(engine, 'download', {
        'url': baseUri.resolve('/download.txt').toString(),
        'path': '@default/sample.txt',
      });

      expect(r['isError'], false);
      expect(await oldFile.exists(), isFalse); // budget trimmed the old file
      expect(await inFlight.exists(), isTrue); // fresh .part never evicted
    });

    test('download overwrites an existing target atomically', () async {
      final target = File('${wsDir.path}/overwrite.txt');
      await target.parent.create(recursive: true);
      await target.writeAsString('old');

      final r = await callTool(engine, 'download', {
        'url': baseUri.resolve('/download.txt').toString(),
        'path': '@default/overwrite.txt',
      });

      expect(r['isError'], false);
      expect(await target.readAsString(), 'raw payload as-is');
    });
  });
}
