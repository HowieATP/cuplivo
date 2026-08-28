import 'dart:io';

import 'package:Cuplivo/features/skills/github_importer.dart';
import 'package:Cuplivo/features/skills/skill_importer.dart';
import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

List<int> _skillArchiveBytes(String prefix) {
  final archive = Archive()
    ..addFile(
      ArchiveFile.string(
        '${prefix}SKILL.md',
        '---\nname: cloud-skill\ndescription: test\n---\nbody',
      ),
    );
  return ZipEncoder().encode(archive);
}

void main() {
  test('bare repository URL follows the GitHub default branch via HEAD', () {
    final info = parseGitHubUrl(
      'https://github.com/Pheobe-Southwood/cuplivo-styles',
    );

    expect(info, isNotNull);
    expect(info!.usesDefaultBranch, isTrue);
    expect(info.branch, isNull);
    expect(
      info.archiveUrl,
      'https://codeload.github.com/Pheobe-Southwood/cuplivo-styles/zip/HEAD',
    );
    expect(info.stripPrefix, 'cuplivo-styles-HEAD/');
  });

  test('explicit tree URL preserves its branch and subpath', () {
    final info = parseGitHubUrl(
      'https://www.github.com/owner/repo/tree/master/skills/cloud',
    );

    expect(info, isNotNull);
    expect(info!.usesDefaultBranch, isFalse);
    expect(info.branch, 'master');
    expect(info.subPath, 'skills/cloud');
    expect(
      info.archiveUrl,
      'https://github.com/owner/repo/archive/refs/heads/master.zip',
    );
    expect(info.stripPrefix, 'repo-master/');
  });

  test('rejects unsupported or malformed repository URLs', () {
    expect(parseGitHubUrl('http://github.com/owner/repo'), isNull);
    expect(parseGitHubUrl('https://example.com/owner/repo'), isNull);
    expect(parseGitHubUrl('https://github.com/owner'), isNull);
    expect(parseGitHubUrl('https://github.com/owner/repo/blob/main/a'), isNull);
    expect(parseGitHubUrl('https://github.com/owner/repo/issues'), isNull);
    expect(parseGitHubUrl('https://github.com/owner/repo/tree'), isNull);
  });

  test('downloaded HEAD archive is scanned with its stable prefix', () async {
    final info = parseGitHubUrl('https://github.com/owner/repo')!;
    final client = MockClient((request) async {
      expect(request.url.toString(), info.archiveUrl);
      return http.Response.bytes(_skillArchiveBytes(info.stripPrefix), 200);
    });

    File? archive;
    try {
      archive = await downloadGitHubArchive(info, client: client);
      expect(archive, isNotNull);
      final skills = await SkillImporter.scanZipForSkills(
        archive!,
        stripPrefix: info.stripPrefix,
      );
      expect(skills, hasLength(1));
      expect(skills!.single.name, 'cloud-skill');
    } finally {
      client.close();
      if (archive != null && await archive.exists()) {
        await archive.delete();
      }
    }
  });
}
