import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart' show IOClient;
import 'package:path/path.dart' as p;
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;

import '../../../utils/app_directories.dart';
import 'readable_web_fetch_service.dart';
import 'web_fetch_content.dart';
import 'web_fetch_target_guard.dart' as guard;
import '../mcp/kelivo_filesystem/kelivo_filesystem_server.dart'
    show isSafeWireSegment, KelivoFilesystemMcpServerEngine;

/// Cuplivo's transport-independent built-in web fetch engine.
///
/// Provides one token-conscious `fetch` tool. HTML is simplified to Markdown
/// by default, while raw content requires an explicit opt-in. Responses are
/// bounded and can be continued with `start_index`.
///
/// `download_path` saves fetched bytes as-is into `@workspaces` (binary
/// allowed); without it, over-length content is stored in
/// `@workspaces/.fetch_cache/` and the path is returned.

class BuiltInWebFetchRequest {
  static const defaultMaxLength = WebFetchContentWindow.defaultMaxLength;
  static const maximumMaxLength = WebFetchContentWindow.maximumMaxLength;

  final Uri url;
  final Map<String, String> headers;
  final int maxLength;
  final int startIndex;
  final bool raw;

  /// Full wire path under `@workspaces/` (validated), or null for text mode.
  final String? downloadPath;

  BuiltInWebFetchRequest({
    required this.url,
    Map<String, String>? headers,
    this.maxLength = defaultMaxLength,
    this.startIndex = 0,
    this.raw = false,
    this.downloadPath,
  }) : headers = headers ?? const {};

  static BuiltInWebFetchRequest parse(Object? args) {
    if (args is! Map) {
      throw ArgumentError(
        'Invalid arguments: expected an object containing url',
      );
    }
    final map = args.cast<String, dynamic>();
    final urlRaw = (map['url'] ?? '').toString().trim();
    final uri = Uri.tryParse(urlRaw);
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        !(uri.isScheme('http') || uri.isScheme('https'))) {
      throw ArgumentError('Invalid url: $urlRaw');
    }
    final blockReason = guard.WebFetchTargetGuard.literalBlockReason(uri);
    if (blockReason != null) {
      throw ArgumentError('Invalid url: $blockReason');
    }
    final headersAny = map['headers'];
    final headers = <String, String>{};
    if (headersAny != null && headersAny is! Map) {
      throw ArgumentError('Invalid headers: expected an object');
    }
    if (headersAny is Map) {
      headersAny.forEach((k, v) {
        if (k == null || v == null) return;
        headers[k.toString()] = v.toString();
      });
    }
    final downloadRaw = map['download_path'];
    final downloadPath = downloadRaw == null
        ? null
        : _validateDownloadPath(downloadRaw.toString());
    if (downloadPath != null) {
      // Download mode: bytes are saved as-is; max_length, start_index and
      // raw are ignored entirely (not even type-validated).
      return BuiltInWebFetchRequest(
        url: uri,
        headers: headers,
        downloadPath: downloadPath,
      );
    }
    final maxLength = _parseInteger(
      map['max_length'],
      name: 'max_length',
      defaultValue: defaultMaxLength,
    );
    if (maxLength < 1 || maxLength > maximumMaxLength) {
      throw ArgumentError(
        'Invalid max_length: expected a value from 1 to $maximumMaxLength',
      );
    }
    final startIndex = _parseInteger(
      map['start_index'],
      name: 'start_index',
      defaultValue: 0,
    );
    if (startIndex < 0) {
      throw ArgumentError('Invalid start_index: expected a non-negative value');
    }
    final rawAny = map['raw'];
    if (rawAny != null && rawAny is! bool) {
      throw ArgumentError('Invalid raw: expected a boolean');
    }

