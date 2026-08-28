import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../../../core/models/web_conversation_style.dart';
import '../../../core/services/network/dio_http_client.dart';
import '../../skills/github_importer.dart' show parseGitHubUrl;

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

class WebConversationStyleGitHubFile {
  const WebConversationStyleGitHubFile({
    required this.downloadUri,
    required this.sourceName,
  });

  final Uri downloadUri;
  final String sourceName;
}

WebConversationStyleGitHubFile? parseWebConversationStyleGitHubFileUrl(
  String url,
) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.hasPort ||
      uri.userInfo.isNotEmpty) {
    return null;
  }

  final host = uri.host.toLowerCase();
  final segments = uri.pathSegments
      .where((segment) => segment.isNotEmpty)
      .toList();
  late final List<String> rawSegments;
  if (host == 'github.com' || host == 'www.github.com') {
    if (segments.length < 5 || segments[2] != 'blob') return null;
    rawSegments = [segments[0], segments[1], ...segments.sublist(3)];
  } else if (host == 'raw.githubusercontent.com') {
    if (segments.length < 4) return null;
    rawSegments = segments;
  } else {
    return null;
  }

  if (!_isSafeGitHubIdentitySegment(rawSegments[0]) ||
      !_isSafeGitHubIdentitySegment(rawSegments[1]) ||
      !_isSafeGitHubIdentitySegment(rawSegments[2]) ||
      rawSegments.sublist(3).any(_isUnsafeGitHubFilePathSegment)) {
    return null;
  }
  final sourceName = rawSegments.last;
  if (!sourceName.endsWith(webConversationStyleFileSuffix)) return null;

  return WebConversationStyleGitHubFile(
    downloadUri: Uri(
      scheme: 'https',
      host: 'raw.githubusercontent.com',
      pathSegments: rawSegments,
    ),
    sourceName: sourceName,
  );
}

bool _isSafeGitHubIdentitySegment(String value) =>
    RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(value) &&
    value != '.' &&
    value != '..';

bool _isUnsafeGitHubFilePathSegment(String value) =>
    value.isEmpty || value == '.' || value == '..';

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
    http.Client? client,
  }) async {
    final repoInfo = parseGitHubUrl(url);
    final fileInfo = parseWebConversationStyleGitHubFileUrl(url);
    if (repoInfo == null && fileInfo == null) {
      throw const WebConversationStyleImportException(
        WebConversationStyleImportErrorCode.invalidGithubUrl,
      );
    }
    final ownsClient = client == null;
    final requestClient =
        client ?? DioHttpClient(proxy: proxy, forceCloseOnDispose: true);
    final byteLimit = fileInfo == null
        ? webConversationStyleArchiveByteLimit
        : webConversationStyleFileByteLimit;
    try {
      final downloadUri =
          fileInfo?.downloadUri ?? Uri.parse(repoInfo!.archiveUrl);
      final response = await requestClient
          .send(http.Request('GET', downloadUri))
          .timeout(const Duration(seconds: 60));
      if (response.statusCode != 200) {
        throw WebConversationStyleImportException(
          WebConversationStyleImportErrorCode.githubDownloadFailed,
          '${response.statusCode}',
        );
      }
      final declaredLength = response.contentLength;
      if (declaredLength != null && declaredLength > byteLimit) {
        _throwGithubDownloadTooLarge(isFile: fileInfo != null);
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 60),
      )) {
        if (bytes.length + chunk.length > byteLimit) {
          _throwGithubDownloadTooLarge(isFile: fileInfo != null);
        }
        bytes.add(chunk);
      }
      final downloadedBytes = bytes.takeBytes();
      if (fileInfo != null) {
        return [singleFile(fileInfo.sourceName, downloadedBytes)];
      }
      return scanArchive(
        downloadedBytes,
        subPath: repoInfo!.subPath,
        stripPrefix: repoInfo.stripPrefix,
      );
    } on WebConversationStyleImportException {
      rethrow;
    } on WebConversationStyleException {
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
      if (ownsClient) requestClient.close();
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

Never _throwGithubDownloadTooLarge({required bool isFile}) {
  if (isFile) {
    throw const WebConversationStyleException(
      WebConversationStyleErrorCode.fileTooLarge,
    );
  }
  throw const WebConversationStyleImportException(
    WebConversationStyleImportErrorCode.archiveTooLarge,
  );
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
