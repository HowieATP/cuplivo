import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:mcp_client/mcp_client.dart' as mcp;
import 'package:path/path.dart' as p;

/// A named root directory bound into the `@kelivo/filesystem` MCP server.
///
/// External mounts are desktop-only and never sync. The built-in `@workspaces`
/// mount is always present (rw) and is the only mount on mobile. See
/// `docs/adr/0019-filesystem-mount-relative-wire-format.md`.
class FilesystemMount {
  final String alias;
  final String path;
  final bool readOnly;

  const FilesystemMount({
    required this.alias,
    required this.path,
    this.readOnly = true,
  });

  String get wireName => '@$alias';

  FilesystemMount copyWith({String? alias, String? path, bool? readOnly}) =>
      FilesystemMount(
        alias: alias ?? this.alias,
        path: path ?? this.path,
        readOnly: readOnly ?? this.readOnly,
      );

  Map<String, dynamic> toJson() => {
    'alias': alias,
    'path': path,
    'readOnly': readOnly,
  };

  factory FilesystemMount.fromJson(Map<String, dynamic> json) =>
      FilesystemMount(
        alias: (json['alias'] as String? ?? '').trim(),
        path: (json['path'] as String? ?? '').trim(),
        readOnly: json['readOnly'] as bool? ?? true,
      );
}

/// Alias validation shared by the mount config UI and the wire-path resolver.
/// Rules: `@[a-z0-9][a-z0-9_-]*`, max 32 chars, `workspaces` reserved.
bool isValidMountAlias(String alias) {
  if (alias.isEmpty || alias.length > 32) return false;
  if (alias == 'workspaces') return false; // reserved built-in
  final first = alias.codeUnitAt(0);
  final lower = first >= 0x61 && first <= 0x7a;
  final digit = first >= 0x30 && first <= 0x39;
  if (!lower && !digit) return false;
  for (var i = 1; i < alias.length; i++) {
    final c = alias.codeUnitAt(i);
    final a = c >= 0x61 && c <= 0x7a;
    final d = c >= 0x30 && c <= 0x39;
    final us = c == 0x5f;
    final hy = c == 0x2d;
    if (!a && !d && !us && !hy) return false;
  }
  return true;
}

/// Validates a single wire-path segment (also used for ZIP entry segments).
///
/// Beyond traversal (`..`), this rejects Win32 normalization hazards: Win32
/// strips trailing dots/spaces from the final path component and treats
/// all-dot names as `..` (`...` == parent), so `.. `, `...`, `.. .` would
/// resolve outside the mount on Windows. Rejected on ALL platforms so wire
/// paths stay portable across devices (a path valid on Linux but rejected on
/// Windows would break marker ids and recorded tool calls).
bool isSafeWireSegment(String seg) {
  if (seg.isEmpty) return false;
  if (seg.endsWith(' ') || seg.endsWith('.')) return false;
  return !RegExp(r'^\.+$').hasMatch(seg);
}

/// A validated mount-relative wire path.
class ResolvedWirePath {
  final FilesystemMount mount;
  final List<String> segments;
  final String wirePath;

  ResolvedWirePath({
    required this.mount,
    required this.segments,
    required this.wirePath,
  });

  bool get isRoot => segments.isEmpty;

  String get hostPath =>
      segments.isEmpty ? mount.path : p.joinAll([mount.path, ...segments]);
}

/// Thrown when a wire path is rejected by the wire-format rules.
class WirePathException implements Exception {
  final String message;
  WirePathException(this.message);

  @override
  String toString() => message;
}

/// Resolves [raw] against [mounts] following the wire format:
/// mount-relative only; absolute paths, `..`, backslashes, empty segments,
/// trailing slashes and unknown aliases are rejected.
ResolvedWirePath resolveWirePath(String raw, List<FilesystemMount> mounts) {
  final trimmed = raw.trim();
  if (trimmed != raw) {
    throw WirePathException(
      'Invalid path: leading/trailing whitespace is not allowed: $raw',
    );
  }
  if (!trimmed.startsWith('@')) {
    throw WirePathException(
      'Invalid path: absolute paths are not allowed. Use a mount-relative '
      'path like @workspaces/notes.md',
    );
  }
  if (trimmed.endsWith('/')) {
    throw WirePathException(
      'Invalid path: trailing slash is not allowed: $raw',
    );
  }
  if (trimmed.contains('\\')) {
    throw WirePathException(
      'Invalid path: backslashes are not allowed; use forward slashes: $raw',
    );
  }
  final parts = trimmed.split('/');
  final alias = parts.first.substring(1);
  if (alias.isEmpty) {
    throw WirePathException('Invalid path: missing mount alias: $raw');
  }
  final mount = mounts.where((m) => m.alias == alias).firstOrNull;
  if (mount == null) {
    throw WirePathException('Unknown mount: @$alias');
  }
  final segments = <String>[];
  for (final seg in parts.skip(1)) {
    if (!isSafeWireSegment(seg)) {
      throw WirePathException('Invalid path: unsafe path segment: $raw');
    }
    if (seg.contains(':') || seg.contains('\u0000')) {
      throw WirePathException(
        'Invalid path: segment contains invalid '
        'characters: $raw',
      );
    }
    segments.add(seg);
  }
  return ResolvedWirePath(mount: mount, segments: segments, wirePath: trimmed);
}

