import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../utils/app_directories.dart';
import 'linux_sandbox_path.dart';
import 'sandbox_runtime.dart';

class UnsupportedSandboxRuntime implements SandboxRuntime {
  UnsupportedSandboxRuntime(this.sandboxId);

  @override
  final String sandboxId;

  @override
  bool get isSupported => false;

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

  SandboxToolResult _unsupported() {
    return SandboxToolResult.failure(
      'platform_unsupported',
      'Linux Sandbox tools are not supported on this platform in v1',
    );
  }

  @override
  Future<SandboxToolResult> read(String path) async => _unsupported();

  @override
  Future<SandboxToolResult> write(String path, String content) async =>
      _unsupported();

  @override
  Future<SandboxToolResult> edit(
    String path,
    String oldString,
    String newString,
  ) async => _unsupported();

  @override
  Future<SandboxToolResult> shell(String command, {Duration? timeout}) async =>
      _unsupported();

  @override
  Future<List<SandboxFsEntry>> listDir([String path = '']) async {
    final root = await _root();
    if (!await root.exists()) return const <SandboxFsEntry>[];
    String hostPath;
    try {
      hostPath = await LinuxSandboxPath.resolveHostPath(
        jailRoot: root.path,
        guestPath: path,
      );
    } on LinuxSandboxPathException {
      return const <SandboxFsEntry>[];
    }
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
}
