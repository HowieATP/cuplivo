import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'sandbox_runtime.dart';

class WslProbeResult {
  final bool available;
  final bool distroReady;
  final String? defaultDistro;
  final String? detail;

  const WslProbeResult({
    required this.available,
    required this.distroReady,
    this.defaultDistro,
    this.detail,
  });
}

/// Convert a Windows host path to a WSL mount path (`C:\x` → `/mnt/c/x`).
String hostPathToWsl(String windowsPath) {
  final trimmed = windowsPath.trim();
  if (trimmed.isEmpty) return trimmed;

  final normalized = trimmed.replaceAll('/', '\\');
  final driveMatch = RegExp(r'^([A-Za-z]):[\\]?(.*)$').firstMatch(normalized);
  if (driveMatch != null) {
    final drive = driveMatch.group(1)!.toLowerCase();
    var rest = driveMatch.group(2) ?? '';
    rest = rest.replaceAll('\\', '/');
    while (rest.startsWith('/')) {
      rest = rest.substring(1);
    }
    if (rest.endsWith('/')) {
      rest = rest.substring(0, rest.length - 1);
    }
    if (rest.isEmpty) return '/mnt/$drive';
    return '/mnt/$drive/$rest';
  }

  // Already a WSL-style path or other form: normalize separators only.
  var unix = trimmed.replaceAll('\\', '/');
  if (unix.length >= 2 && unix[1] == ':') {
    final drive = unix[0].toLowerCase();
    var rest = unix.length > 2 ? unix.substring(2) : '';
    while (rest.startsWith('/')) {
      rest = rest.substring(1);
    }
    if (rest.endsWith('/')) {
      rest = rest.substring(0, rest.length - 1);
    }
    if (rest.isEmpty) return '/mnt/$drive';
    return '/mnt/$drive/$rest';
  }
  return unix;
}

/// Decode WSL CLI stdout which is typically UTF-16LE (often with BOM).
String decodeWslOutput(List<int> bytes) {
  if (bytes.isEmpty) return '';

  var offset = 0;
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    offset = 2;
  } else if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    // UTF-16BE BOM — uncommon for WSL, still handle.
    final units = <int>[];
    for (var i = 2; i + 1 < bytes.length; i += 2) {
      units.add((bytes[i] << 8) | bytes[i + 1]);
    }
    return String.fromCharCodes(units).replaceAll('\u0000', '');
  }

  if (_looksLikeUtf16Le(bytes, offset)) {
    final units = <int>[];
    for (var i = offset; i + 1 < bytes.length; i += 2) {
      units.add(bytes[i] | (bytes[i + 1] << 8));
    }
    // Odd trailing byte
    if ((bytes.length - offset).isOdd) {
      units.add(bytes.last);
    }
    return String.fromCharCodes(units).replaceAll('\u0000', '');
  }

  return utf8.decode(bytes, allowMalformed: true).replaceAll('\u0000', '');
}

bool _looksLikeUtf16Le(List<int> bytes, int offset) {
  final remaining = bytes.length - offset;
  if (remaining < 4) {
    // Short ASCII via UTF-16LE: 'A\x00'
    if (remaining >= 2 && bytes[offset + 1] == 0) return true;
    return false;
  }
  var nulHigh = 0;
  var pairs = 0;
  for (var i = offset; i + 1 < bytes.length && pairs < 32; i += 2) {
    pairs++;
    if (bytes[i + 1] == 0) nulHigh++;
  }
  return pairs > 0 && nulHigh >= (pairs / 2).ceil();
}

Future<WslProbeResult> probeWsl() async {
  try {
    final result = await Process.run(
      'wsl.exe',
      const ['-l', '-q'],
      stdoutEncoding: null,
      stderrEncoding: null,
    );

    final stdoutBytes = _asBytes(result.stdout);
    final stderrBytes = _asBytes(result.stderr);
    final text = decodeWslOutput(stdoutBytes).trim();
    final errText = decodeWslOutput(stderrBytes).trim();

    // Exit code 1 often means "no distros" while wsl.exe itself exists.
    final distros = <String>[];
    for (final line in text.split(RegExp(r'\r?\n'))) {
      final name = line.trim();
      if (name.isEmpty) continue;
      // Skip obvious non-distro noise.
      if (name.toLowerCase().startsWith('windows subsystem')) continue;
      distros.add(name);
    }

    if (distros.isEmpty) {
      final detail = errText.isNotEmpty
          ? errText
          : (text.isNotEmpty
                ? text
                : 'WSL is installed but no distributions are registered');
      return WslProbeResult(
        available: result.exitCode == 0 || result.exitCode == 1,
        distroReady: false,
        detail: detail,
      );
    }

    return WslProbeResult(
      available: true,
      distroReady: true,
      defaultDistro: distros.first,
      detail: 'WSL distro ready: ${distros.first}',
    );
  } on ProcessException catch (e) {
    return WslProbeResult(
      available: false,
      distroReady: false,
      detail: 'WSL not available: ${e.message}',
    );
  } catch (e) {
    return WslProbeResult(
      available: false,
      distroReady: false,
      detail: 'WSL probe failed: $e',
    );
  }
}

Future<SandboxToolResult> execWslShell({
  required String hostFilesDir,
  required String command,
  Duration? timeout,
  String? distro,
}) async {
  final trimmed = command.trim();
  if (trimmed.isEmpty) {
    return SandboxToolResult.failure(
      'empty_command',
      'command must not be empty',
    );
  }

  var effective = timeout ?? const Duration(seconds: 30);
  if (effective > const Duration(seconds: 120)) {
    effective = const Duration(seconds: 120);
  }
  if (effective.isNegative || effective == Duration.zero) {
    effective = const Duration(seconds: 30);
  }

  final wslCd = hostPathToWsl(hostFilesDir);
  final args = <String>[];
  if (distro != null && distro.trim().isNotEmpty) {
    args.addAll(['-d', distro.trim()]);
  }
  // Prefer --cd; also pass bash -lc so the user command runs in a login shell.
  args.addAll(['--cd', wslCd, '--', 'bash', '-lc', trimmed]);

  try {
    final process = await Process.start('wsl.exe', args, runInShell: false);

    const maxOutputBytes = 256 * 1024;
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

List<int> _asBytes(Object? value) {
  if (value == null) return const <int>[];
  if (value is List<int>) return value;
  if (value is Uint8List) return value;
  if (value is String) return utf8.encode(value);
  return utf8.encode(value.toString());
}