/// @kelivo/filesystem — In-memory MCP server engine and transport (Flutter/Dart)
///
/// Provides token-conscious file tools over mount-relative wire paths.
/// See `docs/adr/0019-filesystem-mount-relative-wire-format.md` and the
/// CONTEXT.md "Filesystem MCP" section.
///
/// The server implements a minimal subset of MCP over JSON-RPC 2.0:
/// initialize, tools/list, tools/call.
class KelivoFilesystemMcpServerEngine {
  KelivoFilesystemMcpServerEngine({
    required this.mountsProvider,
    this.onWorkspaceFileDeleted,
  });

  static const int readCharBudget = 32 * 1024;
  static const int readWindowBytes = 32 * 1024 * 1024;
  static const int binaryProbeBytes = 8 * 1024;
  static const int globResultCap = 500;
  static const int grepResultCap = 100;
  static const int maxZipUncompressedBytes = 4 * 1024 * 1024 * 1024;

  final List<FilesystemMount> Function() mountsProvider;
  final Future<void> Function(String wirePath)? onWorkspaceFileDeleted;

  bool _closed = false;

  Future<dynamic> handleMessage(dynamic message) async {
    if (_closed) return null;
    if (message is List) {
      final out = <dynamic>[];
      for (final m in message) {
        out.add(await _handleSingle(m));
      }
      return out;
    }
    return await _handleSingle(message);
  }

  Future<Map<String, dynamic>> _handleSingle(dynamic raw) async {
    try {
      if (raw is! Map) {
        return _error(null, code: -32600, message: 'Invalid Request');
      }
      final req = raw.cast<String, dynamic>();
      final id = req['id'];
      final method = (req['method'] ?? '').toString();
      final params = (req['params'] is Map)
          ? (req['params'] as Map).cast<String, dynamic>()
          : <String, dynamic>{};

      switch (method) {
        case mcp.McpProtocol.methodInitialize:
          return _ok(
            id,
            result: {
              'serverInfo': {'name': '@kelivo/filesystem', 'version': '1.0.0'},
              'protocolVersion': mcp.McpProtocol.defaultVersion,
              'capabilities': {
                'tools': {'listChanged': false},
              },
            },
          );

        case mcp.McpProtocol.methodListTools:
          return _ok(id, result: {'tools': _toolDefinitions()});

        case mcp.McpProtocol.methodCallTool:
          final name = (params['name'] ?? '').toString();
          final arguments = (params['arguments'] is Map)
              ? (params['arguments'] as Map).cast<String, dynamic>()
              : <String, dynamic>{};
          return _ok(id, result: await _callTool(name, arguments));

        default:
          if (id == null) {
            return _noop();
          }
          return _error(id, code: -32601, message: 'Method not found: $method');
      }
    } catch (e) {
      return _error(null, code: -32603, message: 'Internal error: $e');
    }
  }

  void close() {
    _closed = true;
  }

  // =====================================================================
  // Tool dispatch
  // =====================================================================

  Future<Map<String, dynamic>> _callTool(
    String name,
    Map<String, dynamic> args,
  ) async {
    try {
      switch (name) {
        case 'kelivo_read':
          return await _read(args);
        case 'kelivo_write_file':
          return await _writeFile(args);
        case 'kelivo_patch_file':
          return await _patchFile(args);
        case 'kelivo_delete':
          return await _delete(args);
        case 'kelivo_glob':
          return await _glob(args);
        case 'kelivo_grep':
          return await _grep(args);
        case 'kelivo_mkdir':
          return await _mkdir(args);
        case 'kelivo_move':
          return await _move(args);
        case 'kelivo_zip':
          return await _zip(args);
        case 'kelivo_unzip':
          return await _unzip(args);
        default:
          return _toolErr('Tool not found: $name');
      }
    } on WirePathException catch (e) {
      return _toolErr(e.message);
    } catch (e) {
      return _toolErr(e.toString());
    }
  }

  List<FilesystemMount> _mounts() => mountsProvider();

  ResolvedWirePath _resolve(String raw) => resolveWirePath(raw, _mounts());

  // =====================================================================
  // Tools
  // =====================================================================

  Future<Map<String, dynamic>> _read(Map<String, dynamic> args) async {
    final raw = (args['path'] ?? '').toString();
    if (raw == '/') {
      final buf = StringBuffer();
      for (final m in _mounts()) {
        buf.writeln('${m.wireName} (${m.readOnly ? 'ro' : 'rw'}) ${m.path}');
      }
      return _toolOk(buf.toString().trim());
    }
    final resolved = _resolve(raw);
    final fsPath = resolved.hostPath;
    if (await File(fsPath).exists()) {
      final startLine = _argInt(args['start_line'], name: 'start_line') ?? 1;
      if (startLine < 1) {
        return _toolErr('Invalid start_line: expected a value >= 1');
      }
      return await _readFile(resolved, startLine);
    }
    if (await Directory(fsPath).exists()) {
      return await _listDirectory(resolved);
    }
    return _toolErr('Not found: $raw');
  }

