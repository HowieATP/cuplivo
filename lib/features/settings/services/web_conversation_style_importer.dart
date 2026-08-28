import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../../../core/models/web_conversation_style.dart';
import '../../../core/services/network/dio_http_client.dart';
import '../../skills/github_importer.dart' show GitHubRepoInfo, parseGitHubUrl;

const int webConversationStyleArchiveByteLimit = 64 * 1024 * 1024;
const int webConversationStyleArchiveEntryLimit = 2000;

enum WebConversationStyleImportErrorCode {
  invalidFileName,
  invalidArchive,
  archiveTooLarge,
  tooManyArchiveEntries,
  noStylesFound,
  invalidGithubUrl,
  githubDownloadFailed,
}

class WebConversationStyleImportException implements Exception {
  const WebConversationStyleImportException(this.code, [this.detail]);

  final WebConversationStyleImportErrorCode code;
  final String? detail;

  @override
  String toString() => detail == null ? code.name : '${code.name}: $detail';
}

class WebConversationStyleCandidate {
  const WebConversationStyleCandidate({
    required this.sourceName,
    required this.bytes,
  });

  final String sourceName;
  final List<int> bytes;

  WebConversationStyle parse() => WebConversationStyle.parseBytes(bytes);
}

class _ArchiveScanRequest {
  const _ArchiveScanRequest({
    required this.bytes,
    this.subPath,
    this.stripPrefix,
  });

  final Uint8List bytes;
  final String? subPath;
  final String? stripPrefix;
}

class WebConversationStyleImporter {
  const WebConversationStyleImporter();

  WebConversationStyleCandidate singleFile(String fileName, List<int> bytes) {
    if (!fileName.endsWith(webConversationStyleFileSuffix)) {
      throw const WebConversationStyleImportException(
        WebConversationStyleImportErrorCode.invalidFileName,
      );
    }
    if (bytes.length > webConversationStyleFileByteLimit) {
      throw const WebConversationStyleException(
        WebConversationStyleErrorCode.fileTooLarge,
      );
    }
    return WebConversationStyleCandidate(
      sourceName: fileName,
      bytes: List.unmodifiable(bytes),
    );
  }

  WebConversationStyleCandidate manual(String source) {
    return singleFile(
      'manual$webConversationStyleFileSuffix',
      utf8.encode(source),
    );
  }

  Future<List<WebConversationStyleCandidate>> scanArchive(
    List<int> bytes, {
    String? subPath,
    String? stripPrefix,
  }) async {
    if (bytes.length > webConversationStyleArchiveByteLimit) {
      throw const WebConversationStyleImportException(
        WebConversationStyleImportErrorCode.archiveTooLarge,
      );
    }
    final result = await compute(
      _scanArchive,
      _ArchiveScanRequest(
        bytes: Uint8List.fromList(bytes),
        subPath: subPath,
        stripPrefix: stripPrefix,
      ),
    );
    if (result.error != null) throw result.error!;
    if (result.candidates.isEmpty) {
      throw const WebConversationStyleImportException(
        WebConversationStyleImportErrorCode.noStylesFound,
      );
    }
    return result.candidates;
  }

  Future<List<WebConversationStyleCandidate>> downloadGithub(
    String url, {
    NetworkProxyConfig? proxy,
  }) async {
    final info = parseGitHubUrl(url);
    if (info == null || !_isSafeGithubInfo(info)) {
      throw const WebConversationStyleImportException(
        WebConversationStyleImportErrorCode.invalidGithubUrl,
      );
    }
    final client = DioHttpClient(proxy: proxy, forceCloseOnDispose: true);
    try {
      final response = await client
          .send(http.Request('GET', Uri.parse(info.archiveUrl)))
          .timeout(const Duration(seconds: 60));
      if (response.statusCode != 200) {
        throw WebConversationStyleImportException(
          WebConversationStyleImportErrorCode.githubDownloadFailed,
          '${response.statusCode}',
        );
      }
      final declaredLength = response.contentLength;
      if (declaredLength != null &&
          declaredLength > webConversationStyleArchiveByteLimit) {
        throw const WebConversationStyleImportException(
          WebConversationStyleImportErrorCode.archiveTooLarge,
        );
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 60),
      )) {
        if (bytes.length + chunk.length >
            webConversationStyleArchiveByteLimit) {
          throw const WebConversationStyleImportException(
            WebConversationStyleImportErrorCode.archiveTooLarge,
          );
        }
        bytes.add(chunk);
      }
      return scanArchive(
        bytes.takeBytes(),
        subPath: info.subPath,
        stripPrefix: info.stripPrefix,
      );
    } on WebConversationStyleImportException {
      rethrow;
    } on Object catch (error, stackTrace) {
      debugPrint(
        'WebConversationStyleImporter.downloadGithub: $error\n$stackTrace',
      );
      throw WebConversationStyleImportException(
        WebConversationStyleImportErrorCode.githubDownloadFailed,
        '$error',
      );
    } finally {
      client.close();
    }
  }

  List<WebConversationStyle> validateBatch(
    Iterable<WebConversationStyleCandidate> candidates,
  ) {
    final styles = candidates.map((candidate) => candidate.parse()).toList();
    final ids = <String>{};
    for (final style in styles) {
      if (!ids.add(style.id)) {
        throw WebConversationStyleException(
          WebConversationStyleErrorCode.duplicateId,
          style.id,
        );
      }
    }
    return List.unmodifiable(styles);
  }
}