    return BuiltInWebFetchRequest(
      url: uri,
      headers: headers,
      maxLength: maxLength,
      startIndex: startIndex,
      raw: rawAny as bool? ?? false,
    );
  }

  /// Validates [raw] as a full-file wire path under `@workspaces/` only
  /// (ADR 0022 rules; the fetch built-in never touches external mounts).
  /// Directories are not allowed — the path IS the complete target file.
  static String _validateDownloadPath(String raw) {
    if (raw.trim() != raw) {
      throw ArgumentError(
        'Invalid download_path: leading/trailing whitespace is not allowed: $raw',
      );
    }
    const prefix = '@workspaces/';
    if (!raw.startsWith(prefix)) {
      throw ArgumentError(
        'Invalid download_path: must be a full file path under '
        '@workspaces/ (e.g. @workspaces/reports/q3.pdf). '
        'External mounts are not available to the fetch tool.',
      );
    }
    if (raw.endsWith('/')) {
      throw ArgumentError(
        'Invalid download_path: trailing slash is not allowed '
        '(a full file path is required, not a directory): $raw',
      );
    }
    if (raw.contains('\\')) {
      throw ArgumentError(
        'Invalid download_path: backslashes are not allowed; '
        'use forward slashes: $raw',
      );
    }
    for (final seg in raw.substring(prefix.length).split('/')) {
      if (!isSafeWireSegment(seg)) {
        throw ArgumentError('Invalid download_path: unsafe path segment: $raw');
      }
      if (seg.contains(':') || seg.contains('\u0000')) {
        throw ArgumentError(
          'Invalid download_path: segment contains invalid characters: $raw',
        );
      }
      if (seg.startsWith('.')) {
        // Dot-prefixed segments (e.g. `.fetch_cache/`, `.git/`, `.hidden/`)
        // are excluded from backup/sync and invisible to glob/grep — the
        // opposite of a permanent download target: the confirmation's own
        // browsing advice would silently fail and the file never backs up.
        // Mirrors the trash resolver's dot-segment rule.
        throw ArgumentError(
          'Invalid download_path: dot-prefixed segments are reserved '
          'system paths (e.g. .fetch_cache/); download to a regular '
          'workspace path instead.',
        );
      }
    }
    return raw;
  }

  static int _parseInteger(
    Object? value, {
    required String name,
    required int defaultValue,
  }) {
    if (value == null) return defaultValue;
    if (value is int) return value;
    if (value is num && value.isFinite && value == value.roundToDouble()) {
      return value.toInt();
    }
    throw ArgumentError('Invalid $name: expected an integer');
  }
}

class BuiltInWebFetchResult {
  final String url;
  final String? title;
  final String? content;
  final bool raw;
  final String? cachePath;
  final String? downloadPath;
  final int? downloadedBytes;
  final String? note;

  const BuiltInWebFetchResult({
    required this.url,
    this.title,
    this.content,
    this.raw = false,
    this.cachePath,
    this.downloadPath,
    this.downloadedBytes,
    this.note,
  });

  bool get isDownload => downloadPath != null;
}

class BuiltInWebFetchException implements Exception {
  final String message;

  const BuiltInWebFetchException(this.message);

  @override
  String toString() => message;
}

class BuiltInWebFetchService {
  static const _defaultUA =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  /// `.fetch_cache/` eviction budget (512 MB) and TTL (7 days), per CONTEXT.md
  /// "Fetch temp storage". Mutable statics only so tests can shrink them;
  /// production values are fixed, no settings.
  @visibleForTesting
  static int cacheBudgetBytes = 512 * 1024 * 1024;
  @visibleForTesting
  static Duration cacheTtl = const Duration(days: 7);

  /// A `.part`/`.bak` file whose mtime is older than this is crashed, not
  /// in-flight, so the budget pass may evict it. Heuristic, not a guarantee:
  /// `IOSink` buffers, so a slow trickle download (< buffer size between
  /// long gaps, each resetting the 60 s chunk timeout) keeps a stale mtime
  /// past the grace and can be budget-evicted mid-transfer — on POSIX that
  /// orphans the write and the install fails gracefully with an error, on
  /// Windows the delete fails harmlessly (open handle). Grace = 60× the
  /// chunk timeout for normal transfers. Mutable only so tests can shrink it.
  @visibleForTesting
  static Duration partGracePeriod = const Duration(hours: 1);