  Future<Map<String, dynamic>> _readFile(
    ResolvedWirePath resolved,
    int startLine,
  ) async {
    final file = File(resolved.hostPath);
    final raf = await file.open();
    try {
      final stat = await file.stat();
      if (stat.size > readWindowBytes) {
        return _toolErr(
          'File too large to read (${stat.size} bytes > '
          '${readWindowBytes ~/ (1024 * 1024)} MB): ${resolved.wirePath}',
        );
      }
      final window = await raf.read(stat.size);
      if (_looksBinary(window)) {
        return _toolErr(
          'Binary file — cannot read as text: ${resolved.wirePath}',
        );
      }
      final text = utf8.decode(window, allowMalformed: true);
      final lines = text.split('\n');
      if (startLine > lines.length) {
        return _toolErr(
          'Invalid start_line=$startLine: file has only ${lines.length} lines',
        );
      }
      final buf = StringBuffer();
      var chars = 0;
      var lineNo = startLine;
      while (lineNo <= lines.length) {
        final content = lines[lineNo - 1];
        final entry = '$lineNo: $content\n';
        if (chars + entry.length > readCharBudget && buf.isNotEmpty) {
          break;
        }
        buf.write(entry);
        chars += entry.length;
        lineNo++;
      }
      var out = buf.toString();
      final truncated = lineNo <= lines.length;
      if (truncated) {
        out =
            '$out\n[Content truncated: showing lines $startLine-${lineNo - 1} '
            'of ${lines.length}. Call kelivo_read with '
            'start_line=$lineNo to continue.]';
      }
      return _toolOk(out);
    } finally {
      await raf.close();
    }
  }

  Future<Map<String, dynamic>> _listDirectory(ResolvedWirePath resolved) async {
    final dir = Directory(resolved.hostPath);
    // followLinks: false — symlinks are never followed in scans; Link
    // entries fall through to the name-only branch below.
    final children = await dir.list(followLinks: false).toList();
    children.sort((a, b) {
      final aDir = a is Directory;
      final bDir = b is Directory;
      if (aDir != bDir) return aDir ? -1 : 1;
      return p
          .basename(a.path)
          .toLowerCase()
          .compareTo(p.basename(b.path).toLowerCase());
    });
    final buf = StringBuffer();
    buf.writeln('${resolved.wirePath} (${children.length} entries):');
    for (final c in children) {
      final name = p.basename(c.path);
      if (c is Directory) {
        buf.writeln('$name/');
      } else if (c is File) {
        try {
          final size = await c.length();
          buf.writeln('$name ($size bytes)');
        } catch (_) {
          buf.writeln(name);
        }
      } else {
        buf.writeln(name);
      }
    }
    return _toolOk(buf.toString().trim());
  }

  Future<Map<String, dynamic>> _writeFile(Map<String, dynamic> args) async {
    final resolved = _resolve((args['path'] ?? '').toString());
    _requireWritable(resolved);
    final content = (args['content'] ?? '').toString();
    final file = File(resolved.hostPath);
    await file.parent.create(recursive: true);
    await file.writeAsString(content, flush: true);
    return _toolOk(
      'Wrote ${utf8.encode(content).length} bytes to ${resolved.wirePath}',
    );
  }

  Future<Map<String, dynamic>> _patchFile(Map<String, dynamic> args) async {
    final resolved = _resolve((args['path'] ?? '').toString());
    _requireWritable(resolved);
    final oldString = (args['old_string'] ?? '').toString();
    final newString = (args['new_string'] ?? '').toString();
    if (oldString.isEmpty) {
      return _toolErr('Invalid old_string: must not be empty');
    }
    final file = File(resolved.hostPath);
    if (!await file.exists()) {
      return _toolErr('Not found: ${resolved.wirePath}');
    }
    final original = await file.readAsString();
    final idx = original.indexOf(oldString);
    if (idx < 0) {
      return _toolErr('old_string not found in ${resolved.wirePath}');
    }
    final patched =
        original.substring(0, idx) +
        newString +
        original.substring(idx + oldString.length);
    await file.writeAsString(patched, flush: true);
    return _toolOk('Patched ${resolved.wirePath} (replaced 1 occurrence)');
  }

  Future<Map<String, dynamic>> _delete(Map<String, dynamic> args) async {
    final resolved = _resolve((args['path'] ?? '').toString());
    if (resolved.isRoot) {
      return _toolErr('Cannot delete mount root: ${resolved.wirePath}');
    }
    _requireWritable(resolved);
    final recursive = (args['recursive'] as bool?) ?? false;
    final fsPath = resolved.hostPath;
    if (await File(fsPath).exists()) {
      await File(fsPath).delete();
    } else if (await Directory(fsPath).exists()) {
      final dir = Directory(fsPath);
      final children = await dir.list().toList();
      if (children.isNotEmpty && !recursive) {
        return _toolErr(
          'Directory not empty: ${resolved.wirePath}. Set recursive=true to '
          'delete it with its contents',
        );
      }
      await dir.delete(recursive: recursive);
    } else {
      return _toolErr('Not found: ${resolved.wirePath}');
    }
    await _recordDeletionIfWorkspaces(resolved);
    return _toolOk('Deleted ${resolved.wirePath}');
  }

  Future<Map<String, dynamic>> _glob(Map<String, dynamic> args) async {
    final resolved = _resolve((args['path'] ?? '').toString());
    final pattern = (args['pattern'] ?? '').toString();
    if (pattern.isEmpty) {
      return _toolErr('Invalid pattern: must not be empty');
    }
    final dir = Directory(resolved.hostPath);
    if (!await dir.exists()) {
      return _toolErr('Not found: ${resolved.wirePath}');
    }
    final regex = _globToRegex(pattern);
    final dotTargets = pattern.startsWith('.');
    final results = <String>[];
    await _walk(dir, (entry, rel) async {
      if (results.length >= globResultCap) return;
      if (!dotTargets && rel.split('/').any((s) => s.startsWith('.'))) return;
      if (regex.hasMatch(rel)) {
        results.add('${resolved.wirePath}/$rel');
      }
    });
    if (results.length >= globResultCap) {
      results.add('... (cap $globResultCap results reached)');
    }
    return _toolOk(results.isEmpty ? 'No matches' : results.join('\n'));
  }

