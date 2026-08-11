import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../models/workspace.dart';

enum SandboxStatus {
  /// Not Android (or plugin missing entirely).
  unsupported,

  /// No rootfs extracted yet.
  disabled,

  /// Rootfs present but proot runtime (.so) missing from the APK/device.
  runtimeMissing,

  installing,
  ready,
  broken,
}

/// Pure readiness matrix (testable without platform channels).
class SandboxReadiness {
  const SandboxReadiness._();

  static SandboxStatus compute({
    required bool isAndroid,
    required bool hasRootfs,
    required bool hasProot,
    bool rootfsCheckFailed = false,
  }) {
    if (!isAndroid) return SandboxStatus.unsupported;
    if (rootfsCheckFailed) return SandboxStatus.broken;
    if (!hasRootfs) return SandboxStatus.disabled;
    if (!hasProot) return SandboxStatus.runtimeMissing;
    return SandboxStatus.ready;
  }
}

class SandboxExecResult {
  final int exitCode;
  final String stdout;
  final String stderr;
  final bool timedOut;

  const SandboxExecResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    this.timedOut = false,
  });
}

class SandboxInstallProgress {
  final String stage; // downloading | extracting | installing | done
  final double? progress; // 0-1 if known
  final String? message;

  const SandboxInstallProgress({
    required this.stage,
    this.progress,
    this.message,
  });
}

/// One staged apt operation inside the sandbox rootfs.
class AptInstallStep {
  /// 'recover' (self-heal dpkg state), 'update' or 'install'.
  final String stage;
  final String command;
  final int timeoutSeconds;

  const AptInstallStep({
    required this.stage,
    required this.command,
    required this.timeoutSeconds,
  });
}

/// Android proot-based Linux sandbox. Other platforms report [unsupported].
///
/// Architecture mirrors common proot userland sandboxes; implementation is
/// original (not copied from AGPL sources).
class LinuxSandboxService {
  LinuxSandboxService._();
  static final LinuxSandboxService instance = LinuxSandboxService._();

  static const MethodChannel _channel = MethodChannel('cuplivo/linux_sandbox');

  static const int maxOutputChars = 128 * 1024;

  static const String _ua =
      'Cuplivo/1.0 (Linux sandbox installer; +https://github.com/cuplivo/cuplivo)';

  /// Default rootfs URLs by ABI (Ubuntu base 24.04).
  static const Map<String, String> defaultRootfsUrls = {
    'arm64-v8a':
        'https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.3-base-arm64.tar.gz',
    'x86_64':
        'https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.3-base-amd64.tar.gz',
  };

  static const Map<String, Map<String, String>> rootfsSourceUrls = {
    'arm64-v8a': {
      'official':
          'https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.3-base-arm64.tar.gz',
      'tuna':
          'https://mirrors.tuna.tsinghua.edu.cn/ubuntu-cdimage/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.3-base-arm64.tar.gz',
      'aliyun':
          'https://mirrors.aliyun.com/ubuntu-cdimage/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.3-base-arm64.tar.gz',
    },
    'x86_64': {
      'official':
          'https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.3-base-amd64.tar.gz',
      'tuna':
          'https://mirrors.tuna.tsinghua.edu.cn/ubuntu-cdimage/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.3-base-amd64.tar.gz',
      'aliyun':
          'https://mirrors.aliyun.com/ubuntu-cdimage/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.3-base-amd64.tar.gz',
    },
  };

  /// Resolve download URL list for [pref] + [abi]. Exposed for tests.
  static List<String> resolveRootfsUrls({
    required String abi,
    required DependencyInstallPref pref,
  }) {
    final bySource = rootfsSourceUrls[abi] ?? rootfsSourceUrls['arm64-v8a']!;
    final source = pref.sourceId.trim().isEmpty ? 'auto' : pref.sourceId.trim();
    if (source == 'custom') {
      final custom = pref.customUrl?.trim() ?? '';
      if (custom.isEmpty) {
        throw StateError('Custom source requires a URL');
      }
      return [custom];
    }
    if (source == 'auto') {
      return [bySource['official']!, bySource['tuna']!, bySource['aliyun']!];
    }
    final single = bySource[source];
    if (single != null) return [single];
    if (source.startsWith('http://') || source.startsWith('https://')) {
      return [source];
    }
    // Unknown named source → official only (do not dump all mirrors).
    return [bySource['official'] ?? defaultRootfsUrls[abi]!];
  }

