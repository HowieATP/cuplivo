import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../../core/providers/assistant_provider.dart';
import '../models/linux_sandbox.dart';
import '../services/sandbox_runtime.dart';

class LinuxSandboxProvider extends ChangeNotifier {
  static const String prefsKey = 'linux_sandboxes_v1';

  final List<LinuxSandbox> _sandboxes = <LinuxSandbox>[];
  bool _loaded = false;
  Future<void>? _loadFuture;
  Future<void> _persistChain = Future<void>.value();

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
  static bool isValidSandboxId(String id) {
    final trimmed = id.trim();
    if (trimmed.isEmpty || trimmed != id) return false;
    if (trimmed == '.' || trimmed == '..') return false;
    if (trimmed.contains('/') ||
        trimmed.contains('\\') ||
        trimmed.contains('\u0000')) {
      return false;
    }
    if (trimmed.contains('..')) return false;
    return true;
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
            for (var i = 0; i < decoded.length; i++) {
              final item = decoded[i];
              if (item is! Map) {
                debugPrint(
                  'LinuxSandboxProvider: skip corrupt entry at $i: not a Map',
                );
                continue;
              }
              try {
                final sandbox = LinuxSandbox.fromJson(
                  item.cast<String, dynamic>(),
                );
                if (!isValidSandboxId(sandbox.id)) {
                  debugPrint(
                    'LinuxSandboxProvider: skip corrupt entry at $i: invalid id',
                  );
                  continue;
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
          }
        } catch (e) {
          debugPrint('LinuxSandboxProvider: failed to decode prefs: $e');
        }
      }
      _loaded = true;
      notifyListeners();
    } catch (e, st) {
      debugPrint('LinuxSandboxProvider: load failed: $e\n$st');
      rethrow;
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
    );
    _sandboxes.add(sandbox);
    try {
      await _persist();
      notifyListeners();
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