  Future<Map<String, dynamic>> _grep(Map<String, dynamic> args) async {
    final resolved = _resolve((args['path'] ?? '').toString());
    final regexRaw = (args['regex'] ?? '').toString();
    if (regexRaw.isEmpty) {
      return _toolErr('Invalid regex: must not be empty');
    }
    RegExp regex;
    try {
      regex = RegExp(
        regexRaw,
        caseSensitive: !((args['ignore_case'] as bool?) ?? false),
      );
    } catch (e) {
      return _toolErr('Invalid regex: $e');
    }
    final dir = Directory(resolved.hostPath);
    if (!await dir.exists()) {
      return _toolErr('Not found: ${resolved.wirePath}');
    }
    final results = <String>[];
    await _walk(dir, (entry, rel) async {
      if (results.length >= grepResultCap) return;
      if (rel.split('/').any((s) => s.startsWith('.'))) return;
      if (entry is! File) return;
      try {
        final raf = await entry.open();
        try {
          final stat = await entry.stat();
          if (stat.size == 0 || stat.size > readWindowBytes) return;
          final bytes = await raf.read(stat.size);
          if (_looksBinary(bytes)) return;
          final lines = utf8.decode(bytes, allowMalformed: true).split('\n');
          for (var i = 0; i < lines.length; i++) {
            if (results.length >= grepResultCap) break;
            final line = lines[i];
            if (regex.hasMatch(line)) {
              final shown = line.length > 200 ? line.substring(0, 200) : line;
              results.add('${resolved.wirePath}/$rel:${i + 1}: $shown');
            }
          }
        } finally {
          await raf.close();
        }
      } catch (_) {
        // unreadable file — skip
      }
    });
    if (results.length >= grepResultCap) {
      results.add('... (cap $grepResultCap results reached)');
    }
    return _toolOk(results.isEmpty ? 'No matches' : results.join('\n'));
  }

  Future<Map<String, dynamic>> _mkdir(Map<String, dynamic> args) async {
    final resolved = _resolve((args['path'] ?? '').toString());
    if (resolved.isRoot) {
      return _toolErr('Cannot mkdir mount root: ${resolved.wirePath}');
    }
    _requireWritable(resolved);
    final recursive = (args['recursive'] as bool?) ?? false;
    final dir = Directory(resolved.hostPath);
    if (await dir.exists()) {
      return _toolErr('Already exists: ${resolved.wirePath}');
    }
    if (!recursive) {
      final parent = dir.parent;
      if (!await parent.exists()) {
        return _toolErr(
          'Parent directory does not exist: set recursive=true to create '
          'intermediate directories',
        );
      }
    }
    await dir.create(recursive: recursive);
    return _toolOk('Created directory ${resolved.wirePath}');
  }

  Future<Map<String, dynamic>> _move(Map<String, dynamic> args) async {
    final source = _resolve((args['source'] ?? '').toString());
    final dest = _resolve((args['destination'] ?? '').toString());
    if (source.isRoot) {
      return _toolErr('Cannot move mount root: ${source.wirePath}');
    }
    if (dest.isRoot) {
      return _toolErr('Cannot move to mount root: ${dest.wirePath}');
    }
    // A move both deletes the source and writes the destination — a read-only
    // mount blocks either side.
    _requireWritable(source);
    _requireWritable(dest);
    if (!await File(source.hostPath).exists() &&
        !await Directory(source.hostPath).exists()) {
      return _toolErr('Not found: ${source.wirePath}');
    }
    if (await File(dest.hostPath).exists() ||
        await Directory(dest.hostPath).exists()) {
      return _toolErr(
        'Destination already exists — no silent overwrite: ${dest.wirePath}',
      );
    }
    final sameMount = source.mount.alias == dest.mount.alias;
    final destUnderWorkspaces = dest.mount.alias == 'workspaces';
    final srcMtime = await _lastModified(source.hostPath);
    var fullyMoved = false;
    try {
      if (sameMount) {
        await Directory(dest.hostPath).parent.create(recursive: true);
        if (await File(source.hostPath).exists()) {
          await File(source.hostPath).rename(dest.hostPath);
        } else {
          await Directory(source.hostPath).rename(dest.hostPath);
        }
        fullyMoved = true;
      } else {
        // Cross-mount: copy, then tombstone-rename the source (atomic, same
        // volume), then best-effort delete the tombstone. This avoids the
        // partial-delete data-loss window: the original survives under the
        // tombstone name until it is fully removable.
        try {
          await _copyRecursive(source.hostPath, dest.hostPath);
        } catch (e) {
          // Source untouched — a partial destination is garbage.
          await _removeRecursive(dest.hostPath);
          return _toolErr('Move failed: $e');
        }
        final tombstone = '${source.hostPath}.kelivo_move_tmp';
        try {
          if (await File(source.hostPath).exists()) {
            await File(source.hostPath).rename(tombstone);
          } else {
            await Directory(source.hostPath).rename(tombstone);
          }
        } catch (e) {
          // Source intact, destination complete — roll the destination back.
          await _removeRecursive(dest.hostPath);
          return _toolErr('Move failed: $e');
        }
        try {
          await _removeRecursive(tombstone);
        } catch (e) {
          return _toolErr(
            'Moved to ${dest.wirePath} but could not remove the source: '
            'original data preserved at $tombstone. Retry or remove it '
            'manually.',
          );
        }
        fullyMoved = true;
      }
    } catch (e) {
      return _toolErr('Move failed: $e');
    }
    if (fullyMoved) {
      if (destUnderWorkspaces) {
        await _setMtime(dest.hostPath, DateTime.now());
        await _bumpTreeMtimes(dest.hostPath);
      } else if (srcMtime != null) {
        await _setMtime(dest.hostPath, srcMtime);
      }
      await _recordDeletionIfWorkspaces(source);
    }
    return _toolOk('Moved ${source.wirePath} -> ${dest.wirePath}');
  }

