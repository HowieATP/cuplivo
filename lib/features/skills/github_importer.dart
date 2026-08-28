import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

/// Hard cap for a downloaded repository archive, protecting the in-memory
/// buffer and the later zip scan (see SkillImporter caps) from zip-bomb
/// style archives. Skill repositories are far smaller than this.
const int maxArchiveDownloadBytes = 64 * 1024 * 1024;

class GitHubRepoInfo {
  final String owner;
  final String repo;
  final String? branch;
  final String? subPath;

  const GitHubRepoInfo({
    required this.owner,
    required this.repo,
    this.branch,
    this.subPath,
  });

  bool get usesDefaultBranch => branch == null;

  String get archiveUrl => usesDefaultBranch
      ? 'https://codeload.github.com/$owner/$repo/zip/HEAD'
      : 'https://github.com/$owner/$repo/archive/refs/heads/$branch.zip';

  String get stripPrefix => '$repo-${branch ?? 'HEAD'}/';
}

GitHubRepoInfo? parseGitHubUrl(String url) {
  final trimmed = url.trim();
  final uri = Uri.tryParse(trimmed);
  if (uri == null) return null;

  if (uri.scheme != 'https' || uri.hasPort || uri.userInfo.isNotEmpty) {
    return null;
  }
  final host = uri.host.toLowerCase();
  if (host != 'github.com' && host != 'www.github.com') return null;

  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segments.length < 2 || segments.length == 3) return null;

  final owner = segments[0];
  final repo = segments[1];
  if (!_isSafeGitHubSegment(owner) || !_isSafeGitHubSegment(repo)) return null;

  String? branch;
  String? subPath;

  if (segments.length == 2) {
    // A bare repository URL follows the repository's configured default
    // branch through GitHub's HEAD archive instead of guessing `main`.
  } else if (segments.length >= 4 && segments[2] == 'tree') {
    branch = segments[3];
    if (!_isSafeGitHubSegment(branch)) return null;
    if (segments.length > 4) {
      final pathSegments = segments.sublist(4);
      if (pathSegments.any((segment) => !_isSafeGitHubPathSegment(segment))) {
        return null;
      }
      subPath = pathSegments.join('/');
    }
  } else {
    return null;
  }

  return GitHubRepoInfo(
    owner: owner,
    repo: repo,
    branch: branch,
    subPath: subPath,
  );
}

bool _isSafeGitHubSegment(String value) =>
    RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(value) &&
    value != '.' &&
    value != '..';

bool _isSafeGitHubPathSegment(String value) =>
    value.isNotEmpty && value != '.' && value != '..';

Future<File?> downloadGitHubArchive(
  GitHubRepoInfo info, {
  http.Client? client,
}) async {
  final c = client ?? http.Client();
  try {
    final response = await c
        .get(Uri.parse(info.archiveUrl))
        .timeout(const Duration(seconds: 60));
    if (response.statusCode != 200) return null;
    if (response.contentLength != null &&
        response.contentLength! > maxArchiveDownloadBytes) {
      return null;
    }
    if (response.bodyBytes.length > maxArchiveDownloadBytes) return null;

    final tmpDir = Directory.systemTemp;
    final tmpFile = File(
      p.join(
        tmpDir.path,
        'cuplivo_skill_${DateTime.now().millisecondsSinceEpoch}.zip',
      ),
    );
    await tmpFile.writeAsBytes(response.bodyBytes, flush: true);
    return tmpFile;
  } on Object catch (error, stackTrace) {
    debugPrint('downloadGitHubArchive: $error\n$stackTrace');
    return null;
  } finally {
    if (client == null) c.close();
  }
}