  /// True when the proot native runtime is packaged and loadable.
  Future<bool> get isSupported async => hasProotRuntime();

  Future<bool> hasProotRuntime() async {
    if (!Platform.isAndroid) return false;
    try {
      final v = await _channel.invokeMethod<bool>('isSupported');
      return v == true;
    } on MissingPluginException {
      return false;
    } catch (e) {
      debugPrint('LinuxSandboxService.hasProotRuntime: $e');
      return false;
    }
  }

  Future<String> detectAbi() async {
    if (!Platform.isAndroid) return 'unknown';
    try {
      final v = await _channel.invokeMethod<String>('getAbi');
      return v ?? 'arm64-v8a';
    } catch (e) {
      debugPrint('LinuxSandboxService.detectAbi: $e');
      return 'arm64-v8a';
    }
  }

  String linuxDir(String workspaceHostPath) =>
      p.join(workspaceHostPath, '.sandbox', 'linux');

  String tmpDir(String workspaceHostPath) =>
      p.join(workspaceHostPath, '.sandbox', 'tmp');

  /// Rootfs is present when guest shell binary exists under `.sandbox/linux`.
  Future<bool> hasRootfs(String workspaceHostPath) async {
    try {
      final sh = File(p.join(linuxDir(workspaceHostPath), 'bin', 'sh'));
      if (await sh.exists()) return true;
      final bash = File(p.join(linuxDir(workspaceHostPath), 'bin', 'bash'));
      return await bash.exists();
    } catch (e) {
      debugPrint('LinuxSandboxService.hasRootfs: $e');
      return false;
    }
  }

  Future<SandboxStatus> statusFor(String workspaceHostPath) async {
    if (!Platform.isAndroid) return SandboxStatus.unsupported;
    bool rootfs;
    var checkFailed = false;
    try {
      rootfs = await hasRootfs(workspaceHostPath);
    } catch (e) {
      debugPrint('LinuxSandboxService.statusFor rootfs: $e');
      rootfs = false;
      checkFailed = true;
    }
    final proot = await hasProotRuntime();
    return SandboxReadiness.compute(
      isAndroid: true,
      hasRootfs: rootfs,
      hasProot: proot,
      rootfsCheckFailed: checkFailed,
    );
  }

  Future<bool> isDependencyInstalled(
    String workspaceHostPath,
    String depId,
  ) async {
    // Base = rootfs on disk only (does not require proot).
    if (depId == WorkspaceDependencyIds.base) {
      return hasRootfs(workspaceHostPath);
    }
    final status = await statusFor(workspaceHostPath);
    if (status != SandboxStatus.ready) return false;
    final probe = switch (depId) {
      WorkspaceDependencyIds.python => 'python3',
      WorkspaceDependencyIds.nodejs => 'node',
      WorkspaceDependencyIds.git => 'git',
      WorkspaceDependencyIds.buildEssential => 'gcc',
      _ => null,
    };
    if (probe == null) return false;
    final r = await exec(
      workspaceHostPath: workspaceHostPath,
      command: 'command -v $probe >/dev/null 2>&1',
      timeoutSeconds: 15,
    );
    return r.exitCode == 0;
  }

  static String statusUserMessage(SandboxStatus status) {
    switch (status) {
      case SandboxStatus.disabled:
        return 'Install the base (Linux rootfs) dependency first.';
      case SandboxStatus.runtimeMissing:
        return 'proot runtime missing from this build; reinstall the app with sandbox native libs.';
      case SandboxStatus.unsupported:
        return 'Linux sandbox is only available on Android.';
      case SandboxStatus.broken:
        return 'Sandbox rootfs is broken; reinstall the base dependency.';
      case SandboxStatus.installing:
        return 'Sandbox is still installing.';
      case SandboxStatus.ready:
        return 'Sandbox is ready.';
    }
  }