  Future<Map<String, dynamic>> _zip(Map<String, dynamic> args) async {
    final source = _resolve((args['source'] ?? '').toString());
    final dest = _resolve((args['destination'] ?? '').toString());
    if (source.isRoot) {
      return _toolErr('Cannot zip mount root: ${source.wirePath}');
    }
    if (dest.isRoot) {
      return _toolErr('Cannot zip to mount root: ${dest.wirePath}');
    }
    _requireWritable(dest);
    if (await File(dest.hostPath).exists() ||
        await Directory(dest.hostPath).exists()) {
      return _toolErr(
        'Destination already exists — no silent overwrite: ${dest.wirePath}',
      );
    }
    var totalBytes = 0;
    var fileCount = 0;
    final entries = <({File file, String name})>[];
    if (await File(source.hostPath).exists()) {
      final size = await File(source.hostPath).length();
      totalBytes += size;
      entries.add((
        file: File(source.hostPath),
        name: p.basename(source.hostPath),
      ));
      fileCount = 1;
    } else if (await Directory(source.hostPath).exists()) {
      final root = Directory(source.hostPath);
      // followLinks: false — symlinks are skipped, never packed.
      await for (final ent in root.list(recursive: true, followLinks: false)) {
        if (ent is File) {
          final rel = p
              .relative(ent.path, from: root.path)
              .replaceAll('\\', '/');
          totalBytes += await ent.length();
          entries.add((file: ent, name: rel));
          fileCount++;
        }
      }
    } else {
      return _toolErr('Not found: ${source.wirePath}');
    }
    if (totalBytes > maxZipUncompressedBytes) {
      return _toolErr(
        'Zip too large: $totalBytes uncompressed bytes exceeds the '
        '4 GB cap',
      );
    }
    await Directory(dest.hostPath).parent.create(recursive: true);
    final encoder = ZipFileEncoder();
    try {
      encoder.create(dest.hostPath);
      for (final e in entries) {
        encoder.addFileSync(e.file, e.name);
      }
      encoder.closeSync();
    } catch (e) {
      try {
        await File(dest.hostPath).delete();
      } catch (_) {}
      return _toolErr('Zip failed: $e');
    }
    return _toolOk(
      'Zipped $fileCount files ($totalBytes bytes) to '
      '${dest.wirePath}',
    );
  }

  Future<Map<String, dynamic>> _unzip(Map<String, dynamic> args) async {
    final source = _resolve((args['source'] ?? '').toString());
    final dest = _resolve((args['destination'] ?? '').toString());
    if (dest.isRoot) {
      return _toolErr('Cannot unzip to mount root: ${dest.wirePath}');
    }
    _requireWritable(dest);
    final zipFile = File(source.hostPath);
    if (!await zipFile.exists()) {
      return _toolErr('Not found: ${source.wirePath}');
    }
    final destDir = Directory(dest.hostPath);
    if (await destDir.exists()) {
      return _toolErr(
        'Destination already exists — no silent overwrite: ${dest.wirePath}',
      );
    }

    // Pass 1: pre-scan entries — zip-slip check + size cap + overwrite check.
    final planned = <({String name, List<String> parts, int size})>[];
    var totalBytes = 0;
    try {
      final input1 = InputFileStream(zipFile.path);
      try {
        final archive = ZipDecoder().decodeStream(input1);
        for (final entry in archive) {
          if (!entry.isFile) continue;
          final normalized = entry.name.replaceAll('\\', '/');
          if (normalized.startsWith('/') || _hasDrivePrefix(normalized)) {
            return _toolErr('Unsafe zip entry (absolute path): ${entry.name}');
          }
          final parts = normalized
              .split('/')
              .where((s) => s.isNotEmpty && s != '.')
              .toList();
          // Same segment rule as wire paths: covers `..` AND Win32
          // normalization hazards (`.. `, `...`, trailing dots/spaces).
          if (parts.any((s) => !isSafeWireSegment(s))) {
            return _toolErr('Unsafe zip entry (path traversal): ${entry.name}');
          }
          if (parts.isEmpty) continue;
          totalBytes += entry.size;
          if (totalBytes > maxZipUncompressedBytes) {
            return _toolErr(
              'Zip too large: uncompressed size exceeds the 4 GB cap',
            );
          }
          planned.add((name: normalized, parts: parts, size: entry.size));
        }
      } finally {
        input1.close();
      }
      for (final e in planned) {
        final target = p.joinAll([destDir.path, ...e.parts]);
        if (await File(target).exists() || await Directory(target).exists()) {
          return _toolErr(
            'Destination entry already exists — no silent overwrite: '
            '${e.name}',
          );
        }
      }
    } catch (e) {
      if (e.toString().contains('Unsafe zip entry') ||
          e.toString().contains('Zip too large') ||
          e.toString().contains('already exists')) {
        rethrow;
      }
      return _toolErr('Failed to read zip: $e');
    }

    // Pass 2: extract.
    await destDir.create(recursive: true);
    try {
      final input2 = InputFileStream(zipFile.path);
      try {
        final archive = ZipDecoder().decodeStream(input2);
        for (final entry in archive) {
          if (!entry.isFile) continue;
          final normalized = entry.name.replaceAll('\\', '/');
          final parts = normalized
              .split('/')
              .where((s) => s.isNotEmpty && s != '.')
              .toList();
          if (parts.isEmpty) continue;
          final target = p.joinAll([destDir.path, ...parts]);
          final output = OutputFileStream(target);
          try {
            entry.writeContent(output);
          } finally {
            output.closeSync();
          }
          final mtime = _decodeDosDateTime(entry.lastModTime);
          if (mtime != null) {
            try {
              await File(target).setLastModified(mtime);
            } catch (_) {}
          }
        }
      } finally {
        input2.close();
      }
      // Restored entry mtimes would make the new content invisible to
      // since-filtered backups — protocol rule: everything entering
      // @workspaces gets mtime=now.
      if (dest.mount.alias == 'workspaces') {
        await _bumpTreeMtimes(destDir.path);
      }
    } catch (e) {
      return _toolErr('Extraction failed: $e');
    }
    return _toolOk(
      'Extracted ${planned.length} files ($totalBytes bytes) to '
      '${dest.wirePath}',
    );
  }

