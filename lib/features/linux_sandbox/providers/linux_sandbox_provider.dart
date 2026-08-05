import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../../core/providers/assistant_provider.dart';
import '../models/linux_sandbox.dart';
import '../services/sandbox_disk_layout.dart';
import '../services/sandbox_runtime.dart';

class LinuxSandboxProvider extends ChangeNotifier {
  static const String prefsKey = 'linux_sandboxes_v1';

  final List<LinuxSandbox> _sandboxes = <LinuxSandbox>[];
  bool _loaded = false;
  Future<void>? _loadFuture;
  Future<void> _persistChain = Future<void>.value();
  final Set<String> _installingIds = <String>{};

  LinuxSandboxProvider() {
    unawaited(
      ensureLoaded().catchError((Object e, StackTrace st) {
        debugPrint('LinuxSandboxProvider: initial load failed: $e\n$st');
      }),
    );
  }

  bool get loaded => _loaded;

  List<LinuxSandbox> get sandboxes => List.unmodifiable(_sandboxes);

  /// Reject empty ids and path-escape segments so destroyDisk cannot leave
  /// the sandboxes base directory. Create still uses Uuid().v4().
  static bool isValidSandboxId(String id) =>
      SandboxDiskLayout.isValidSandboxId(id);

  static LinuxSandboxRuntimeMode defaultRuntimeModeForPlatform() {
    if (Platform.isWindows) return LinuxSandboxRuntimeMode.localJail;
    if (Platform.isLinux) return LinuxSandboxRuntimeMode.nativeLinux;
    if (Platform.isAndroid) return LinuxSandboxRuntimeMode.proot;
    return LinuxSandboxRuntimeMode.unsupported;
  }

  LinuxSandbox? getById(String id) {
    final idx = _sandboxes.indexWhere((s) => s.id == id);
    if (idx < 0) return null;
    return _sandboxes[idx];
  }

