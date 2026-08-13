import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:Cuplivo/features/skills/skill_importer.dart';
import 'package:Cuplivo/features/skills/skill_manager.dart';

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

String _skillMd(String name, {String description = 'test skill'}) {
  return '---\nname: $name\ndescription: $description\n---\nbody text';
}

File _makeZip(Directory dir, Map<String, String> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.addFile(ArchiveFile.string(entry.key, entry.value));
  }
  final bytes = ZipEncoder().encode(archive);
  final file = File('${dir.path}/repo.zip');
  file.writeAsBytesSync(bytes, flush: true);
  return file;
}

void main() {
  late Directory root;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('skill_importer_test_');
    PathProviderPlatform.instance = _FakePathProviderPlatform(root.path);
  });

  tearDownAll(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  group('scanZipForSkills', () {
    test('discovers a skill at the repository root', () async {
      final zip = _makeZip(root, {
        'repo-main/SKILL.md': _skillMd('alpha'),
        'repo-main/references/notes.md': 'notes',
      });

      final discovered = await SkillImporter.scanZipForSkills(
        zip,
        stripPrefix: 'repo-main/',
      );

      expect(discovered, hasLength(1));
      expect(discovered!.first.name, 'alpha');
      expect(discovered.first.description, 'test skill');
      expect(
        discovered.first.files.keys,
        containsAll(['SKILL.md', 'references/notes.md']),
      );
    });

    test('filters by subPath', () async {
      final zip = _makeZip(root, {
        'repo-main/skills/foo/SKILL.md': _skillMd('foo'),
        'repo-main/skills/bar/SKILL.md': _skillMd('bar'),
        'repo-main/README.md': 'readme',
      });

      final discovered = await SkillImporter.scanZipForSkills(
        zip,
        stripPrefix: 'repo-main/',
        subPath: 'skills/foo',
      );

      expect(discovered, hasLength(1));
      expect(discovered!.first.name, 'foo');
    });

    test('skips excluded paths and non-skill content', () async {
      final zip = _makeZip(root, {
        'repo-main/.git/config': 'x',
        'repo-main/node_modules/pkg/index.js': 'x',
        'repo-main/README.md': 'readme',
        'repo-main/SKILL.md': _skillMd('alpha'),
      });

      final discovered = await SkillImporter.scanZipForSkills(
        zip,
        stripPrefix: 'repo-main/',
      );

      expect(discovered, hasLength(1));
      expect(discovered!.first.name, 'alpha');
    });

    test('skips files above the size limit', () async {
      final big = 'x' * (SkillImporter.maxImportFileSize + 1);
      final zip = _makeZip(root, {
        'repo-main/big.bin': big,
        'repo-main/SKILL.md': _skillMd('alpha'),
      });

      final discovered = await SkillImporter.scanZipForSkills(
        zip,
        stripPrefix: 'repo-main/',
      );

      expect(discovered, hasLength(1));
      expect(discovered!.first.files.keys, isNot(contains('big.bin')));
    });

    test('returns empty list when no SKILL.md has a valid name', () async {
      final zip = _makeZip(root, {
        'repo-main/README.md': 'readme',
        'repo-main/SKILL.md': 'no frontmatter here',
      });

      final discovered = await SkillImporter.scanZipForSkills(
        zip,
        stripPrefix: 'repo-main/',
      );

      expect(discovered, isEmpty);
    });

    test('does not crash on garbage zip bytes', () async {
      final file = File('${root.path}/broken.zip');
      file.writeAsBytesSync(utf8.encode('not a zip'), flush: true);

      final discovered = await SkillImporter.scanZipForSkills(file);

      expect(discovered, isEmpty);
    });
  });

  group('importFromZip', () {
    test('imports all skills when fewer than 5 are discovered', () async {
      final zip = _makeZip(root, {
        'repo-main/alpha/SKILL.md': _skillMd('alpha'),
        'repo-main/beta/SKILL.md': _skillMd('beta'),
      });

      final outcome = await SkillImporter.importFromZip(
        zip,
        stripPrefix: 'repo-main/',
      );

      expect(outcome.isSuccess, isTrue);
      expect(outcome.error, isNull);
      expect(outcome.result!.imported, 2);
      expect(outcome.result!.failed, 0);
      expect(outcome.result!.importedNames, ['alpha', 'beta']);
      expect(await SkillManager.skillExists('alpha'), isTrue);
      expect(await SkillManager.skillExists('beta'), isTrue);
    });

    test('rejects the import when 5 or more skills are discovered', () async {
      final files = <String, String>{
        for (int i = 0; i < 6; i++)
          'repo-main/skill$i/SKILL.md': _skillMd('skill$i'),
      };
      final zip = _makeZip(root, files);

      final outcome = await SkillImporter.importFromZip(
        zip,
        stripPrefix: 'repo-main/',
      );

      expect(outcome.error, 'too_many_skills');
      expect(outcome.discoveredCount, 6);
      expect(outcome.result, isNull);
      expect(await SkillManager.skillExists('skill0'), isFalse);
    });

    test('reports no_skills_found when the zip has no skills', () async {
      final zip = _makeZip(root, {'repo-main/README.md': 'readme'});

      final outcome = await SkillImporter.importFromZip(
        zip,
        stripPrefix: 'repo-main/',
      );

      expect(outcome.error, 'no_skills_found');
      expect(outcome.isSuccess, isFalse);
    });

    test('reports no_skills_found for a garbage zip', () async {
      final file = File('${root.path}/broken2.zip');
      file.writeAsBytesSync(utf8.encode('not a zip'), flush: true);

      final outcome = await SkillImporter.importFromZip(file);

      expect(outcome.error, 'no_skills_found');
      expect(outcome.isSuccess, isFalse);
    });

    test('counts per-skill failures without stopping the batch', () async {
      final zip = _makeZip(root, {
        'repo-main/good/SKILL.md': _skillMd('good'),
        // uppercase name fails SkillPaths.validateName
        'repo-main/bad/SKILL.md': _skillMd('BADNAME'),
      });

      final outcome = await SkillImporter.importFromZip(
        zip,
        stripPrefix: 'repo-main/',
      );

      expect(outcome.isSuccess, isTrue);
      expect(outcome.result!.imported, 1);
      expect(outcome.result!.failed, 1);
      expect(outcome.result!.importedNames, ['good']);
      expect(await SkillManager.skillExists('good'), isTrue);
    });
  });
}
