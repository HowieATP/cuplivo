import 'dart:io';

import 'unsupported_sandbox_runtime.dart';
import 'windows_local_jail_runtime.dart';

class SandboxFsEntry {
  final String name;
  final bool isDirectory;
  final int? size;
  final DateTime? modifiedAt;

  const SandboxFsEntry({
    required this.name,
    required this.isDirectory,
    this.size,
    this.modifiedAt,
  });
}

class SandboxToolResult {
  final bool ok;
  final String? content;
  final String? errorCode;
  final String? errorMessage;
  final int? exitCode;
  final bool timedOut;
  final bool outputTruncated;

  const SandboxToolResult({
    required this.ok,
    this.content,
    this.errorCode,
    this.errorMessage,
    this.exitCode,
    this.timedOut = false,
    this.outputTruncated = false,
  });

  factory SandboxToolResult.success(
    String content, {
    int? exitCode,
    bool outputTruncated = false,
  }) {
    return SandboxToolResult(
      ok: true,
      content: content,
      exitCode: exitCode,
      outputTruncated: outputTruncated,
    );
  }

  factory SandboxToolResult.failure(
    String errorCode,
    String errorMessage, {
    int? exitCode,
    bool timedOut = false,
  }) {
    return SandboxToolResult(
      ok: false,
      errorCode: errorCode,
      errorMessage: errorMessage,
      exitCode: exitCode,
      timedOut: timedOut,
    );
  }

  Map<String, dynamic> toJson() {
    if (ok) {
      return {
        'ok': true,
        'content': content ?? '',
        if (exitCode != null) 'exit_code': exitCode,
        if (outputTruncated) 'output_truncated': true,
      };
    }
    return {
      'ok': false,
      'error': errorCode ?? 'error',
      'message': errorMessage ?? 'Unknown error',
      if (exitCode != null) 'exit_code': exitCode,
      if (timedOut) 'timed_out': true,
    };
  }
}

abstract class SandboxRuntime {
  String get sandboxId;

  bool get isSupported;

  Future<Directory> rootDirectory();

  Future<void> ensureReady();

  Future<SandboxToolResult> read(String path);

  Future<SandboxToolResult> write(String path, String content);

  Future<SandboxToolResult> edit(
    String path,
    String oldString,
    String newString,
  );

  Future<SandboxToolResult> shell(String command, {Duration? timeout});

  Future<List<SandboxFsEntry>> listDir([String path = '']);

  Future<void> destroyDisk();
}

SandboxRuntime createSandboxRuntime(String sandboxId) {
  if (Platform.isWindows) {
    return WindowsLocalJailRuntime(sandboxId);
  }
  return UnsupportedSandboxRuntime(sandboxId);
}
