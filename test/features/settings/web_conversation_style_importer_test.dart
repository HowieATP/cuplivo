import 'dart:convert';
import 'dart:io';

import 'package:Cuplivo/core/models/web_conversation_style.dart';
import 'package:Cuplivo/features/settings/services/web_conversation_style_importer.dart';
import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

List<int> styleBytes(String id) => utf8.encode(
  jsonEncode({
    'kind': webConversationStyleKind,
    'schemaVersion': 1,
    'id': id,
    'name': id,
    'common': {
      'userBubble': {'cornerRadius': 12},
    },
    'light': {},
    'dark': {},
  }),
);

List<int> zipBytes(Map<String, List<int>> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  return ZipEncoder().encode(archive);
}

void main() {
  const importer = WebConversationStyleImporter();

  test('accepts only the required single-file suffix', () {
    expect(
      importer
          .singleFile('one.cuplivo-style.json', styleBytes('one'))
          .parse()
          .id,
      'one',
    );
    expect(
      () => importer.singleFile('one.json', styleBytes('one')),
      throwsA(
        isA<WebConversationStyleImportException>().having(
          (error) => error.code,
          'code',
          WebConversationStyleImportErrorCode.invalidFileName,
        ),
      ),
    );
  });

  test('documented example is directly importable', () {
    final file = File('docs/examples/soft-cards.cuplivo-style.json');
    final style = importer
        .singleFile(file.path.split('/').last, file.readAsBytesSync())
        .parse();
    expect(style.id, 'soft-cards');
    expect(style.resolveAppearance(isDark: false), contains('processCard'));
    expect(style.resolveAppearance(isDark: true), contains('assistantBubble'));
  });

  test('parses GitHub blob and raw style file URLs', () {
    const rawUrl =
        'https://raw.githubusercontent.com/owner/repo/master/'
        'styles/cloud.cuplivo-style.json';
    final blob = parseWebConversationStyleGitHubFileUrl(
      'https://github.com/owner/repo/blob/master/'
      'styles/cloud.cuplivo-style.json',
    );
    final raw = parseWebConversationStyleGitHubFileUrl(rawUrl);

    expect(blob, isNotNull);
    expect(blob!.downloadUri.toString(), rawUrl);
    expect(blob.sourceName, 'cloud.cuplivo-style.json');
    expect(raw, isNotNull);
    expect(raw!.downloadUri.toString(), rawUrl);
    expect(raw.sourceName, 'cloud.cuplivo-style.json');
  });

  test('rejects unsafe or unsupported GitHub style file URLs', () {
    expect(
      parseWebConversationStyleGitHubFileUrl(
        'https://example.com/owner/repo/master/a.cuplivo-style.json',
      ),
      isNull,
    );
    expect(
      parseWebConversationStyleGitHubFileUrl(
        'http://raw.githubusercontent.com/owner/repo/master/'
        'a.cuplivo-style.json',
      ),
      isNull,
    );
    expect(
      parseWebConversationStyleGitHubFileUrl(
        'https://github.com/owner/repo/blob/master/style.json',
      ),
      isNull,
    );
    expect(
      parseWebConversationStyleGitHubFileUrl(
        'https://github.com/owner/repo/tree/master/'
        'a.cuplivo-style.json',
      ),
      isNull,
    );
  });

  test('downloads a raw style file through the single-file pipeline', () async {
    const rawUrl =
        'https://raw.githubusercontent.com/owner/repo/master/'
        'cloud.cuplivo-style.json';
    final client = MockClient((request) async {
      expect(request.url.toString(), rawUrl);
      return http.Response.bytes(styleBytes('cloud'), 200);
    });

    final candidates = await importer.downloadGithub(rawUrl, client: client);

    expect(candidates, hasLength(1));
    expect(candidates.single.sourceName, 'cloud.cuplivo-style.json');
    expect(candidates.single.parse().id, 'cloud');
  });

  test('downloads a bare repository from its HEAD archive', () async {
    final client = MockClient((request) async {
      expect(
        request.url.toString(),
        'https://codeload.github.com/owner/repo/zip/HEAD',
      );
      return http.Response.bytes(
        zipBytes({'repo-HEAD/cloud.cuplivo-style.json': styleBytes('cloud')}),
        200,
      );
    });

    final candidates = await importer.downloadGithub(
      'https://github.com/owner/repo',
      client: client,
    );

    expect(candidates, hasLength(1));
    expect(candidates.single.sourceName, 'cloud.cuplivo-style.json');
    expect(candidates.single.parse().id, 'cloud');
  });

  test('reports GitHub HTTP failures and raw file size limits', () async {
    final failedClient = MockClient((_) async => http.Response('missing', 404));
    expect(
      () => importer.downloadGithub(
        'https://github.com/owner/repo',
        client: failedClient,
      ),
      throwsA(
        isA<WebConversationStyleImportException>().having(
          (error) => error.code,
          'code',
          WebConversationStyleImportErrorCode.githubDownloadFailed,
        ),
      ),
    );

    final oversizedClient = MockClient(
      (_) async => http.Response.bytes(
        List<int>.filled(webConversationStyleFileByteLimit + 1, 0),
        200,
      ),
    );
    expect(
      () => importer.downloadGithub(
        'https://raw.githubusercontent.com/owner/repo/main/'
        'large.cuplivo-style.json',
        client: oversizedClient,
      ),
      throwsA(
        isA<WebConversationStyleException>().having(
          (error) => error.code,
          'code',
          WebConversationStyleErrorCode.fileTooLarge,
        ),
      ),
    );
  });

  test(
    'recursively scans ZIP and applies GitHub prefix/subpath filters',
    () async {
      final candidates = await importer.scanArchive(
        zipBytes({
          'repo-main/themes/a.cuplivo-style.json': styleBytes('a'),
          'repo-main/themes/nested/b.cuplivo-style.json': styleBytes('b'),
          'repo-main/outside/c.cuplivo-style.json': styleBytes('c'),
          'repo-main/themes/readme.md': utf8.encode('ignored'),
        }),
        stripPrefix: 'repo-main/',
        subPath: 'themes',
      );

      expect(candidates.map((candidate) => candidate.sourceName), [
        'themes/a.cuplivo-style.json',
        'themes/nested/b.cuplivo-style.json',
      ]);
      expect(importer.validateBatch(candidates).map((style) => style.id), [
        'a',
        'b',
      ]);
    },
  );

  test('rejects invalid archive and archive item limit', () async {
    expect(
      () => importer.scanArchive([1, 2, 3]),
      throwsA(
        isA<WebConversationStyleImportException>().having(
          (error) => error.code,
          'code',
          WebConversationStyleImportErrorCode.invalidArchive,
        ),
      ),
    );

    final files = <String, List<int>>{
      for (var i = 0; i <= webConversationStyleArchiveEntryLimit; i++)
        'file-$i.txt': const [1],
    };
    expect(
      () => importer.scanArchive(zipBytes(files)),
      throwsA(
        isA<WebConversationStyleImportException>().having(
          (error) => error.code,
          'code',
          WebConversationStyleImportErrorCode.tooManyArchiveEntries,
        ),
      ),
    );
  });

  test(
    'rejects an empty scan and an invalid selected batch atomically',
    () async {
      expect(
        () =>
            importer.scanArchive(zipBytes({'readme.md': utf8.encode('none')})),
        throwsA(
          isA<WebConversationStyleImportException>().having(
            (error) => error.code,
            'code',
            WebConversationStyleImportErrorCode.noStylesFound,
          ),
        ),
      );

      final candidates = [
        WebConversationStyleCandidate(
          sourceName: 'valid.cuplivo-style.json',
          bytes: styleBytes('valid'),
        ),
        const WebConversationStyleCandidate(
          sourceName: 'broken.cuplivo-style.json',
          bytes: [123],
        ),
      ];
      expect(
        () => importer.validateBatch(candidates),
        throwsA(isA<WebConversationStyleException>()),
      );
    },
  );

  test('rejects duplicate IDs in a selected batch', () {
    final candidates = [
      WebConversationStyleCandidate(
        sourceName: 'a.cuplivo-style.json',
        bytes: styleBytes('same'),
      ),
      WebConversationStyleCandidate(
        sourceName: 'b.cuplivo-style.json',
        bytes: styleBytes('same'),
      ),
    ];
    expect(
      () => importer.validateBatch(candidates),
      throwsA(
        isA<WebConversationStyleException>().having(
          (error) => error.code,
          'code',
          WebConversationStyleErrorCode.duplicateId,
        ),
      ),
    );
  });
}
