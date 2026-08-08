import 'dart:convert';
import 'dart:io' show Platform;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

// Longest-first so `x86_64` is not partially matched as `x86`.
// Also used as static fallback order when device ABIs are unknown/unmatched.
const List<String> kAndroidApkArchTags = [
  'arm64-v8a',
  'armeabi-v7a',
  'x86_64',
  'x86',
];

String? parseAndroidApkArch(String assetName) {
  final lower = assetName.toLowerCase();
  for (final arch in kAndroidApkArchTags) {
    if (lower.contains(arch)) return arch;
  }
  return null;
}

/// iOS release ipa arch tags. Real iOS devices ship arm64-only; the x86_64
/// variant covers Intel-Mac simulators. Order doubles as static fallback
/// priority (arm64 first, mirroring the Android arm64-first default).
const List<String> kIosIpaArchTags = ['arm64', 'x86_64'];

String? parseIosIpaArch(String assetName) {
  final lower = assetName.toLowerCase();
  for (final arch in kIosIpaArchTags) {
    if (lower.contains('_$arch.ipa')) return arch;
  }
  return null;
}

String? selectIosDownloadUrl({
  required Map<String, String> ipaByArch,
  String? universalUrl,
  String? deviceArch,
}) {
  if (deviceArch != null) {
    final url = ipaByArch[deviceArch];
    if (url != null && url.isNotEmpty) return url;
  }
  for (final arch in kIosIpaArchTags) {
    final url = ipaByArch[arch];
    if (url != null && url.isNotEmpty) return url;
  }
  if (universalUrl != null && universalUrl.isNotEmpty) return universalUrl;
  if (ipaByArch.isNotEmpty) return ipaByArch.values.first;
  return null;
}

String? selectAndroidDownloadUrl({
  required Map<String, String> apkByArch,
  String? unarchUrl,
  List<String> supportedAbis = const [],
}) {
  for (final abi in supportedAbis) {
    final url = apkByArch[abi];
    if (url != null && url.isNotEmpty) return url;
  }
  for (final arch in kAndroidApkArchTags) {
    final url = apkByArch[arch];
    if (url != null && url.isNotEmpty) return url;
  }
  if (unarchUrl != null && unarchUrl.isNotEmpty) return unarchUrl;
  if (apkByArch.isNotEmpty) return apkByArch.values.first;
  return null;
}

class UpdateInfo {
  final String app;
  final String version;
  final int? build;
  final DateTime? releasedAt;
  final String? notes;
  final bool mandatory;
  final Map<String, String> downloads;

  const UpdateInfo({
    required this.app,
    required this.version,
    this.build,
    this.releasedAt,
    this.notes,
    this.mandatory = false,
    this.downloads = const {},
  });

  String? bestDownloadUrl() {
    if (Platform.isIOS) {
      return downloads['ios'] ??
          downloads['iosAppStore'] ??
          downloads['universal'];
    }
    if (Platform.isAndroid) {
      return downloads['android'] ?? downloads['universal'];
    }
    if (Platform.isMacOS) {
      return downloads['macos'] ??
          downloads['mac'] ??
          downloads['darwin'] ??
          downloads['universal'];
    }
    if (Platform.isWindows) {
      return downloads['windows'] ?? downloads['win'] ?? downloads['universal'];
    }
    if (Platform.isLinux) {
      return downloads['linux'] ?? downloads['universal'];
    }
    return downloads['universal'] ?? downloads['android'] ?? downloads['ios'];
  }

  factory UpdateInfo.fromJson(Map<String, dynamic> json) {
    final latest = (json['latest'] as Map?) ?? const {};
    final downloads =
        (latest['downloads'] as Map?)?.map(
          (k, v) => MapEntry(k.toString(), v.toString()),
        ) ??
        const {};
    DateTime? released;
    final releasedRaw = latest['releasedAt']?.toString();
    if (releasedRaw != null && releasedRaw.isNotEmpty) {
      try {
        released = DateTime.parse(releasedRaw);
      } catch (_) {}
    }
    return UpdateInfo(
      app: (json['app'] ?? '').toString(),
      version: (latest['version'] ?? '').toString(),
      build: int.tryParse((latest['build'] ?? '').toString()),
      releasedAt: released,
      notes: (latest['notes'] ?? '').toString(),
      mandatory: (latest['mandatory'] as bool?) ?? false,
      downloads: downloads,
    );
  }