  /// Ensures sandbox metadata is loaded from SharedPreferences.
  /// Concurrent callers share one in-flight load. Failed loads are retryable.
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loadFuture ??= _load();
    try {
      await _loadFuture;
    } finally {
      _loadFuture = null;
    }
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(prefsKey);
      if (raw != null && raw.isNotEmpty) {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is! List) {
            debugPrint(
              'LinuxSandboxProvider: prefs root is not a List, ignoring',
            );
          } else {
            final parsed = <LinuxSandbox>[];
            var needsPersist = false;
            for (var i = 0; i < decoded.length; i++) {
              final item = decoded[i];
              if (item is! Map) {
                debugPrint(
                  'LinuxSandboxProvider: skip corrupt entry at $i: not a Map',
                );
                continue;
              }
              try {
                var sandbox = LinuxSandbox.fromJson(
                  item.cast<String, dynamic>(),
                );
                if (!isValidSandboxId(sandbox.id)) {
                  debugPrint(
                    'LinuxSandboxProvider: skip corrupt entry at $i: invalid id',
                  );
                  continue;
                }
                // Integrity: crashed mid-install must not stay installing.
                if (sandbox.status == LinuxSandboxStatus.installing) {
                  sandbox = sandbox.copyWith(
                    status: LinuxSandboxStatus.broken,
                    lastInstallError:
                        sandbox.lastInstallError ??
                        'Install interrupted; sandbox marked broken',
                    updatedAt: DateTime.now(),
                  );
                  needsPersist = true;
                }
                parsed.add(sandbox);
              } catch (e) {
                debugPrint(
                  'LinuxSandboxProvider: skip corrupt entry at $i: $e',
                );
              }
            }
            _sandboxes
              ..clear()
              ..addAll(parsed);
            if (needsPersist) {
              try {
                await _writeSnapshot(
                  _sandboxes.map((e) => e.toJson()).toList(growable: false),
                );
              } catch (e, st) {
                debugPrint(
                  'LinuxSandboxProvider: crash-recovery persist failed: $e\n$st',
                );
              }
            }
          }
        } catch (e) {
          debugPrint('LinuxSandboxProvider: failed to decode prefs: $e');
        }
      }
      await _probeReadySandboxes();
      _loaded = true;
      notifyListeners();
    } catch (e, st) {
      debugPrint('LinuxSandboxProvider: load failed: $e\n$st');
      rethrow;
    }
  }

  /// Re-probe sandboxes marked ready; downgrade if disk/runtime disagrees.
  Future<void> _probeReadySandboxes() async {
    var changed = false;
    for (var i = 0; i < _sandboxes.length; i++) {
      final sandbox = _sandboxes[i];
      if (sandbox.status != LinuxSandboxStatus.ready) continue;
      try {
        final runtime = createSandboxRuntime(sandbox.id);
        final probed = await runtime.probeStatus();
        if (probed == LinuxSandboxStatus.ready) continue;
        // Unsupported platform probe returns disabled — do not corrupt
        // status when prefs were restored on another OS.
        if (probed == LinuxSandboxStatus.disabled) continue;
        _sandboxes[i] = sandbox.copyWith(
          status: probed == LinuxSandboxStatus.notReady
              ? LinuxSandboxStatus.notReady
              : LinuxSandboxStatus.broken,
          updatedAt: DateTime.now(),
        );
        changed = true;
      } catch (e, st) {
        debugPrint(
          'LinuxSandboxProvider: probeStatus failed for ${sandbox.id}: $e\n$st',
        );
        _sandboxes[i] = sandbox.copyWith(
          status: LinuxSandboxStatus.broken,
          updatedAt: DateTime.now(),
        );
        changed = true;
      }
    }
    if (!changed) return;
    try {
      await _writeSnapshot(
        _sandboxes.map((e) => e.toJson()).toList(growable: false),
      );
    } catch (e, st) {
      debugPrint(
        'LinuxSandboxProvider: probe downgrade persist failed: $e\n$st',
      );
    }
  }

  /// Serializes writes; each call snapshots list state at invoke time so a
  /// later mutation does not clobber an earlier persist payload mid-flight.
  /// A failed write does not poison the chain for subsequent persists.
  Future<void> _persist() {
    final snapshot = _sandboxes.map((e) => e.toJson()).toList(growable: false);
    final next = _persistChain.then((_) => _writeSnapshot(snapshot));
    _persistChain = next.catchError((Object e, StackTrace st) {
      debugPrint('LinuxSandboxProvider: persist failed: $e\n$st');
    });
    return next;
  }

  Future<void> _writeSnapshot(List<Map<String, dynamic>> snapshot) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(prefsKey, jsonEncode(snapshot));
  }

  Future<LinuxSandbox> create({
    required String name,
    String? description,
    List<String> enabledEnvPacks = const <String>[],
  }) async {
    await ensureLoaded();
    final now = DateTime.now();
    final sandbox = LinuxSandbox(
      id: const Uuid().v4(),
      name: name.trim().isEmpty ? 'Sandbox' : name.trim(),
      description: description?.trim().isEmpty == true
          ? null
          : description?.trim(),
      createdAt: now,
      updatedAt: now,
      enabledEnvPacks: enabledEnvPacks,
      status: LinuxSandboxStatus.notReady,
      runtimeMode: defaultRuntimeModeForPlatform(),
    );
    _sandboxes.add(sandbox);
    try {
      await _persist();
      notifyListeners();
      // Layout only — installBaseEnv is explicit.
      final runtime = createSandboxRuntime(sandbox.id);
      await runtime.ensureReady();
      return sandbox;
    } catch (e, st) {
      debugPrint('LinuxSandboxProvider.create: failed, rolling back: $e\n$st');
      _sandboxes.removeWhere((s) => s.id == sandbox.id);
      try {
        await _persist();
      } catch (persistError, persistSt) {
        debugPrint(
          'LinuxSandboxProvider.create: rollback persist failed: '
          '$persistError\n$persistSt',
        );
      }
      notifyListeners();
      rethrow;
    }
  }

  /// Explicit base-env install. Updates status through installing → ready/broken.
  Future<SandboxInstallResult> installBaseEnv(
    String id, {
    void Function(double? progress, String stage)? onProgress,
  }) async {
    await ensureLoaded();
    if (!isValidSandboxId(id)) {
      return SandboxInstallResult.failure(
        LinuxSandboxRuntimeMode.unknown,
        'Invalid sandbox id',
      );
    }
    if (_installingIds.contains(id)) {
      return SandboxInstallResult.failure(
        LinuxSandboxRuntimeMode.unknown,
        'Install already in progress for this sandbox',
      );
    }
    final idx = _sandboxes.indexWhere((s) => s.id == id);
    if (idx < 0) {
      return SandboxInstallResult.failure(
        LinuxSandboxRuntimeMode.unknown,
        'Sandbox not found',
      );
    }

    _installingIds.add(id);
    try {
      final current = _sandboxes[idx];
      _sandboxes[idx] = current.copyWith(
        status: LinuxSandboxStatus.installing,
        clearLastInstallError: true,
        clearStatusMessage: true,
        updatedAt: DateTime.now(),
      );
      await _persist();
      notifyListeners();

      final runtime = createSandboxRuntime(id);
      late final SandboxInstallResult result;
      try {
        result = await runtime.installBaseEnv(
          onProgress: (progress, stage) {
            onProgress?.call(progress, stage);
            final progressIdx = _sandboxes.indexWhere((s) => s.id == id);
            if (progressIdx < 0) return;
            final pct = progress == null
                ? ''
                : ' ${(progress.clamp(0.0, 1.0) * 100).toStringAsFixed(0)}%';
            _sandboxes[progressIdx] = _sandboxes[progressIdx].copyWith(
              statusMessage: '$stage$pct',
              updatedAt: DateTime.now(),
            );
            notifyListeners();
          },
        );
      } catch (e, st) {
        debugPrint('LinuxSandboxProvider.installBaseEnv: threw: $e\n$st');
        result = SandboxInstallResult.failure(
          runtime.runtimeMode,
          e.toString(),
        );
      }

      final afterIdx = _sandboxes.indexWhere((s) => s.id == id);
      if (afterIdx < 0) return result;

      if (result.ok) {
        final msg = result.statusMessage;
        _sandboxes[afterIdx] = _sandboxes[afterIdx].copyWith(
          status: LinuxSandboxStatus.ready,
          runtimeMode: result.mode,
          clearLastInstallError: true,
          statusMessage: msg,
          clearStatusMessage: msg == null || msg.isEmpty,
          updatedAt: DateTime.now(),
        );
      } else {
        _sandboxes[afterIdx] = _sandboxes[afterIdx].copyWith(
          status: LinuxSandboxStatus.broken,
          runtimeMode: result.mode,
          lastInstallError: result.errorMessage,
          clearStatusMessage: true,
          updatedAt: DateTime.now(),
        );
      }
      await _persist();
      notifyListeners();
      return result;
    } catch (e, st) {
      debugPrint(
        'LinuxSandboxProvider.installBaseEnv: pipeline failed: $e\n$st',
      );
      final failIdx = _sandboxes.indexWhere((s) => s.id == id);
      if (failIdx >= 0) {
        _sandboxes[failIdx] = _sandboxes[failIdx].copyWith(
          status: LinuxSandboxStatus.broken,
          lastInstallError: e.toString(),
          clearStatusMessage: true,
          updatedAt: DateTime.now(),
        );
        try {
          await _persist();
        } catch (persistError, persistSt) {
          debugPrint(
            'LinuxSandboxProvider.installBaseEnv: broken persist failed: '
            '$persistError\n$persistSt',
          );
        }
        notifyListeners();
      }
      return SandboxInstallResult.failure(
        LinuxSandboxRuntimeMode.unknown,
        e.toString(),
      );
    } finally {
      _installingIds.remove(id);
    }
  }

  Future<void> update(LinuxSandbox sandbox) async {
    await ensureLoaded();
    final idx = _sandboxes.indexWhere((s) => s.id == sandbox.id);
    if (idx < 0) return;
    _sandboxes[idx] = sandbox.copyWith(updatedAt: DateTime.now());
    await _persist();
    notifyListeners();
  }

  Future<void> setToolConfig(
    String sandboxId,
    String toolName,
    LinuxSandboxToolConfig config,
  ) async {
    await ensureLoaded();
    if (!LinuxSandboxToolNames.all.contains(toolName)) return;
    final idx = _sandboxes.indexWhere((s) => s.id == sandboxId);
    if (idx < 0) return;
    final current = _sandboxes[idx];
    final tools = Map<String, LinuxSandboxToolConfig>.from(current.tools);
    tools[toolName] = config;
    _sandboxes[idx] = current.copyWith(tools: tools, updatedAt: DateTime.now());
    await _persist();
    notifyListeners();
  }

  /// Deletes sandbox metadata and best-effort disk/assistant scrub.
  ///
  /// Order: scrub assistants (per-item catch) → destroyDisk (catch+log) →
  /// always remove metadata. Prefer removing metadata over leaving a phantom
  /// entry if disk destroy fails.
  Future<void> delete(String id, AssistantProvider assistantProvider) async {
    await ensureLoaded();
    if (!isValidSandboxId(id)) {
      debugPrint('LinuxSandboxProvider.delete: refusing invalid id: $id');
      return;
    }
    final idx = _sandboxes.indexWhere((s) => s.id == id);
    if (idx < 0) return;

    for (final a in List.of(assistantProvider.assistants)) {
      if (a.sandboxId != id) continue;
      try {
        await assistantProvider.updateAssistant(
          a.copyWith(clearSandboxId: true, sandboxEnabled: false),
        );
      } catch (e, st) {
        debugPrint(
          'LinuxSandboxProvider.delete: scrub assistant ${a.id} failed: $e\n$st',
        );
      }
    }

    final runtime = createSandboxRuntime(id);
    try {
      await runtime.destroyDisk();
    } catch (e, st) {
      debugPrint(
        'LinuxSandboxProvider.delete: destroyDisk failed for $id '
        '(metadata will still be removed): $e\n$st',
      );
    }

    // Re-resolve index after async scrub (list may have changed).
    final removeIdx = _sandboxes.indexWhere((s) => s.id == id);
    if (removeIdx >= 0) {
      _sandboxes.removeAt(removeIdx);
    }
    await _persist();
    notifyListeners();
  }
}
