import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../../utils/app_directories.dart';
import 'linux_sandbox_path.dart';
import 'sandbox_runtime.dart';

class WindowsLocalJailRuntime implements SandboxRuntime {
  WindowsLocalJailRuntime(this.sandboxId);

  static const Duration defaultShellTimeout = Duration(seconds: 30);
  static const Duration maxShellTimeout = Duration(seconds: 120);
  static const int maxOutputBytes = 256 * 1024;
  static const int maxReadBytes = 1024 * 1024;

  @override
  final String sandboxId;

  @override
  bool get isSupported => true;

  Future<Directory> _root() async {
    final base = await AppDirectories.getLinuxSandboxesDirectory();
    return Directory(p.join(base.path, sandboxId));
  }

  @override
  Future<Directory> rootDirectory() => _root();

  @override
  Future<void> ensureReady() async {
    final root = await _root();
    if (!await root.exists()) {
      await root.create(recursive: true);
    }
  }

  Future<String> _resolve(String guestPath) async {
    final root = await _root();
    return LinuxSandboxPath.resolveHostPath(
      jailRoot: root.path,
      guestPath: guestPath,
    );
  }

  @override
  Future<SandboxToolResult> read(String path) async {
    try {
      await ensureReady();
      final hostPath = await _resolve(path);
      final file = File(hostPath);
      final dir = Directory(hostPath);
      if (await file.exists()) {
        final length = await file.length();
        if (length > maxReadBytes) {
          return SandboxToolResult.failure(
            'file_too_large',
            'File exceeds $maxReadBytes byte read limit: $path',
          );
        }
        final bytes = await file.readAsBytes();
        if (_looksBinary(bytes)) {
          return SandboxToolResult.failure(
            'binary_file',
            'Binary file cannot be read as text: $path',
          );
        }
        return SandboxToolResult.success(
          utf8.decode(bytes, allowMalformed: true),
        );
      }
      if (await dir.exists()) {
        final entries = await listDir(path);
        final buf = StringBuffer();
        for (final e in entries) {
          buf.writeln(e.isDirectory ? '${e.name}/' : e.name);
        }
        return SandboxToolResult.success(buf.toString().trimRight());
      }
      return SandboxToolResult.failure('not_found', 'Not found: $path');
    } on LinuxSandboxPathException catch (e) {
      return SandboxToolResult.failure(e.code, e.message);
    } catch (e) {
      return SandboxToolResult.failure('io_error', e.toString());
    }
  }

  @override
  Future<SandboxToolResult> write(String path, String content) async {
    try {
      await ensureReady();
      final hostPath = await _resolve(path);
      final root = await _root();
      final file = File(hostPath);
      final parent = file.parent;
      if (!LinuxSandboxPath.isUnderRoot(root.path, parent.path)) {
        return SandboxToolResult.failure(
          'path_escape',
          'Parent path escapes jail: $path',
        );
      }
      await parent.create(recursive: true);
      await file.writeAsString(content, flush: true);
      return SandboxToolResult.success(
        'Wrote ${content.length} characters to $path',
      );
    } on LinuxSandboxPathException catch (e) {
      return SandboxToolResult.failure(e.code, e.message);
    } catch (e) {
      return SandboxToolResult.failure('io_error', e.toString());
    }
  }

  @override
  Future<SandboxToolResult> edit(
    String path,
    String oldString,
    String newString,
  ) async {
    if (oldString.isEmpty) {
      return SandboxToolResult.failure(
        'invalid_old_string',
        'old_string must not be empty',
      );
    }
    try {
      await ensureReady();
      final hostPath = await _resolve(path);
      final file = File(hostPath);
      if (!await file.exists()) {
        return SandboxToolResult.failure('not_found', 'Not found: $path');
      }
      final text = await file.readAsString();
      final index = text.indexOf(oldString);
      if (index < 0) {
        return SandboxToolResult.failure(
          'old_string_not_found',
          'old_string not found in $path',
        );
      }
      final updated = text.replaceFirst(oldString, newString);
      await file.writeAsString(updated, flush: true);
      return SandboxToolResult.success('Edited $path');
    } on LinuxSandboxPathException catch (e) {
      return SandboxToolResult.failure(e.code, e.message);
    } catch (e) {
      return SandboxToolResult.failure('io_error', e.toString());
    }
  }

