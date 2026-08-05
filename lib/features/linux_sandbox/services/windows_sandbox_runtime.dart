import 'dart:io';

import '../models/linux_sandbox.dart';
import 'local_jail_fs.dart';
import 'sandbox_disk_layout.dart';
import 'sandbox_runtime.dart';
import 'windows_local_jail_runtime.dart';
import 'windows_wsl.dart';

/// Windows facade: prefers WSL when a distro is ready, otherwise local jail.
class WindowsSandboxRuntime implements SandboxRuntime {
  WindowsSandboxRuntime(this.sandboxId)
    : _localJail = WindowsLocalJailRuntime(sandboxId);

  final WindowsLocalJailRuntime _localJail;

  LinuxSandboxRuntimeMode _mode = LinuxSandboxRuntimeMode.localJail;

  @override
  final String sandboxId;

  @override
  bool get isSupported => true;

  @override
  LinuxSandboxRuntimeMode get runtimeMode => _mode;

  Future<LocalJailFs> _fs() async {
    await ensureReady();
    final files = await SandboxDiskLayout.filesDir(sandboxId);
    return LocalJailFs(files);
  }

  Future<void> _refreshModeFromDisk() async {
    final name = await SandboxDiskLayout.readRuntimeMode(sandboxId);
    if (name == null) return;
    for (final e in LinuxSandboxRuntimeMode.values) {
      if (e.name == name) {
        _mode = e;
        return;
      }
    }
  }

  @override
  Future<Directory> rootDirectory() => SandboxDiskLayout.filesDir(sandboxId);

  @override
  Future<void> ensureReady() => SandboxDiskLayout.ensureLayout(sandboxId);

  @override
  Future<SandboxInstallResult> installBaseEnv({
    void Function(double? progress, String stage)? onProgress,
  }) async {
    try {
      onProgress?.call(0.1, 'layout');
      await ensureReady();
      onProgress?.call(0.4, 'probe_wsl');
      final probe = await probeWsl();
      if (probe.distroReady) {
        onProgress?.call(0.8, 'marker');
        await SandboxDiskLayout.writeRuntimeMode(
          sandboxId,
          LinuxSandboxRuntimeMode.wsl.name,
        );
        await SandboxDiskLayout.writeBaseEnvMarker(sandboxId);
        _mode = LinuxSandboxRuntimeMode.wsl;
        onProgress?.call(1.0, 'done');
        return SandboxInstallResult.success(LinuxSandboxRuntimeMode.wsl);
      }

      onProgress?.call(0.8, 'marker');
      await SandboxDiskLayout.writeRuntimeMode(
        sandboxId,
        LinuxSandboxRuntimeMode.localJail.name,
      );
      await SandboxDiskLayout.writeBaseEnvMarker(sandboxId);
      _mode = LinuxSandboxRuntimeMode.localJail;
      onProgress?.call(1.0, 'done');
      final detail =
          probe.detail ??
          'WSL not available; using Windows folder jail (not Linux)';
      return SandboxInstallResult.success(
        LinuxSandboxRuntimeMode.localJail,
        statusMessage: detail,
      );
    } catch (e) {
      return SandboxInstallResult.failure(_mode, e.toString());
    }
  }

  @override
  Future<LinuxSandboxStatus> probeStatus() async {
    try {
      await _refreshModeFromDisk();
      final root = await SandboxDiskLayout.sandboxRoot(sandboxId);
      if (!await root.exists()) return LinuxSandboxStatus.notReady;
      final files = await SandboxDiskLayout.filesDir(sandboxId);
      if (!await files.exists()) return LinuxSandboxStatus.notReady;
      if (await SandboxDiskLayout.hasBaseEnvMarker(sandboxId)) {
        return LinuxSandboxStatus.ready;
      }
      return LinuxSandboxStatus.notReady;
    } catch (_) {
      return LinuxSandboxStatus.broken;
    }
  }

  @override
  Future<SandboxToolResult> read(String path) async {
    final fs = await _fs();
    return fs.read(path);
  }

  @override
  Future<SandboxToolResult> write(String path, String content) async {
    final fs = await _fs();
    return fs.write(path, content);
  }

  @override
  Future<SandboxToolResult> edit(
    String path,
    String oldString,
    String newString,
  ) async {
    final fs = await _fs();
    return fs.edit(path, oldString, newString);
  }

  @override
  Future<SandboxToolResult> shell(String command, {Duration? timeout}) async {
    await ensureReady();
    await _refreshModeFromDisk();

    if (_mode == LinuxSandboxRuntimeMode.wsl) {
      final probe = await probeWsl();
      if (probe.distroReady) {
        final files = await rootDirectory();
        return execWslShell(
          hostFilesDir: files.path,
          command: command,
          timeout: timeout,
          distro: probe.defaultDistro,
        );
      }
      // Marker says wsl but probe failed — fall back for this call only.
      return _localJail.shell(command, timeout: timeout);
    }

    return _localJail.shell(command, timeout: timeout);
  }

  @override
  Future<List<SandboxFsEntry>> listDir([String path = '']) async {
    final fs = await _fs();
    return fs.listDir(path);
  }

  @override
  Future<void> destroyDisk() => SandboxDiskLayout.destroySandboxTree(sandboxId);
}
