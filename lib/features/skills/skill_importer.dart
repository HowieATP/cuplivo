import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart' show compute, debugPrint;
import 'package:path/path.dart' as p;

import 'skill_manager.dart';

class DiscoveredSkill {
  final String name;
  final String description;
  final Map<String, List<int>> files;

  const DiscoveredSkill({
    required this.name,
    required this.description,
    required this.files,
  });
}

class SkillImportResult {
  final int imported;
  final int failed;
  final List<String> importedNames;

  const SkillImportResult({
    required this.imported,
    required this.failed,
    required this.importedNames,
  });
}

/// Error codes returned by [SkillZipImportOutcome.error].
class SkillZipError {
  const SkillZipError._();

  static const String scanFailed = 'scan_failed';
  static const String noSkillsFound = 'no_skills_found';
  static const String tooManySkills = 'too_many_skills';
}

class SkillZipImportOutcome {
  /// One of [SkillZipError] when the import did not run. Null when skills
  /// were imported.
  final String? error;
  final int discoveredCount;
  final SkillImportResult? result;

  const SkillZipImportOutcome({
    required this.error,
    required this.discoveredCount,
    this.result,
  });

  bool get isSuccess => error == null;
}

class _ScanRequest {
  final String filePath;
  final String? subPath;
  final String? stripPrefix;

  const _ScanRequest({required this.filePath, this.subPath, this.stripPrefix});
}

/// Shared skill import pipeline used by both the Skills page UI and the
/// `download_skill` LLM tool. Keeps the zip-scan/import logic in one place so
/// headless (tool) flows and interactive (dialog) flows behave identically.
class SkillImporter {
  SkillImporter._();

  static const int maxImportFileSize = 1024 * 1024;

  /// Hard caps against zip-bomb style archives. The scan aborts (returns
  /// null) once either limit is exceeded.
  static const int maxArchiveEntries = 2000;
  static const int maxArchiveTotalBytes = 64 * 1024 * 1024;

  /// Scan a zip archive for skill directories (each containing a SKILL.md
  /// with a valid `name` frontmatter field).
  ///
  /// Runs off the main isolate so large archives do not jank the UI.
  /// Returns null when the archive cannot be scanned, an empty list when no
  /// valid skills are found, or the discovered skills otherwise.
  static Future<List<DiscoveredSkill>?> scanZipForSkills(
    File file, {
    String? subPath,
    String? stripPrefix,
  }) {
    return compute(
      _scanZipForSkillsInIsolate,
      _ScanRequest(
        filePath: file.path,
        subPath: subPath,
        stripPrefix: stripPrefix,
      ),
    );
  }

  static List<DiscoveredSkill>? _scanZipForSkillsInIsolate(
    _ScanRequest request,
  ) {
    return _scanZipForSkillsSync(
      File(request.filePath),
      subPath: request.subPath,
      stripPrefix: request.stripPrefix,
    );
  }

  static List<DiscoveredSkill>? _scanZipForSkillsSync(
    File file, {
    String? subPath,
    String? stripPrefix,
  }) {
    final discovered = <DiscoveredSkill>[];
    try {
      final bytes = file.readAsBytesSync();
      final archive = ZipDecoder().decodeBytes(bytes);

      final skillDirs = <String>{};
      final allFiles = <String, List<int>>{};
      var entryCount = 0;
      var totalBytes = 0;

      for (final entry in archive) {
        if (!entry.isFile) continue;

        entryCount++;
        if (entryCount > maxArchiveEntries) {
          archive.clear();
          return null;
        }
        totalBytes += entry.size;
        if (totalBytes > maxArchiveTotalBytes) {
          archive.clear();
          return null;
        }

        var relativePath = entry.name;
        if (stripPrefix != null && relativePath.startsWith(stripPrefix)) {
          relativePath = relativePath.substring(stripPrefix.length);
        }
        if (subPath != null && subPath.isNotEmpty) {
          final normalized = subPath.endsWith('/') ? subPath : '$subPath/';
          if (!relativePath.startsWith(normalized) && relativePath != subPath) {
            continue;
          }
        }

        if (_isExcludedPath(relativePath) ||
            relativePath.contains('..') ||
            !p.isRelative(relativePath)) {
          continue;
        }
        if (entry.size > maxImportFileSize) continue;

        allFiles[relativePath] = entry.content as List<int>;

        if (p.basename(relativePath) == 'SKILL.md') {
          final dir = p.dirname(relativePath);
          skillDirs.add(dir == '.' ? '' : dir);
        }
      }

      final seenNames = <String>{};
      for (final skillDir in skillDirs) {
        final skillMdKey = skillDir.isEmpty ? 'SKILL.md' : '$skillDir/SKILL.md';
        final skillMdBytes = allFiles[skillMdKey];
        if (skillMdBytes == null) continue;

        final content = utf8.decode(skillMdBytes);
        final parsed = SkillManager.parseFrontmatter(content);
        if (parsed == null) continue;
        final name = parsed.fields['name'];
        if (name == null || name.isEmpty) continue;
        // Duplicate frontmatter names would silently overwrite each other
        // during import; keep only the first occurrence.
        if (!seenNames.add(name)) continue;

        final files = _collectSkillFiles(skillDir, skillDirs, allFiles);

        discovered.add(
          DiscoveredSkill(
            name: name,
            description: parsed.fields['description'] ?? '',
            files: files,
          ),
        );
      }
      archive.clear();
    } catch (e) {
      debugPrint('SkillImporter.scanZipForSkills: failed to scan ZIP: $e');
      return null;
    }
    return discovered;
  }