  // =====================================================================
  // Helpers
  // =====================================================================

  void _requireWritable(ResolvedWirePath resolved) {
    if (resolved.mount.readOnly) {
      throw WirePathException('Mount @${resolved.mount.alias} is read-only');
    }
  }

  Future<void> _recordDeletionIfWorkspaces(ResolvedWirePath resolved) async {
    // Dot-prefixed entries (e.g. .fetch_cache/) never sync, so their markers
    // would be meaningless noise on peers — one dotfile rule, both planes
    // (content and markers). See ADR-0018.
    if (resolved.mount.alias == 'workspaces' &&
        !resolved.segments.any((s) => s.startsWith('.'))) {
      final cb = onWorkspaceFileDeleted;
      if (cb != null) {
        try {
          await cb(resolved.wirePath);
        } catch (e) {
          // Marker protocol is advisory (ADR-0018): a marker failure must
          // not fail the deletion itself, but it must be visible in logs.
          // ignore: avoid_print
          print('kelivo_filesystem: failed to record deletion marker: $e');
        }
      }
    }
  }

  bool _looksBinary(Uint8List bytes) {
    final n = math.min(bytes.length, binaryProbeBytes);
    for (var i = 0; i < n; i++) {
      if (bytes[i] == 0) return true;
    }
    return false;
  }

  Future<DateTime?> _lastModified(String path) async {
    try {
      final fileStat = await File(path).stat();
      return fileStat.modified;
    } catch (_) {}
    try {
      final dirStat = await Directory(path).stat();
      return dirStat.modified;
    } catch (_) {}
    return null;
  }

  Future<void> _setMtime(String path, DateTime mtime) async {
    try {
      await File(path).setLastModified(mtime);
    } catch (_) {
      // Directory mtimes are not settable through dart:io on all platforms;
      // moving a directory into @workspaces keeps its mtime — incremental
      // backup picks it up via the mtime of its contents, which is set
      // during the copy itself.
    }
  }

  /// Recursively sets mtime=now on every file under [path] (followLinks:
  /// false — symlinks are never followed in scans). Used after content
  /// enters @workspaces via move or unzip: the per-file mtime filter of
  /// incremental backups / LAN sync must see the new paths, otherwise the
  /// source path gets a deletion marker while the new content never
  /// arrives (protocol rule "mtime=now for workspaces").
  Future<void> _bumpTreeMtimes(String path) async {
    final d = Directory(path);
    if (!await d.exists()) return;
    await for (final ent in d.list(recursive: true, followLinks: false)) {
      if (ent is File) {
        try {
          await ent.setLastModified(DateTime.now());
        } catch (_) {}
      }
    }
  }

  Future<void> _copyRecursive(String src, String dst) async {
    await Directory(p.dirname(dst)).create(recursive: true);
    final srcFile = File(src);
    if (await srcFile.exists()) {
      await srcFile.copy(dst);
      return;
    }
    final srcDir = Directory(src);
    if (!await srcDir.exists()) {
      throw FileSystemException('Not found: $src');
    }
    await Directory(dst).create(recursive: true);
    // followLinks: false — symlinks are skipped, never copied.
    await for (final ent in srcDir.list(followLinks: false)) {
      final target = p.join(dst, p.basename(ent.path));
      if (ent is Directory) {
        await _copyRecursive(ent.path, target);
      } else if (ent is File) {
        await ent.copy(target);
      }
    }
  }

  Future<void> _removeRecursive(String path) async {
    final f = File(path);
    if (await f.exists()) {
      await f.delete();
      return;
    }
    final d = Directory(path);
    if (await d.exists()) {
      await d.delete(recursive: true);
    }
  }