  /// Overflow text is only saved when its UTF-8 size fits `kelivo_read`'s
  /// read window — otherwise the model could never read the file back
  /// (single source of truth: the filesystem server's boundary). Mutable only
  /// so tests can shrink it.
  @visibleForTesting
  static int maxReadableTextBytes =
      KelivoFilesystemMcpServerEngine.readWindowBytes;

  /// Per-chunk inactivity timeout for download streams. A moving download
  /// never trips it; a stalled peer fails instead of hanging the tool call.
  /// Mutable only so tests can shrink it.
  @visibleForTesting
  static Duration downloadChunkTimeout = const Duration(minutes: 1);

  /// Timeout for the TCP connect + response-header phase of a download.
  /// `client.send` is otherwise unbounded (a blackholed connection never
  /// produces a chunk, so the chunk timeout can't fire). Mutable only so
  /// tests can shrink it.
  @visibleForTesting
  static Duration downloadResponseTimeout = const Duration(seconds: 30);

  /// Total-duration timeout for TEXT mode (`http.get` covers connect,
  /// headers and body in one unbounded future). Bounds what would otherwise
  /// hang indefinitely — a blackholed page must fail fast for the model.
  /// Mutable only so tests can shrink it.
  @visibleForTesting
  static Duration textFetchTimeout = const Duration(seconds: 60);

  static Map<String, String> _mergedHeaders(BuiltInWebFetchRequest payload) =>
      <String, String>{'User-Agent': _defaultUA, ...payload.headers};

  static Future<BuiltInWebFetchResult> fetch(
    BuiltInWebFetchRequest payload, {
    Future<Directory> Function()? workspacesDirProvider,
    Duration? timeout,
  }) async {
    final downloadPath = payload.downloadPath;
    if (downloadPath != null) {
      // Download mode: bytes saved as-is; max_length/start_index/raw ignored.
      return _download(payload, downloadPath, workspacesDirProvider);
    }
    try {
      final readable = await ReadableWebFetchService.fetch(
        url: payload.url,
        headers: _mergedHeaders(payload),
        raw: payload.raw,
        timeout: timeout ?? textFetchTimeout,
      );
      final text = readable.content;
      String? cachePath;
      String? note;
      if (payload.startIndex == 0 && text.length > payload.maxLength) {
        // Over-length on the first call: store the FULL converted content so
        // the model can read it in one kelivo_read call. Deterministic name,
        // no reuse — every call re-fetches and overwrites (CONTEXT.md).
        final byteLen = utf8.encode(text).length;
        if (byteLen > maxReadableTextBytes) {
          note =
              'Content too large to save as text ($byteLen bytes exceeds '
              'kelivo_read\'s ${maxReadableTextBytes ~/ (1024 * 1024)} MB '
              'window). Re-call web_fetch with download_path set to save it '
              'as-is.';
        } else {
          cachePath = await _saveOverflowText(
            payload,
            text,
            isMarkdown: !payload.raw && readable.isMarkdown,
            workspacesDirProvider: workspacesDirProvider,
          );
        }
      }
      return BuiltInWebFetchResult(
        url: readable.url,
        title: readable.title,
        content: text,
        raw: payload.raw,
        cachePath: cachePath,
        note: note,
      );
    } on UnsupportedReadableContentException catch (e) {
      throw BuiltInWebFetchException(
        'Possible binary content detected. $e If the payload is a file '
        '(image, PDF, archive, ...), re-call '
        'web_fetch with download_path set (e.g. download_path: '
        '"@workspaces/download.bin") to save it as-is.',
      );
    } catch (e) {
      if (e is BuiltInWebFetchException) rethrow;
      throw BuiltInWebFetchException(e.toString());
    }
  }