bool _isSafeGithubInfo(GitHubRepoInfo info) {
  final segment = RegExp(r'^[A-Za-z0-9._-]+$');
  return segment.hasMatch(info.owner) &&
      segment.hasMatch(info.repo) &&
      segment.hasMatch(info.branch);
}

class _ArchiveScanResult {
  const _ArchiveScanResult({this.candidates = const [], this.error});

  final List<WebConversationStyleCandidate> candidates;
  final WebConversationStyleImportException? error;
}

_ArchiveScanResult _scanArchive(_ArchiveScanRequest request) {
  Archive? archive;
  try {
    if (request.bytes.length < 4 ||
        request.bytes[0] != 0x50 ||
        request.bytes[1] != 0x4b ||
        !const <int>{0x03, 0x05, 0x07}.contains(request.bytes[2])) {
      return const _ArchiveScanResult(
        error: WebConversationStyleImportException(
          WebConversationStyleImportErrorCode.invalidArchive,
        ),
      );
    }
    archive = ZipDecoder().decodeBytes(request.bytes);
    if (archive.length > webConversationStyleArchiveEntryLimit) {
      return const _ArchiveScanResult(
        error: WebConversationStyleImportException(
          WebConversationStyleImportErrorCode.tooManyArchiveEntries,
        ),
      );
    }
    var totalBytes = 0;
    final candidates = <WebConversationStyleCandidate>[];
    for (final entry in archive) {
      totalBytes += entry.size;
      if (totalBytes > webConversationStyleArchiveByteLimit) {
        return const _ArchiveScanResult(
          error: WebConversationStyleImportException(
            WebConversationStyleImportErrorCode.archiveTooLarge,
          ),
        );
      }
      if (!entry.isFile) continue;
      var relativePath = entry.name.replaceAll('\\', '/');
      final stripPrefix = request.stripPrefix;
      if (stripPrefix != null && relativePath.startsWith(stripPrefix)) {
        relativePath = relativePath.substring(stripPrefix.length);
      }
      final subPath = request.subPath?.replaceAll('\\', '/');
      if (subPath != null && subPath.isNotEmpty) {
        final normalized = subPath.endsWith('/') ? subPath : '$subPath/';
        if (!relativePath.startsWith(normalized)) continue;
      }
      if (!p.posix.isRelative(relativePath) ||
          p.posix.split(relativePath).contains('..') ||
          !relativePath.endsWith(webConversationStyleFileSuffix)) {
        continue;
      }
      candidates.add(
        WebConversationStyleCandidate(
          sourceName: relativePath,
          bytes: List<int>.unmodifiable(entry.content as List<int>),
        ),
      );
    }
    candidates.sort((a, b) => a.sourceName.compareTo(b.sourceName));
    return _ArchiveScanResult(candidates: List.unmodifiable(candidates));
  } on WebConversationStyleImportException catch (error) {
    return _ArchiveScanResult(error: error);
  } on Object catch (error, stackTrace) {
    debugPrint('WebConversationStyleImporter.scanArchive: $error\n$stackTrace');
    return const _ArchiveScanResult(
      error: WebConversationStyleImportException(
        WebConversationStyleImportErrorCode.invalidArchive,
      ),
    );
  } finally {
    archive?.clear();
  }
}