  /// Collect the files owned by [skillDir].
  ///
  /// Files that belong to another skill directory (a sibling, or a nested
  /// child skill) are excluded so a skill never absorbs another skill's
  /// content. All other files under the skill directory are kept, including
  /// auxiliary subdirectories like `references/`.
  static Map<String, List<int>> _collectSkillFiles(
    String skillDir,
    Set<String> skillDirs,
    Map<String, List<int>> allFiles,
  ) {
    final files = <String, List<int>>{};
    for (final entry in allFiles.entries) {
      final key = entry.key;
      if (!_fileBelongsToSkillDir(key, skillDir)) continue;
      var ownedByOther = false;
      for (final other in skillDirs) {
        if (other == skillDir) continue;
        if (_fileBelongsToSkillDir(key, other)) {
          ownedByOther = true;
          break;
        }
      }
      if (ownedByOther) continue;
      final relativeToSkill = skillDir.isEmpty
          ? key
          : key.substring(skillDir.length + 1);
      files[relativeToSkill] = entry.value;
    }
    return files;
  }

  /// Whether [fileKey] (an archive-relative path) is inside [skillDir]
  /// itself. The root skill (`skillDir == ''`) spans the whole archive minus
  /// the other skills' subtrees.
  static bool _fileBelongsToSkillDir(String fileKey, String skillDir) {
    if (skillDir.isEmpty) return true;
    final prefix = '$skillDir/';
    if (!fileKey.startsWith(prefix)) return false;
    return fileKey.substring(prefix.length).isNotEmpty;
  }

  static bool _isExcludedPath(String path) {
    final segments = path.split('/');
    for (final seg in segments) {
      if (seg.startsWith('.')) return true;
      if (seg == '__pycache__' || seg == 'node_modules') return true;
    }
    return false;
  }

  /// Persist discovered skills to disk via [SkillManager.saveSkillWithFiles].
  static Future<SkillImportResult> importSkills(
    List<DiscoveredSkill> skills,
  ) async {
    int imported = 0;
    int failed = 0;
    final importedNames = <String>[];

    for (final skill in skills) {
      final error = await SkillManager.saveSkillWithFiles(
        name: skill.name,
        files: skill.files,
      );
      if (error != null) {
        failed++;
      } else {
        imported++;
        importedNames.add(skill.name);
      }
    }

    return SkillImportResult(
      imported: imported,
      failed: failed,
      importedNames: importedNames,
    );
  }

  /// Headless import of skills from an already-downloaded repository zip.
  ///
  /// Mirrors the interactive Skills page rule: fewer than 5 discovered skills
  /// are imported in full; 5 or more return a [SkillZipError.tooManySkills]
  /// outcome (the interactive page would let the user pick, headless flows
  /// cannot).
  static Future<SkillZipImportOutcome> importFromZip(
    File file, {
    String? subPath,
    String? stripPrefix,
  }) async {
    final discovered = await scanZipForSkills(
      file,
      subPath: subPath,
      stripPrefix: stripPrefix,
    );
    if (discovered == null) {
      return const SkillZipImportOutcome(
        error: SkillZipError.scanFailed,
        discoveredCount: 0,
      );
    }
    if (discovered.isEmpty) {
      return const SkillZipImportOutcome(
        error: SkillZipError.noSkillsFound,
        discoveredCount: 0,
      );
    }
    if (discovered.length >= 5) {
      return SkillZipImportOutcome(
        error: SkillZipError.tooManySkills,
        discoveredCount: discovered.length,
      );
    }
    final result = await importSkills(discovered);
    return SkillZipImportOutcome(
      error: null,
      discoveredCount: discovered.length,
      result: result,
    );
  }
}