  /// Walks [dir] depth-first. Symlinks are never followed (followLinks:
  /// false — repo policy; cycle-proof and keeps recursive scans inside the
  /// mount boundary; Link entries are simply skipped).
  Future<void> _walk(
    Directory dir,
    Future<void> Function(FileSystemEntity entry, String rel) onEntry,
  ) async {
    await for (final ent in dir.list(followLinks: false)) {
      final rel = p.basename(ent.path);
      if (ent is Directory) {
        await onEntry(ent, rel);
        await _walk(ent, (child, childRel) {
          return onEntry(child, '$rel/$childRel');
        });
      } else if (ent is File) {
        await onEntry(ent, rel);
      }
    }
  }

  int? _argInt(Object? value, {required String name}) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num && value.isFinite && value == value.roundToDouble()) {
      return value.toInt();
    }
    return null;
  }

  static bool _hasDrivePrefix(String normalized) {
    if (normalized.length < 2) return false;
    final c0 = normalized.codeUnitAt(0);
    final isLetter = (c0 >= 0x41 && c0 <= 0x5a) || (c0 >= 0x61 && c0 <= 0x7a);
    return isLetter && normalized[1] == ':';
  }

  /// Decode a DOS date/time packed value (from ZIP entry's lastModTime) into
  /// a [DateTime]. Returns null when the date portion is zero (unset).
  static DateTime? _decodeDosDateTime(int packed) {
    final dosDate = packed >> 16;
    final dosTime = packed & 0xFFFF;
    if (dosDate == 0) return null;
    final year = ((dosDate >> 9) & 0x7f) + 1980;
    final month = (dosDate >> 5) & 0x0f;
    final day = dosDate & 0x1f;
    final hour = (dosTime >> 11) & 0x1f;
    final minute = (dosTime >> 5) & 0x3f;
    final second = (dosTime & 0x1f) * 2;
    try {
      return DateTime(year, month, day, hour, minute, second);
    } catch (_) {
      return null;
    }
  }

  /// Converts a glob pattern (supporting `**`, `*`, `?`, `[...]`) to a RegExp.
  static RegExp _globToRegex(String glob) {
    final sb = StringBuffer();
    var i = 0;
    while (i < glob.length) {
      final c = glob[i];
      if (c == '*') {
        if (i + 1 < glob.length && glob[i + 1] == '*') {
          sb.write('.*');
          i += 2;
          if (i < glob.length && glob[i] == '/') {
            sb.write('/?');
            i++;
          }
          continue;
        }
        sb.write('[^/]*');
      } else if (c == '?') {
        sb.write('[^/]');
      } else if (c == '[') {
        final end = glob.indexOf(']', i + 1);
        if (end < 0) {
          sb.write(RegExp.escape(c));
        } else {
          var inner = glob.substring(i + 1, end);
          if (inner.startsWith('!')) inner = '^${inner.substring(1)}';
          sb.write('[$inner]');
          i = end;
        }
      } else {
        sb.write(RegExp.escape(c));
      }
      i++;
    }
    return RegExp('^${sb.toString()}\$');
  }

  List<Map<String, dynamic>> _toolDefinitions() {
    return {
      'kelivo_read': {
        'name': 'kelivo_read',
        'description':
            'Read a file, list a directory, or list all mounts. '
            'path="/" lists all mounts. A mount-relative path (e.g. '
            '@workspaces/notes.md) reads a file with line numbers; a path '
            'pointing to a directory lists its entries. Output is capped at '
            '32 KB; continuation hint: call kelivo_read with start_line=N to '
            'continue. Binary files are rejected.',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'path': {
              'type': 'string',
              'description':
                  'Mount-relative path (@alias/rel/path) or "/" to list '
                  'mounts. Absolute paths are rejected.',
            },
            'start_line': {
              'type': 'integer',
              'description': '1-based first line to show (default 1)',
              'minimum': 1,
            },
          },
          'required': ['path'],
        },
      },
      'kelivo_write_file': {
        'name': 'kelivo_write_file',
        'description':
            'Write (create or overwrite) a file. Parent directories are '
            'created automatically. Fails on read-only mounts.',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'path': {
              'type': 'string',
              'description': 'Mount-relative path (@alias/rel/path)',
            },
            'content': {'type': 'string', 'description': 'Full file content'},
          },
          'required': ['path', 'content'],
        },
      },
      'kelivo_patch_file': {
        'name': 'kelivo_patch_file',
        'description':
            'Replace the first occurrence of old_string with new_string in a '
            'file. Errors when old_string is not found. Fails on read-only '
            'mounts.',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'path': {
              'type': 'string',
              'description': 'Mount-relative path (@alias/rel/path)',
            },
            'old_string': {'type': 'string', 'description': 'Text to replace'},
            'new_string': {'type': 'string', 'description': 'Replacement text'},
          },
          'required': ['path', 'old_string', 'new_string'],
        },
      },
      'kelivo_delete': {
        'name': 'kelivo_delete',
        'description':
            'Delete a file, or a directory (empty, or with recursive=true). '
            'Deleting a mount root is rejected. Deletions inside @workspaces '
            'are recorded and propagate to synced devices as deletion marks '
            '(advisory, never auto-deleted).',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'path': {
              'type': 'string',
              'description': 'Mount-relative path (@alias/rel/path)',
            },
            'recursive': {
              'type': 'boolean',
              'description':
                  'Delete a non-empty directory with its contents '
                  '(default false)',
              'default': false,
            },
          },
          'required': ['path'],
        },
      },
      'kelivo_glob': {
        'name': 'kelivo_glob',
        'description':
            'List files matching a glob pattern under a directory. Dotfiles '
            'and dot-directories are ignored unless the pattern starts with '
            'a dot (ripgrep convention). Results are capped at 500.',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'path': {
              'type': 'string',
              'description': 'Directory, mount-relative (@alias/rel/path)',
            },
            'pattern': {
              'type': 'string',
              'description': 'Relative glob pattern, e.g. "**/*.md" or "*.txt"',
            },
          },
          'required': ['path', 'pattern'],
        },
      },
      'kelivo_grep': {
        'name': 'kelivo_grep',
        'description':
            'Search files under a directory for lines matching a regular '
            'expression. Dotfiles/dot-directories are skipped (ripgrep '
            'convention), binary files are skipped. Results are capped at '
            '100 and returned as "path:line: text".',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'path': {
              'type': 'string',
              'description': 'Directory, mount-relative (@alias/rel/path)',
            },
            'regex': {
              'type': 'string',
              'description':
                  'Regular expression to match against line '
                  'contents',
            },
            'ignore_case': {
              'type': 'boolean',
              'description': 'Case-insensitive matching (default false)',
              'default': false,
            },
          },
          'required': ['path', 'regex'],
        },
      },
      'kelivo_mkdir': {
        'name': 'kelivo_mkdir',
        'description':
            'Create a directory. Without recursive=true the parent must '
            'already exist. Fails on read-only mounts.',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'path': {
              'type': 'string',
              'description': 'Mount-relative path (@alias/rel/path)',
            },
            'recursive': {
              'type': 'boolean',
              'description': 'Create intermediate directories (default false)',
              'default': false,
            },
          },
          'required': ['path'],
        },
      },
      'kelivo_move': {
        'name': 'kelivo_move',
        'description':
            'Move a file or directory to a new location. Cross-mount moves '
            'are allowed. Never overwrites an existing destination. Files '
            'moved into @workspaces get mtime=now so incremental backups '
            'pick them up; the source path records a deletion mark.',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'source': {
              'type': 'string',
              'description': 'Existing file or directory (mount-relative)',
            },
            'destination': {
              'type': 'string',
              'description':
                  'Target path (mount-relative). Must not already exist.',
            },
          },
          'required': ['source', 'destination'],
        },
      },
      'kelivo_zip': {
        'name': 'kelivo_zip',
        'description':
            'Create a ZIP archive of a file or directory. Uncompressed size '
            'is capped at 4 GB. The destination must not exist. Fails on '
            'read-only mounts.',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'source': {
              'type': 'string',
              'description':
                  'File or directory to archive '
                  '(mount-relative)',
            },
            'destination': {
              'type': 'string',
              'description': 'Output .zip path (mount-relative)',
            },
          },
          'required': ['source', 'destination'],
        },
      },
      'kelivo_unzip': {
        'name': 'kelivo_unzip',
        'description':
            'Extract a ZIP archive into a directory. Entries are pre-scanned '
            'for path traversal (zip-slip) and the uncompressed size is '
            'capped at 4 GB. The destination must not exist. Fails on '
            'read-only mounts.',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'source': {
              'type': 'string',
              'description': 'ZIP archive path (mount-relative)',
            },
            'destination': {
              'type': 'string',
              'description': 'Output directory (mount-relative)',
            },
          },
          'required': ['source', 'destination'],
        },
      },
    }.values.toList();
  }

  Map<String, dynamic> _ok(dynamic id, {required Map<String, dynamic> result}) {
    return {'jsonrpc': '2.0', if (id != null) 'id': id, 'result': result};
  }

  Map<String, dynamic> _error(
    dynamic id, {
    required int code,
    required String message,
  }) {
    return {
      'jsonrpc': '2.0',
      if (id != null) 'id': id,
      'error': {'code': code, 'message': message},
    };
  }

  Map<String, dynamic> _noop() => {'jsonrpc': '2.0'};

  static Map<String, dynamic> _toolOk(String text) => {
    'content': [
      {'type': 'text', 'text': text},
    ],
    'isStreaming': false,
    'isError': false,
  };

  static Map<String, dynamic> _toolErr(String message) => {
    'content': [
      {'type': 'text', 'text': message},
    ],
    'isStreaming': false,
    'isError': true,
  };
}

/// In-memory ClientTransport that directly invokes the local server engine.
class KelivoFilesystemInMemoryClientTransport implements mcp.ClientTransport {
  final KelivoFilesystemMcpServerEngine _server;
  final _messageController = StreamController<dynamic>.broadcast();
  final _closeCompleter = Completer<void>();
  bool _closed = false;

  KelivoFilesystemInMemoryClientTransport(this._server);

  @override
  Stream<dynamic> get onMessage => _messageController.stream;

  @override
  Future<void> get onClose => _closeCompleter.future;

  @override
  void send(dynamic message) {
    if (_closed) return;
    Future.microtask(() async {
      final resp = await _server.handleMessage(message);
      if (_closed) return;
      if (resp != null) {
        _messageController.add(resp);
      }
    });
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    try {
      _server.close();
    } catch (_) {}
    if (!_messageController.isClosed) _messageController.close();
    if (!_closeCompleter.isCompleted) _closeCompleter.complete();
  }
}