  @override
  Future<SandboxToolResult> shell(String command, {Duration? timeout}) async {
    final trimmed = command.trim();
    if (trimmed.isEmpty) {
      return SandboxToolResult.failure(
        'empty_command',
        'command must not be empty',
      );
    }
    var effective = timeout ?? defaultShellTimeout;
    if (effective > maxShellTimeout) effective = maxShellTimeout;
    if (effective.isNegative || effective == Duration.zero) {
      effective = defaultShellTimeout;
    }

    try {
      await ensureReady();
      final root = await _root();
      final process = await Process.start(
        'cmd',
        ['/c', trimmed],
        workingDirectory: root.path,
        runInShell: false,
      );

      final out = BytesBuilder(copy: false);
      final err = BytesBuilder(copy: false);
      var truncated = false;
      var total = 0;

      void take(List<int> chunk, BytesBuilder sink) {
        if (truncated) return;
        final remaining = maxOutputBytes - total;
        if (remaining <= 0) {
          truncated = true;
          return;
        }
        if (chunk.length <= remaining) {
          sink.add(chunk);
          total += chunk.length;
        } else {
          sink.add(chunk.sublist(0, remaining));
          total += remaining;
          truncated = true;
        }
      }

      final stdoutSub = process.stdout.listen((c) => take(c, out));
      final stderrSub = process.stderr.listen((c) => take(c, err));

      var timedOut = false;
      final exitCode = await process.exitCode.timeout(
        effective,
        onTimeout: () async {
          timedOut = true;
          process.kill(ProcessSignal.sigkill);
          try {
            return await process.exitCode.timeout(const Duration(seconds: 2));
          } catch (_) {
            return -1;
          }
        },
      );

      await stdoutSub.cancel();
      await stderrSub.cancel();

      final stdoutText = utf8.decode(out.takeBytes(), allowMalformed: true);
      final stderrText = utf8.decode(err.takeBytes(), allowMalformed: true);
      final buf = StringBuffer();
      if (stdoutText.isNotEmpty) buf.write(stdoutText);
      if (stderrText.isNotEmpty) {
        if (buf.isNotEmpty && !buf.toString().endsWith('\n')) buf.writeln();
        buf.write(stderrText);
      }
      if (timedOut) {
        return SandboxToolResult.failure(
          'timeout',
          'Command timed out after ${effective.inSeconds}s',
          exitCode: exitCode,
          timedOut: true,
        );
      }
      return SandboxToolResult.success(
        buf.toString(),
        exitCode: exitCode,
        outputTruncated: truncated,
      );
    } catch (e) {
      return SandboxToolResult.failure('shell_error', e.toString());
    }
  }

  @override
  Future<List<SandboxFsEntry>> listDir([String path = '']) async {
    await ensureReady();
    final hostPath = await _resolve(path);
    final dir = Directory(hostPath);
    if (!await dir.exists()) return const <SandboxFsEntry>[];
    final entries = <SandboxFsEntry>[];
    await for (final entity in dir.list(followLinks: false)) {
      final stat = await entity.stat();
      final isDir = entity is Directory;
      entries.add(
        SandboxFsEntry(
          name: p.basename(entity.path),
          isDirectory: isDir,
          size: isDir ? null : stat.size,
          modifiedAt: stat.modified,
        ),
      );
    }
    entries.sort((a, b) {
      if (a.isDirectory != b.isDirectory) {
        return a.isDirectory ? -1 : 1;
      }
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }

  @override
  Future<void> destroyDisk() async {
    final root = await _root();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  }

  static bool _looksBinary(List<int> bytes) {
    final n = bytes.length < 8192 ? bytes.length : 8192;
    for (var i = 0; i < n; i++) {
      if (bytes[i] == 0) return true;
    }
    return false;
  }
}