  /// Parses a GitHub Releases API response into [UpdateInfo].
  factory UpdateInfo.fromGithubRelease(
    Map<String, dynamic> json, {
    List<String> androidAbis = const [],
    String? iosArch,
  }) {
    final tag = (json['tag_name'] ?? '').toString();
    // Strip leading 'v' prefix if present (e.g. "v1.2.3" -> "1.2.3")
    final version = tag.startsWith('v') ? tag.substring(1) : tag;

    DateTime? released;
    final publishedAt = json['published_at']?.toString();
    if (publishedAt != null && publishedAt.isNotEmpty) {
      try {
        released = DateTime.parse(publishedAt);
      } catch (_) {}
    }

    // Map release assets to platform download keys
    final downloads = <String, String>{};
    final apkByArch = <String, String>{};
    final ipaByArch = <String, String>{};
    String? unarchApkUrl;
    String? universalIpaUrl;
    final assets = (json['assets'] as List?) ?? const [];
    for (final asset in assets) {
      if (asset is! Map) continue;
      final name = (asset['name'] ?? '').toString().toLowerCase();
      final url = (asset['browser_download_url'] ?? '').toString();
      if (url.isEmpty) continue;
      if (name.endsWith('.apk')) {
        final arch = parseAndroidApkArch(name);
        if (arch != null) {
          apkByArch[arch] = url;
        } else {
          unarchApkUrl = url;
        }
      } else if (name.endsWith('.ipa')) {
        final arch = parseIosIpaArch(name);
        if (arch != null) {
          ipaByArch[arch] = url;
        } else {
          universalIpaUrl = url;
        }
      } else if (name.endsWith('.dmg') || name.endsWith('.pkg')) {
        downloads['macos'] = url;
      } else if (name.endsWith('.exe') || name.endsWith('.msix')) {
        downloads['windows'] = url;
      } else if (name.endsWith('.appimage') ||
          name.endsWith('.deb') ||
          name.endsWith('.rpm')) {
        downloads['linux'] = url;
      }
    }

    final androidUrl = selectAndroidDownloadUrl(
      apkByArch: apkByArch,
      unarchUrl: unarchApkUrl,
      supportedAbis: androidAbis,
    );
    if (androidUrl != null) {
      downloads['android'] = androidUrl;
    }

    final iosUrl = selectIosDownloadUrl(
      ipaByArch: ipaByArch,
      universalUrl: universalIpaUrl,
      deviceArch: iosArch,
    );
    if (iosUrl != null) {
      downloads['ios'] = iosUrl;
    }

    return UpdateInfo(
      app: 'cuplivo',
      version: version,
      releasedAt: released,
      notes: (json['body'] ?? '').toString(),
      downloads: downloads,
    );
  }
}

class UpdateProvider extends ChangeNotifier {
  UpdateInfo? _available;
  UpdateInfo? get available => _available;
  bool _checking = false;
  bool get checking => _checking;
  bool _dismissed = false;
  bool get dismissed => _dismissed;
  String? _error;
  String? get error => _error;

  /// Session-scoped dismiss: hides the update entry until the next app launch.
  /// Not persisted — the provider is recreated on startup, so a still-pending
  /// update reappears after restart.
  void dismiss() {
    _dismissed = true;
    notifyListeners();
  }

  Future<void> checkForUpdates() async {
    if (_checking) return;
    _checking = true;
    _error = null;
    notifyListeners();
    try {
      final url = Uri.parse(
        'https://api.github.com/repos/cuplivo/cuplivo/releases/latest',
      );
      final resp = await http.get(
        url,
        headers: {'Accept': 'application/vnd.github+json'},
      );
      if (resp.statusCode != 200) {
        throw Exception('HTTP ${resp.statusCode}');
      }
      final data =
          jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      final androidAbis = await _androidSupportedAbis();
      final iosArch = await _iosDeviceArch();
      final info = UpdateInfo.fromGithubRelease(
        data,
        androidAbis: androidAbis,
        iosArch: iosArch,
      );

      final pkg = await PackageInfo.fromPlatform();
      final currentVer = pkg.version; // e.g., 1.0.0

      // Compare by version only; ignore build numbers
      final hasNew = _isRemoteNewer(
        remoteVersion: info.version,
        currentVersion: currentVer,
      );
      _available = hasNew ? info : null;
    } catch (e) {
      _error = e.toString();
    } finally {
      _checking = false;
      notifyListeners();
    }
  }

  Future<List<String>> _androidSupportedAbis() async {
    if (!Platform.isAndroid) return const [];
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      return List<String>.from(info.supportedAbis);
    } catch (e) {
      debugPrint('UpdateProvider: failed to read Android ABIs: $e');
      return const [];
    }
  }

  /// iOS has no ABI list like Android. Real iOS devices ship arm64-only since
  /// 2013, so a physical device maps to arm64. Simulators report the host CPU
  /// through utsname.machine (e.g. x86_64 / arm64).
  Future<String?> _iosDeviceArch() async {
    if (!Platform.isIOS) return null;
    try {
      final info = await DeviceInfoPlugin().iosInfo;
      if (info.isPhysicalDevice) return 'arm64';
      final machine = info.utsname.machine.toLowerCase();
      if (machine.contains('x86_64')) return 'x86_64';
      if (machine.contains('arm64') || machine.contains('aarch64')) {
        return 'arm64';
      }
      return null;
    } catch (e) {
      debugPrint('UpdateProvider: failed to read iOS architecture: $e');
      return null;
    }
  }

  bool _isRemoteNewer({
    required String remoteVersion,
    required String currentVersion,
  }) {
    // Compare semantic versions only (ignore internal build numbers)
    List<int> parseVer(String v) {
      final parts = v.split('.');
      final nums = <int>[];
      for (int i = 0; i < 3; i++) {
        nums.add(i < parts.length ? int.tryParse(parts[i]) ?? 0 : 0);
      }
      return nums;
    }

    final a = parseVer(remoteVersion);
    final b = parseVer(currentVersion);
    if (a[0] != b[0]) return a[0] > b[0];
    if (a[1] != b[1]) return a[1] > b[1];
    if (a[2] != b[2]) return a[2] > b[2];
    return false;
  }
}