  /// Downloads [payload] to [downloadPath] (a validated `@workspaces/...`
  /// full file path). Streams to a unique `.part` file inside
  /// `.fetch_cache/`, then renames onto the target. Existing targets are
  /// replaced atomically via a backup name with rollback (a failed rename
  /// restores the previous file). A crash leaves only a `.part` inside the
  /// cache dir, aged out by the TTL pass. Never buffers the body in memory.
  static Future<BuiltInWebFetchResult> _download(
    BuiltInWebFetchRequest payload,
    String downloadPath,
    Future<Directory> Function()? workspacesDirProvider,
  ) async {
    final Directory ws;
    try {
      ws = await _resolveWorkspaces(workspacesDirProvider);
    } catch (e) {
      debugPrint('[web_fetch] @workspaces sandbox unavailable: $e');
      throw BuiltInWebFetchException(
        'Failed to resolve the @workspaces sandbox: '
        '${e is Exception ? e.toString() : 'Unknown error'}',
      );
    }
    final rel = downloadPath.substring('@workspaces/'.length);
    final target = File(p.join(ws.path, rel));
    final cacheDir = Directory(p.join(ws.path, '.fetch_cache'));
    // Fail fast: a directory at the target path must never be replaced by a
    // file (schema: download_path is a full file path, not a directory).
    if (await Directory(target.path).exists()) {
      throw BuiltInWebFetchException(
        'Invalid download_path: a directory already exists at $downloadPath. '
        'download_path must be a full file path, not a directory.',
      );
    }
    final tmp = File(
      p.join(
        cacheDir.path,
        '${_cacheKey(payload)}_${DateTime.now().microsecondsSinceEpoch}.part',
      ),
    );
    // Byte-exact transfer: the default client auto-decompresses gzip and adds
    // Accept-Encoding: gzip, which would silently change the saved bytes and
    // the reported size. Download mode saves the wire bytes as-is. The raw
    // client is held so timeouts can force-close the socket (a non-force
    // close leaves blackholed connections alive until the OS TCP timeout).
    // Redirects are followed manually so every hop is SSRF-revalidated.
    final rawClient = HttpClient()..autoUncompress = false;
    final client = IOClient(rawClient);
    var size = 0;
    try {
      await cacheDir.create(recursive: true);
      final resp = await _sendWithRedirectGuard(
        client,
        payload,
        downloadResponseTimeout,
      );
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw Exception('HTTP ${resp.statusCode}');
      }
      // The IOSink buffers; its first I/O error surfaces at flush()/close().
      // A partial file must never be installed or reported as a success —
      // any write failure aborts the download.
      final sink = tmp.openWrite();
      var sinkFailed = false;
      try {
        try {
          await for (final chunk in resp.stream.timeout(downloadChunkTimeout)) {
            sink.add(chunk);
            size += chunk.length;
          }
          await sink.flush();
        } finally {
          try {
            await sink.close();
          } catch (e) {
            sinkFailed = true;
            debugPrint('[web_fetch] closing download sink failed: $e');
          }
        }
      } catch (e) {
        sinkFailed = true;
        rethrow;
      }
      if (sinkFailed) {
        throw Exception('failed to write downloaded bytes to disk');
      }
      await target.parent.create(recursive: true);
      await _install(target, tmp, cacheDir);
      return BuiltInWebFetchResult(
        url: payload.url.toString(),
        downloadPath: downloadPath,
        downloadedBytes: size,
      );
    } catch (e) {
      try {
        if (await tmp.exists()) {
          await tmp.delete();
        }
      } catch (cleanupErr) {
        debugPrint('[web_fetch] failed to clean up $tmp: $cleanupErr');
      }
      throw BuiltInWebFetchException(
        'Failed to download ${payload.url}: '
        '${e is Exception ? e.toString() : 'Unknown error'}',
      );
    } finally {
      // Keep `.fetch_cache/` temp storage under TTL/budget (stale `.part`
      // files from crashed downloads and overflow files).
      await _evictCache(cacheDir, justWritten: tmp);
      rawClient.close(force: true);
    }
  }

  /// Sends the download request, following redirects manually so each hop is
  /// re-validated by the SSRF guard before a socket opens. The streamed
  /// response body is drained on redirect hops (the download mode never
  /// buffers non-final bodies). Redirects are capped at
  /// [guard.WebFetchTargetGuard.maxRedirectHops].
  static Future<http.StreamedResponse> _sendWithRedirectGuard(
    http.Client client,
    BuiltInWebFetchRequest payload,
    Duration timeout,
  ) async {
    var current = payload.url;
    for (var hop = 0; hop <= guard.WebFetchTargetGuard.maxRedirectHops; hop++) {
      final reason = await guard.webFetchTargetBlockReason(current);
      if (reason != null) {
        throw Exception(reason);
      }
      final req = http.Request('GET', current)
        ..headers.addAll(_mergedHeaders(payload))
        ..headers['Accept-Encoding'] = 'identity'
        ..followRedirects = false;
      final response = await client.send(req).timeout(timeout);
      if (!_isRedirect(response.statusCode)) return response;
      final location = response.headers['location'];
      await response.stream.drain<void>();
      if (location == null || location.isEmpty) {
        throw Exception('Redirect without a Location header');
      }
      current = current.resolve(location);
    }
    throw Exception('Too many redirects');
  }

  static bool _isRedirect(int statusCode) =>
      statusCode >= 300 && statusCode < 400;

  /// Replaces [target] with the completed [tmp] file. Windows cannot rename
  /// onto an existing path, so the old file is staged to a unique backup
  /// INSIDE `.fetch_cache/` first (same volume, atomic; a crash between the
  /// two renames leaves only a backup that the eviction passes age out). If
  /// the install rename fails, the backup is restored — the previous content
  /// survives, never a delete-then-rename window.
  static Future<void> _install(
    File target,
    File tmp,
    Directory cacheDir,
  ) async {
    if (await Directory(target.path).exists()) {
      throw Exception('a directory already exists at ${target.path}');
    }
    if (!await target.exists()) {
      await tmp.rename(target.path);
      return;
    }
    final backup = File(
      p.join(
        cacheDir.path,
        '${p.basename(target.path)}_${DateTime.now().microsecondsSinceEpoch}.bak',
      ),
    );
    try {
      await target.rename(backup.path);
    } catch (e) {
      // Common cause: a concurrent download to the SAME target already
      // staged/replaced it. The loser's failure is recoverable by retry.
      throw Exception(
        'failed to stage the existing target ${target.path} for overwrite '
        '(a concurrent download may target the same path; retry): $e',
      );
    }
    try {
      await tmp.rename(target.path);
    } catch (e) {
      try {
        await backup.rename(target.path);
      } catch (restoreErr) {
        debugPrint(
          '[web_fetch] failed to restore $target from $backup: $restoreErr',
        );
      }
      rethrow;
    }
    try {
      if (await backup.exists()) {
        await backup.delete();
      }
    } catch (e) {
      debugPrint('[web_fetch] failed to delete backup $backup: $e');
    }
  }

  /// Resolves the `@workspaces` sandbox directory (default:
  /// `AppDirectories.getWorkspacesDirectory`), creating it if missing.
  static Future<Directory> _resolveWorkspaces(
    Future<Directory> Function()? workspacesDirProvider,
  ) async {
    final dir =
        await (workspacesDirProvider ??
            AppDirectories.getWorkspacesDirectory)();
    await dir.create(recursive: true);
    return dir;
  }

  /// Deterministic cache key: sha256 over url + raw flag + sorted headers.
  /// Stable identity per fetch configuration (naming only — no reuse).
  static String _cacheKey(BuiltInWebFetchRequest payload) {
    final headerKeys = payload.headers.keys.toList()..sort();
    final canonical = [
      payload.url.toString(),
      payload.raw ? 'raw' : 'converted',
      for (final k in headerKeys) '$k:${payload.headers[k]}',
    ].join('\u0000');
    return crypto.sha256
        .convert(utf8.encode(canonical))
        .toString()
        .substring(0, 16);
  }

  /// Saves the full converted text of an over-length fetch into
  /// `@workspaces/.fetch_cache/<key>.md|.txt` and runs the eviction pass.
  /// Returns the wire path, or null when the sandbox is unavailable (logged;
  /// the bounded text response still stands — recoverable environment issue).
  static Future<String?> _saveOverflowText(
    BuiltInWebFetchRequest payload,
    String text, {
    required bool isMarkdown,
    required Future<Directory> Function()? workspacesDirProvider,
  }) async {
    final Directory ws;
    try {
      ws = await _resolveWorkspaces(workspacesDirProvider);
    } catch (e) {
      debugPrint(
        '[web_fetch] @workspaces sandbox unavailable, '
        'skipping overflow save: $e',
      );
      return null;
    }
    final name = '${_cacheKey(payload)}.${isMarkdown ? 'md' : 'txt'}';
    final dir = Directory(p.join(ws.path, '.fetch_cache'));
    try {
      await dir.create(recursive: true);
      final file = File(p.join(dir.path, name));
      await file.writeAsString(text);
      await _evictCache(dir, justWritten: file);
      return '@workspaces/.fetch_cache/$name';
    } catch (e) {
      debugPrint('[web_fetch] overflow save failed: $e');
      return null;
    }
  }

  /// `.fetch_cache/` eviction (CONTEXT.md "Fetch temp storage"), run after
  /// every cache-dir write (overflow saves AND download temp files):
  /// 1. TTL pass: delete EVERYTHING (including `.part`/`.bak` files — crashed
  ///    downloads/installs age out) older than [cacheTtl].
  /// 2. Budget pass: delete oldest-first, excluding [justWritten] (the
  ///    current fetch's payload) and ANY file fresher than
  ///    [partGracePeriod] — a fresh file may be an in-flight parallel
  ///    download's temp, an install-phase backup, or another call's just
  ///    saved overflow file; budget eviction only trims files older than the
  ///    grace (the cache may transiently exceed the budget by an hour of
  ///    writes). Older entries are evictable regardless of extension.
  /// Best effort — never errors the caller, all failures logged. Iteration
  /// is async so the app isolate yields between files near the budget.
  static Future<void> _evictCache(
    Directory dir, {
    required File justWritten,
  }) async {
    final expiredBefore = DateTime.now().subtract(cacheTtl);
    final fresherThan = DateTime.now().subtract(partGracePeriod);
    try {
      await for (final ent in dir.list()) {
        if (ent is! File || ent.path == justWritten.path) continue;
        try {
          if (ent.statSync().modified.isBefore(expiredBefore)) {
            await ent.delete();
          }
        } catch (e) {
          debugPrint('[web_fetch] eviction (ttl) failed for ${ent.path}: $e');
        }
      }
      // Precompute (path, mtime, size) per entry: a file that vanishes
      // between list and stat (e.g. a concurrent download's `.part` being
      // renamed onto its target) must skip only ITSELF, not abort the
      // remaining budget eviction. statSync stays on the app isolate, but the
      // 512 MB budget bounds the entry count (typically ≤ ~20–50 files).
      final entries = <({String path, DateTime modified, int size})>[];
      await for (final ent in dir.list()) {
        if (ent is! File || ent.path == justWritten.path) continue;
        try {
          final stat = ent.statSync();
          entries.add((
            path: ent.path,
            modified: stat.modified,
            size: stat.size,
          ));
        } catch (e) {
          debugPrint('[web_fetch] eviction (stat) skipped ${ent.path}: $e');
        }
      }
      entries.sort((a, b) => a.modified.compareTo(b.modified));
      var total = entries.fold<int>(0, (sum, e) => sum + e.size);
      for (final e in entries) {
        if (total <= cacheBudgetBytes) break;
        if (!e.modified.isBefore(fresherThan)) {
          continue;
        }
        try {
          await File(e.path).delete();
          total -= e.size;
        } catch (err) {
          debugPrint(
            '[web_fetch] eviction (budget) failed for ${e.path}: $err',
          );
        }
      }
    } catch (e) {
      debugPrint('[web_fetch] eviction pass failed: $e');
    }
  }
}
