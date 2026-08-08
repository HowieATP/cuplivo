import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_client/mcp_client.dart' as mcp;
import 'package:path/path.dart' as p;

import 'package:Cuplivo/core/services/mcp/kelivo_fetch/kelivo_fetch_server.dart';

void main() {
  group('Kelivo fetch MCP', () {
    late HttpServer httpServer;
    late KelivoFetchMcpServerEngine engine;
    late Uri baseUri;
    late Directory wsDir;

    setUp(() async {
      httpServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      baseUri = Uri.parse('http://127.0.0.1:${httpServer.port}');
      wsDir = await Directory.systemTemp.createTemp('kelivo_fetch_test');
      engine = KelivoFetchMcpServerEngine(
        workspacesDirProvider: () async => wsDir,
      );
      httpServer.listen((request) async {
        if (request.uri.path == '/json') {
          request.response.headers.contentType = ContentType.json;
          request.response.write('''
{
  "items": [
    1,
    2
  ]
}
''');
        } else if (request.uri.path == '/unicode') {
          request.response.headers.contentType = ContentType.text;
          request.response.write('😀abc');
        } else if (request.uri.path == '/download.txt') {
          request.response.headers.contentType = ContentType.text;
          request.response.write('raw payload as-is');
        } else if (request.uri.path == '/download.bin') {
          request.response.headers.contentType = ContentType.binary;
          request.response.add(utf8.encode('BIN\u0000DATA'));
        } else if (request.uri.path == '/gzipped.txt') {
          final compressed = gzip.encode(utf8.encode('gzipped payload'));
          request.response.headers.contentType = ContentType.text;
          request.response.headers.add('Content-Encoding', 'gzip');
          request.response.add(compressed);
        } else if (request.uri.path == '/no-charset.txt') {
          request.response.headers.contentType = ContentType.text;
          request.response.write('你好世界');
        } else if (request.uri.path == '/image.png') {
          request.response.headers.contentType = ContentType('image', 'png');
          request.response.write('PNGDATA-no-nul-bytes');
        } else if (request.uri.path == '/stall') {
          request.response.headers.contentType = ContentType.text;
          request.response.write('first-chunk');
          await request.response.flush();
          // Hold the response open past the client's 200 ms chunk timeout;
          // the parked future resumes after the test's tearDown force-closes
          // the server, which dart:io absorbs without an unhandled error.
          await Future<void>.delayed(const Duration(seconds: 1));
        } else if (request.uri.path == '/no-headers') {
          // Hold the request open WITHOUT writing: response headers are
          // never sent, so `client.send` parks until downloadResponseTimeout.
          // (A handler that returns immediately would get an auto-completed
          // empty 200 from dart:io, which the client would accept.)
          await Future<void>.delayed(const Duration(seconds: 1));
        } else if (request.uri.path == '/plain.txt') {
          request.response.headers.contentType = ContentType.text;
          request.response.write(List.filled(7000, 'z').join());
        } else {
          request.response.headers.contentType = ContentType.html;
          request.response.write('''
<!doctype html>
<html>
  <head><script>SCRIPT-NOISE-${List.filled(1000, 'x').join()}</script></head>
  <body>
    <nav>NAV-NOISE-${List.filled(1000, 'y').join()}</nav>
    <main><h1>Useful title</h1><p>${List.filled(6500, 'a').join()}</p></main>
    <footer>FOOTER-NOISE</footer>
  </body>
</html>
''');
        }
        await request.response.close();
      });
    });

    tearDown(() async {
      engine.close();
      await httpServer.close(force: true);
      if (await wsDir.exists()) {
        await wsDir.delete(recursive: true);
      }
      KelivoFetcher.cacheBudgetBytes = 512 * 1024 * 1024;
      KelivoFetcher.cacheTtl = const Duration(days: 7);
      KelivoFetcher.maxReadableTextBytes = 32 * 1024 * 1024;
      KelivoFetcher.downloadChunkTimeout = const Duration(minutes: 1);
      KelivoFetcher.downloadResponseTimeout = const Duration(seconds: 30);
      KelivoFetcher.textFetchTimeout = const Duration(seconds: 60);
      KelivoFetcher.partGracePeriod = const Duration(hours: 1);
    });

    test('advertises one compact, bounded fetch tool', () async {
      final response =
          await engine.handleMessage({
                'jsonrpc': '2.0',
                'id': 1,
                'method': 'tools/list',
              })
              as Map<String, dynamic>;

      final tools =
          (response['result'] as Map<String, dynamic>)['tools'] as List;
      expect(tools, hasLength(1));
      final tool = (tools.single as Map).cast<String, dynamic>();
      expect(tool['name'], 'kelivo_fetch');
      expect(tool['description'], contains('HTML is simplified'));
      expect(
        tool['description'],
        contains('already appears in the conversation'),
      );
      expect(tool['description'], contains('requires authentication'));
      expect(tool['description'], contains('download_path'));
      expect(tool['description'], contains('@workspaces/.fetch_cache/'));

      final schema = (tool['inputSchema'] as Map).cast<String, dynamic>();
      final properties = (schema['properties'] as Map).cast<String, dynamic>();
      expect(properties['url']['description'], contains('do not add www'));
      expect(
        properties['url']['description'],
        contains('https://example.com is valid'),
      );
      expect(properties['max_length'], {
        'type': 'integer',
        'description': 'Maximum content characters to return',
        'default': 5000,
        'minimum': 1,
        'maximum': 20000,
      });
      expect(properties['start_index'], containsPair('default', 0));
      expect(properties['raw'], containsPair('default', false));
      expect(
        properties['download_path']['description'],
        contains('full file path under @workspaces/'),
      );
      expect(
        properties['download_path']['description'],
        contains('not a directory'),
      );
    });

    test(
      'simplifies HTML and limits default output to 5000 characters',
      () async {
        final result = await _callFetch(engine, baseUri.resolve('/html'));
        final text = _resultText(result);

        expect(text, contains('Useful title'));
        expect(text, isNot(contains('SCRIPT-NOISE')));
        expect(text, isNot(contains('NAV-NOISE')));
        expect(text, isNot(contains('FOOTER-NOISE')));
        expect(text, contains('start_index=5000'));
        expect(text.split('\n\n[Content truncated').first, hasLength(5000));
      },
    );

    test('continues a truncated response from start_index', () async {
      final result = await _callFetch(
        engine,
        baseUri.resolve('/html'),
        arguments: const {'start_index': 5000},
      );
      final text = _resultText(result);

      expect(text, isNotEmpty);
      expect(text, isNot(contains('Content truncated')));
      expect(text, matches(RegExp(r'^a+$')));
    });

    test('requires raw opt-in and still bounds raw HTML', () async {
      final result = await _callFetch(
        engine,
        baseUri.resolve('/html'),
        arguments: const {'raw': true, 'max_length': 200},
      );
      final text = _resultText(result);

      expect(text, contains('<!doctype html>'));
      expect(text, contains('SCRIPT-NOISE'));
      expect(text.split('\n\n[Content truncated').first.length, 200);
    });

    test('compacts JSON before returning it', () async {
      final result = await _callFetch(engine, baseUri.resolve('/json'));

      expect(_resultText(result), '{"items":[1,2]}');
    });

    test('does not split Unicode surrogate pairs at a boundary', () async {
      final first = await _callFetch(
        engine,
        baseUri.resolve('/unicode'),
        arguments: const {'max_length': 1},
      );
      final continued = await _callFetch(
        engine,
        baseUri.resolve('/unicode'),
        arguments: const {'max_length': 3, 'start_index': 2},
      );

      expect(_resultText(first), startsWith('😀'));
      expect(_resultText(first), contains('start_index=2'));
      expect(_resultText(continued), 'abc');
    });

    test('rejects attempts to exceed the hard output limit', () async {
      final result = await _callFetch(
        engine,
        baseUri.resolve('/html'),
        arguments: const {'max_length': 20001},
      );

      expect(result['isError'], isTrue);
      expect(_resultText(result), contains('Invalid max_length'));
    });

    test(
      'download_path saves text bytes as-is and returns a confirmation',
      () async {
        final result = await _callFetch(
          engine,
          baseUri.resolve('/download.txt'),
          arguments: const {'download_path': '@workspaces/notes/sample.txt'},
        );
        final text = _resultText(result);

        expect(result['isError'], isFalse);
        expect(text, contains('@workspaces/notes/sample.txt'));
        expect(text, contains('17 bytes'));
        expect(text, isNot(contains('raw payload as-is')));

        final file = File(p.join(wsDir.path, 'notes', 'sample.txt'));
        expect(await file.exists(), isTrue);
        expect(await file.readAsString(), 'raw payload as-is');
      },
    );

    test('download_path saves binary bytes as-is', () async {
      final result = await _callFetch(
        engine,
        baseUri.resolve('/download.bin'),
        arguments: const {'download_path': '@workspaces/payload.bin'},
      );

      expect(result['isError'], isFalse);
      final file = File(p.join(wsDir.path, 'payload.bin'));
      expect(await file.exists(), isTrue);
      expect(await file.readAsBytes(), utf8.encode('BIN\u0000DATA'));
    });

    test('download_path silently overwrites an existing target', () async {
      final target = File(p.join(wsDir.path, 'overwrite.txt'));
      await target.parent.create(recursive: true);
      await target.writeAsString('old');

      final result = await _callFetch(
        engine,
        baseUri.resolve('/download.txt'),
        arguments: const {'download_path': '@workspaces/overwrite.txt'},
      );

      expect(result['isError'], isFalse);
      expect(await target.readAsString(), 'raw payload as-is');
    });

    test(
      'download_path ignores max_length/start_index/raw and notes it',
      () async {
        final result = await _callFetch(
          engine,
          baseUri.resolve('/download.txt'),
          arguments: const {
            'download_path': '@workspaces/notes/sample.txt',
            'max_length': 3,
            'start_index': 1,
            'raw': true,
          },
        );

        expect(result['isError'], isFalse);
        expect(
          _resultText(result),
          contains('max_length, start_index and raw'),
        );
        final file = File(p.join(wsDir.path, 'notes', 'sample.txt'));
        expect(await file.readAsString(), 'raw payload as-is');
      },
    );

    test('rejects invalid download_path values', () async {
      for (final bad in const [
        'notes/sample.txt', // no @workspaces prefix
        '@other/sample.txt', // external mount
        '@workspaces/', // directory, not a file
        '@workspaces/a/../b.txt', // traversal segment
        '@workspaces/a\\b.txt', // backslash
        '@workspaces/..', // all-dot segment (Win32 parent hazard)
        '@workspaces/.fetch_cache/x.bin', // reserved temp storage
        '@workspaces/.fetch_cache', // reserved temp storage root
        '@workspaces/.hidden/x.bin', // dot-prefixed segment
        '@workspaces/reports/.git/notes.md', // dot-prefixed segment (nested)
      ]) {
        final result = await _callFetch(
          engine,
          baseUri.resolve('/download.txt'),
          arguments: {'download_path': bad},
        );
        expect(result['isError'], isTrue, reason: 'should reject $bad');
        expect(_resultText(result), contains('Invalid download_path'));
      }
    });

    test('binary content without download_path errors with guidance', () async {
      final result = await _callFetch(engine, baseUri.resolve('/download.bin'));

      expect(result['isError'], isTrue);
      expect(_resultText(result), contains('Possible binary content detected'));
      expect(_resultText(result), contains('download_path'));
      expect(_fetchCacheFiles(wsDir), isEmpty);
    });

    test(
      'over-length content is saved to .fetch_cache with a path hint',
      () async {
        final result = await _callFetch(engine, baseUri.resolve('/html'));
        final text = _resultText(result);

        expect(text, contains('start_index=5000'));
        final match = RegExp(
          r'Full content \(\d+ characters\) saved to '
          r'(@workspaces/\.fetch_cache/\w+\.md)',
        ).firstMatch(text);
        expect(match, isNotNull);
        final wirePath = match!.group(1)!;

        final file = File(
          p.joinAll([
            wsDir.path,
            ...wirePath.substring('@workspaces/'.length).split('/'),
          ]),
        );
        expect(await file.exists(), isTrue);
        final saved = await file.readAsString();
        expect(saved, contains('Useful title'));
        expect(saved, isNot(contains('SCRIPT-NOISE')));
        expect(saved.length, greaterThan(5000));
      },
    );

    test('over-length raw content is saved as .txt', () async {
      final result = await _callFetch(
        engine,
        baseUri.resolve('/plain.txt'),
        arguments: const {'max_length': 100},
      );

      final text = _resultText(result);
      final match = RegExp(
        r'(@workspaces/\.fetch_cache/\w+\.txt)',
      ).firstMatch(text);
      expect(match, isNotNull);
      final file = File(
        p.joinAll([
          wsDir.path,
          ...match!.group(1)!.substring('@workspaces/'.length).split('/'),
        ]),
      );
      expect(await file.exists(), isTrue);
      expect((await file.readAsString()).length, 7000);
    });

    test('content within max_length is never saved', () async {
      final result = await _callFetch(
        engine,
        baseUri.resolve('/json'),
        arguments: const {'max_length': 5000},
      );

      expect(result['isError'], isFalse);
      expect(_resultText(result), isNot(contains('.fetch_cache')));
      expect(_fetchCacheFiles(wsDir), isEmpty);
    });

    test('continuation calls do not rewrite the cache entry', () async {
      await _callFetch(engine, baseUri.resolve('/html'));
      expect(_fetchCacheFiles(wsDir), hasLength(1));

      final continued = await _callFetch(
        engine,
        baseUri.resolve('/html'),
        arguments: const {'start_index': 5000},
      );
      expect(_resultText(continued), matches(RegExp(r'^a+$')));
      expect(_fetchCacheFiles(wsDir), hasLength(1));
    });

    test(
      'cache entries are deterministic and overwritten, not reused',
      () async {
        final first = await _callFetch(engine, baseUri.resolve('/html'));
        final second = await _callFetch(engine, baseUri.resolve('/html'));
        final firstPath = RegExp(
          r'(@workspaces/\.fetch_cache/\w+\.md)',
        ).firstMatch(_resultText(first))!.group(1)!;
        final secondPath = RegExp(
          r'(@workspaces/\.fetch_cache/\w+\.md)',
        ).firstMatch(_resultText(second))!.group(1)!;

        expect(secondPath, firstPath);
        expect(_fetchCacheFiles(wsDir), hasLength(1));
      },
    );

    test('eviction removes entries older than the TTL', () async {
      final cacheDir = Directory(p.join(wsDir.path, '.fetch_cache'));
      await cacheDir.create(recursive: true);
      final stale = File(p.join(cacheDir.path, 'stale.txt'));
      await stale.writeAsString('old');
      await stale.setLastModified(
        DateTime.now().subtract(const Duration(days: 8)),
      );

      await _callFetch(engine, baseUri.resolve('/html'));

      expect(await stale.exists(), isFalse);
      expect(_fetchCacheFiles(wsDir), hasLength(1));
    });

    test(
      'eviction trims the oldest entries to stay within the budget',
      () async {
        final cacheDir = Directory(p.join(wsDir.path, '.fetch_cache'));
        await cacheDir.create(recursive: true);
        final old1 = File(p.join(cacheDir.path, 'old1.txt'));
        await old1.writeAsString(List.filled(30, 'a').join());
        await old1.setLastModified(
          DateTime.now().subtract(const Duration(days: 1)),
        );
        final old2 = File(p.join(cacheDir.path, 'old2.txt'));
        await old2.writeAsString(List.filled(30, 'b').join());
        await old2.setLastModified(
          DateTime.now().subtract(const Duration(days: 2)),
        );

        KelivoFetcher.cacheBudgetBytes = 50;
        final result = await _callFetch(
          engine,
          baseUri.resolve('/unicode'),
          arguments: const {'max_length': 1},
        );

        expect(_resultText(result), contains('.fetch_cache'));
        final remaining = _fetchCacheFiles(wsDir);
        expect(remaining, hasLength(2));
        expect(await old2.exists(), isFalse); // oldest evicted first
        expect(await old1.exists(), isTrue); // newer old file kept
      },
    );

    test(
      'sandbox resolution failure degrades to text without a hint',
      () async {
        final failingEngine = KelivoFetchMcpServerEngine(
          workspacesDirProvider: () async =>
              throw const FileSystemException('sandbox unavailable'),
        );
        final result = await _callFetch(
          failingEngine,
          baseUri.resolve('/html'),
        );

        expect(result['isError'], isFalse);
        expect(_resultText(result), contains('start_index=5000'));
        expect(_resultText(result), isNot(contains('.fetch_cache')));
        failingEngine.close();
      },
    );

    test('download to an unavailable sandbox errors explicitly', () async {
      final failingEngine = KelivoFetchMcpServerEngine(
        workspacesDirProvider: () async =>
            throw const FileSystemException('sandbox unavailable'),
      );
      final result = await _callFetch(
        failingEngine,
        baseUri.resolve('/download.txt'),
        arguments: const {'download_path': '@workspaces/sample.txt'},
      );

      expect(result['isError'], isTrue);
      expect(_resultText(result), contains('sandbox'));
      failingEngine.close();
    });

    test(
      'download saves the exact wire bytes when gzip content-encoded',
      () async {
        final expected = gzip.encode(utf8.encode('gzipped payload'));
        final result = await _callFetch(
          engine,
          baseUri.resolve('/gzipped.txt'),
          arguments: const {'download_path': '@workspaces/gz.txt'},
        );

        expect(result['isError'], isFalse);
        expect(_resultText(result), contains('${expected.length} bytes'));
        final file = File(p.join(wsDir.path, 'gz.txt'));
        expect(await file.readAsBytes(), expected);
      },
    );

    test(
      'charset-less UTF-8 pages decode correctly instead of latin-1',
      () async {
        final result = await _callFetch(
          engine,
          baseUri.resolve('/no-charset.txt'),
        );

        expect(result['isError'], isFalse);
        expect(_resultText(result), '你好世界');
      },
    );

    test(
      'download mode ignores invalid max_length instead of erroring',
      () async {
        final result = await _callFetch(
          engine,
          baseUri.resolve('/download.txt'),
          arguments: const {
            'download_path': '@workspaces/sample.txt',
            'max_length': 20001,
            'start_index': -5,
            'raw': 'not-a-bool',
          },
        );

        expect(result['isError'], isFalse);
        final file = File(p.join(wsDir.path, 'sample.txt'));
        expect(await file.readAsString(), 'raw payload as-is');
      },
    );

    test(
      'content beyond kelivo_read window is not saved; download_path hinted',
      () async {
        KelivoFetcher.maxReadableTextBytes = 50;
        final result = await _callFetch(engine, baseUri.resolve('/html'));
        final text = _resultText(result);

        expect(text, contains('Content too large to save as text'));
        expect(text, contains('download_path'));
        expect(text, isNot(contains('saved to @workspaces/.fetch_cache')));
        expect(_fetchCacheFiles(wsDir), isEmpty);
      },
    );

    test('downloads also run eviction: stale .part files age out', () async {
      final cacheDir = Directory(p.join(wsDir.path, '.fetch_cache'));
      await cacheDir.create(recursive: true);
      final stalePart = File(p.join(cacheDir.path, 'old.part'));
      await stalePart.writeAsString('crashed download');
      await stalePart.setLastModified(
        DateTime.now().subtract(const Duration(days: 8)),
      );

      final result = await _callFetch(
        engine,
        baseUri.resolve('/download.txt'),
        arguments: const {'download_path': '@workspaces/sample.txt'},
      );

      expect(result['isError'], isFalse);
      expect(await stalePart.exists(), isFalse);
    });

    test('budget eviction never deletes fresh in-flight .part files', () async {
      final cacheDir = Directory(p.join(wsDir.path, '.fetch_cache'));
      await cacheDir.create(recursive: true);
      final oldFile = File(p.join(cacheDir.path, 'old.txt'));
      await oldFile.writeAsString(List.filled(30, 'a').join());
      await oldFile.setLastModified(
        DateTime.now().subtract(const Duration(days: 2)),
      );
      final inFlight = File(p.join(cacheDir.path, 'inflight.part'));
      await inFlight.writeAsString(List.filled(30, 'b').join());

      KelivoFetcher.cacheBudgetBytes = 50;
      final result = await _callFetch(
        engine,
        baseUri.resolve('/download.txt'),
        arguments: const {'download_path': '@workspaces/sample.txt'},
      );

      expect(result['isError'], isFalse);
      expect(await oldFile.exists(), isFalse); // budget trimmed the old file
      expect(await inFlight.exists(), isTrue); // fresh .part never evicted
    });

    test(
      'budget eviction removes .part files past the crash grace period',
      () async {
        final cacheDir = Directory(p.join(wsDir.path, '.fetch_cache'));
        await cacheDir.create(recursive: true);
        final crashed = File(p.join(cacheDir.path, 'crashed.part'));
        await crashed.writeAsString(List.filled(30, 'c').join());
        await crashed.setLastModified(
          DateTime.now().subtract(const Duration(days: 1)),
        );

        KelivoFetcher.cacheBudgetBytes = 10;
        final result = await _callFetch(
          engine,
          baseUri.resolve('/download.txt'),
          arguments: const {'download_path': '@workspaces/sample.txt'},
        );

        expect(result['isError'], isFalse);
        expect(await crashed.exists(), isFalse); // stale .part budget-evicted
      },
    );

    test(
      'download_path targeting an existing directory errors cleanly',
      () async {
        final dir = Directory(p.join(wsDir.path, 'notes'));
        await dir.create(recursive: true);

        final result = await _callFetch(
          engine,
          baseUri.resolve('/download.txt'),
          arguments: const {'download_path': '@workspaces/notes'},
        );

        expect(result['isError'], isTrue);
        expect(_resultText(result), contains('directory already exists'));
        expect(await dir.exists(), isTrue); // directory untouched
        expect(
          wsDir
              .listSync()
              .whereType<File>()
              .where((f) => f.path.endsWith('.bak'))
              .toList(),
          isEmpty,
        );
      },
    );

    test('a stalled download stream times out instead of hanging', () async {
      KelivoFetcher.downloadChunkTimeout = const Duration(milliseconds: 200);
      final result = await _callFetch(
        engine,
        baseUri.resolve('/stall'),
        arguments: const {'download_path': '@workspaces/stall.bin'},
      );

      expect(result['isError'], isTrue);
      expect(_resultText(result), contains('TimeoutException'));
    });

    test('a stalled text-mode fetch times out instead of hanging', () async {
      KelivoFetcher.textFetchTimeout = const Duration(milliseconds: 200);
      final result = await _callFetch(engine, baseUri.resolve('/stall'));

      expect(result['isError'], isTrue);
      expect(_resultText(result), contains('TimeoutException'));
    });

    test(
      'a server that never sends headers cannot hang the download',
      () async {
        KelivoFetcher.downloadResponseTimeout = const Duration(
          milliseconds: 200,
        );
        final result = await _callFetch(
          engine,
          baseUri.resolve('/no-headers'),
          arguments: const {'download_path': '@workspaces/nohead.bin'},
        );

        expect(result['isError'], isTrue);
      },
    );

    test(
      'binary content-type is flagged even without early null bytes',
      () async {
        final result = await _callFetch(engine, baseUri.resolve('/image.png'));

        expect(result['isError'], isTrue);
        expect(_resultText(result).toLowerCase(), contains('binary'));
        expect(_resultText(result), contains('download_path'));
      },
    );

    test(
      'budget eviction never deletes fresh install-phase .bak files',
      () async {
        final cacheDir = Directory(p.join(wsDir.path, '.fetch_cache'));
        await cacheDir.create(recursive: true);
        final oldFile = File(p.join(cacheDir.path, 'old.txt'));
        await oldFile.writeAsString(List.filled(30, 'a').join());
        await oldFile.setLastModified(
          DateTime.now().subtract(const Duration(days: 2)),
        );
        final freshBackup = File(p.join(cacheDir.path, 'notes.bak'));
        await freshBackup.writeAsString(List.filled(30, 'b').join());

        KelivoFetcher.cacheBudgetBytes = 50;
        final result = await _callFetch(
          engine,
          baseUri.resolve('/download.txt'),
          arguments: const {'download_path': '@workspaces/sample.txt'},
        );

        expect(result['isError'], isFalse);
        expect(await oldFile.exists(), isFalse); // budget trimmed the old file
        expect(await freshBackup.exists(), isTrue); // fresh .bak never evicted
      },
    );

    test(
      'budget eviction never deletes another call\'s fresh overflow file',
      () async {
        final cacheDir = Directory(p.join(wsDir.path, '.fetch_cache'));
        await cacheDir.create(recursive: true);
        final oldFile = File(p.join(cacheDir.path, 'old.md'));
        await oldFile.writeAsString(List.filled(30, 'a').join());
        await oldFile.setLastModified(
          DateTime.now().subtract(const Duration(days: 2)),
        );
        final freshOverflow = File(p.join(cacheDir.path, 'fresh.md'));
        await freshOverflow.writeAsString(List.filled(30, 'b').join());

        KelivoFetcher.cacheBudgetBytes = 50;
        final result = await _callFetch(
          engine,
          baseUri.resolve('/unicode'),
          arguments: const {'max_length': 1},
        );

        expect(result['isError'], isFalse);
        expect(await oldFile.exists(), isFalse); // old overflow trimmed
        expect(await freshOverflow.exists(), isTrue); // fresh one protected
      },
    );

    test(
      'client-side request timeout does not cancel the in-flight download',
      () async {
        final server = KelivoFetchMcpServerEngine(
          workspacesDirProvider: () async => wsDir,
        );
        final transport = KelivoInMemoryClientTransport(server);
        final client = mcp.McpClient.createClient(
          mcp.McpClient.simpleConfig(
            name: 'test',
            version: '1.0.0',
            requestTimeout: const Duration(milliseconds: 200),
          ),
        );
        await client.connect(transport);
        try {
          await client.callTool('kelivo_fetch', {
            'url': baseUri.resolve('/stall').toString(),
            'download_path': '@workspaces/sample.txt',
          });
          fail('expected the client-side request timeout to fire');
        } on mcp.McpError catch (e) {
          expect(e.message, contains('Request timed out'));
        }
        client.disconnect();
        transport.close();
        server.close();

        // The server-side download runs to completion in the same isolate
        // regardless of the client timeout: the file exists once the stalled
        // body finishes (1 s park), and the result is simply discarded.
        await Future<void>.delayed(const Duration(seconds: 2));
        final file = File(p.join(wsDir.path, 'sample.txt'));
        expect(await file.exists(), isTrue);
        expect(await file.readAsString(), 'first-chunk');
      },
    );
  });
}

List<File> _fetchCacheFiles(Directory wsDir) {
  final dir = Directory(p.join(wsDir.path, '.fetch_cache'));
  if (!dir.existsSync()) return [];
  return dir.listSync().whereType<File>().toList();
}

Future<Map<String, dynamic>> _callFetch(
  KelivoFetchMcpServerEngine engine,
  Uri url, {
  Map<String, dynamic> arguments = const {},
}) async {
  final response =
      await engine.handleMessage({
            'jsonrpc': '2.0',
            'id': 1,
            'method': 'tools/call',
            'params': {
              'name': 'kelivo_fetch',
              'arguments': {'url': url.toString(), ...arguments},
            },
          })
          as Map<String, dynamic>;
  return ((response['result'] as Map).cast<String, dynamic>());
}

String _resultText(Map<String, dynamic> result) {
  final content = result['content'] as List;
  return ((content.single as Map)['text'] as String);
}