  Future<void> installBase({
    required String workspaceHostPath,
    required DependencyInstallPref pref,
    void Function(SandboxInstallProgress)? onProgress,
  }) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('Linux sandbox is Android-only');
    }
    final abi = await detectAbi();
    final urls = resolveRootfsUrls(abi: abi, pref: pref);
    final sandboxDir = Directory(p.join(workspaceHostPath, '.sandbox'));
    await sandboxDir.create(recursive: true);
    final archivePath = p.join(sandboxDir.path, 'download.tar.gz');

    Object? lastError;
    for (final url in urls) {
      try {
        onProgress?.call(
          SandboxInstallProgress(
            stage: 'downloading',
            progress: 0,
            message: url,
          ),
        );
        await _downloadFile(
          url: url,
          savePath: archivePath,
          onProgress: (ratio) {
            onProgress?.call(
              SandboxInstallProgress(
                stage: 'downloading',
                progress: ratio,
                message: url,
              ),
            );
          },
        );
        onProgress?.call(
          const SandboxInstallProgress(stage: 'extracting', progress: null),
        );
        await _channel.invokeMethod<void>('extractRootfs', {
          'workspacePath': workspaceHostPath,
          'archivePath': archivePath,
        });
        try {
          final f = File(archivePath);
          if (await f.exists()) await f.delete();
        } catch (e) {
          debugPrint('LinuxSandboxService: cleanup archive failed: $e');
        }
        onProgress?.call(
          const SandboxInstallProgress(stage: 'done', progress: 1),
        );
        return;
      } catch (e) {
        lastError = e;
        debugPrint('installBase failed for $url: $e');
        try {
          final f = File(archivePath);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }
    throw StateError('Failed to install rootfs: $lastError');
  }

  Future<void> _downloadFile({
    required String url,
    required String savePath,
    void Function(double ratio)? onProgress,
  }) async {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 45),
        receiveTimeout: const Duration(minutes: 30),
        sendTimeout: const Duration(minutes: 5),
        followRedirects: true,
        maxRedirects: 8,
        headers: <String, dynamic>{'User-Agent': _ua, 'Accept': '*/*'},
        // Let us handle non-2xx with a clear message.
        validateStatus: (code) => code != null && code >= 200 && code < 400,
      ),
    );
    try {
      final response = await dio.download(
        url,
        savePath,
        deleteOnError: true,
        onReceiveProgress: (received, total) {
          if (total > 0) {
            onProgress?.call((received / total).clamp(0.0, 1.0));
          } else {
            onProgress?.call(0);
          }
        },
        options: Options(
          responseType: ResponseType.bytes,
          followRedirects: true,
          validateStatus: (code) => code != null && code >= 200 && code < 300,
        ),
      );
      final code = response.statusCode ?? 0;
      if (code < 200 || code >= 300) {
        throw StateError('HTTP $code downloading $url');
      }
      final file = File(savePath);
      if (!await file.exists() || await file.length() == 0) {
        throw StateError('Downloaded file empty for $url');
      }
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      final reason = e.message ?? e.type.name;
      if (code != null) {
        throw StateError('HTTP $code downloading $url: $reason');
      }
      throw StateError('Download failed for $url: $reason');
    } finally {
      dio.close(force: true);
    }
  }

  /// Build the staged apt commands used by [installPackage].
  ///
  /// The `recover` step repairs an interrupted dpkg state left behind by a
  /// killed transaction (install timeout, app process death) and clears
  /// stale lock files, so later installs do not fail with
  /// "dpkg was interrupted". Exposed for tests.
  static List<AptInstallStep> buildAptInstallSteps({
    required String packages,
    String mirrorSetup = '',
  }) {
    return [
      AptInstallStep(
        stage: 'recover',
        timeoutSeconds: 300,
        command:
            'export DEBIAN_FRONTEND=noninteractive; '
            'rm -f /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend '
            '/var/cache/apt/archives/lock /var/lib/apt/lists/lock; '
            'dpkg --configure -a; apt-get -f install -y',
      ),
      AptInstallStep(
        stage: 'update',
        timeoutSeconds: 600,
        command:
            '${mirrorSetup.isEmpty ? '' : mirrorSetup}'
            'apt-get update -y',
      ),
      AptInstallStep(
        stage: 'install',
        timeoutSeconds: 1800,
        command:
            'export DEBIAN_FRONTEND=noninteractive; '
            'apt-get install -y --no-install-recommends $packages '
            '&& apt-get clean',
      ),
    ];
  }

  Future<void> installPackage({
    required String workspaceHostPath,
    required String depId,
    required DependencyInstallPref pref,
    void Function(SandboxInstallProgress)? onProgress,
  }) async {
    if (depId == WorkspaceDependencyIds.base) {
      await installBase(
        workspaceHostPath: workspaceHostPath,
        pref: pref,
        onProgress: onProgress,
      );
      return;
    }
    if (!await hasRootfs(workspaceHostPath)) {
      throw StateError(statusUserMessage(SandboxStatus.disabled));
    }
    if (!await hasProotRuntime()) {
      throw StateError(statusUserMessage(SandboxStatus.runtimeMissing));
    }
    onProgress?.call(const SandboxInstallProgress(stage: 'installing'));
    final packages = switch (depId) {
      WorkspaceDependencyIds.python => 'python3 python3-pip',
      WorkspaceDependencyIds.nodejs => 'nodejs npm',
      WorkspaceDependencyIds.git => 'git',
      WorkspaceDependencyIds.buildEssential => 'build-essential',
      _ => throw StateError('Unknown dependency: $depId'),
    };
    var mirrorSetup = '';
    if (pref.sourceId == 'custom' &&
        pref.customUrl != null &&
        pref.customUrl!.trim().isNotEmpty) {
      final url = _sanitizeMirrorUrl(pref.customUrl!.trim());
      if (url == null) {
        throw StateError('Invalid custom mirror URL');
      }
      mirrorSetup =
          "printf '%s\\n' 'deb $url noble main universe' > /etc/apt/sources.list && ";
    }
    for (final step in buildAptInstallSteps(
      packages: packages,
      mirrorSetup: mirrorSetup,
    )) {
      final r = await exec(
        workspaceHostPath: workspaceHostPath,
        command: step.command,
        timeoutSeconds: step.timeoutSeconds,
      );
      if (r.exitCode != 0) {
        if (step.stage == 'recover') {
          debugPrint(
            'LinuxSandboxService: dpkg self-heal failed (${r.exitCode}): '
            '${r.stderr}',
          );
          continue;
        }
        final label = step.stage == 'update' ? 'apt update' : 'apt install';
        throw StateError('$label failed (${r.exitCode}): ${r.stderr}');
      }
    }
    onProgress?.call(const SandboxInstallProgress(stage: 'done', progress: 1));
  }

  Future<SandboxExecResult> exec({
    required String workspaceHostPath,
    required String command,
    String? cwd,
    int timeoutSeconds = 30,
  }) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('shell is Android-only');
    }
    try {
      final map = await _channel.invokeMethod<Map>('exec', {
        'workspacePath': workspaceHostPath,
        'command': command,
        if (cwd != null) 'cwd': cwd,
        'timeoutMs': timeoutSeconds * 1000,
      });
      if (map == null) {
        return const SandboxExecResult(
          exitCode: -1,
          stdout: '',
          stderr: 'null result',
        );
      }
      var stdout = (map['stdout'] ?? '').toString();
      var stderr = (map['stderr'] ?? '').toString();
      if (stdout.length > maxOutputChars) {
        stdout = '${stdout.substring(0, maxOutputChars)}\n...[truncated]';
      }
      if (stderr.length > maxOutputChars) {
        stderr = '${stderr.substring(0, maxOutputChars)}\n...[truncated]';
      }
      return SandboxExecResult(
        exitCode: (map['exitCode'] as num?)?.toInt() ?? -1,
        stdout: stdout,
        stderr: stderr,
        timedOut: map['timedOut'] == true,
      );
    } on MissingPluginException {
      return const SandboxExecResult(
        exitCode: -1,
        stdout: '',
        stderr: 'Linux sandbox plugin not available',
      );
    } on PlatformException catch (e) {
      return SandboxExecResult(
        exitCode: -1,
        stdout: '',
        stderr: e.message ?? e.code,
      );
    }
  }

  /// Allow only plain http(s) mirror base URLs without shell metacharacters.
  static String? _sanitizeMirrorUrl(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    if (uri.host.isEmpty) return null;
    if (RegExp(r'''[\s'"\\;&|`$<>]''').hasMatch(raw)) return null;
    return raw;
  }
}
