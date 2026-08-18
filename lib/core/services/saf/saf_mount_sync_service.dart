import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../mcp/kelivo_filesystem/kelivo_filesystem_server.dart';
import '../../../utils/app_directories.dart';

/// One Android SAF mount: a user-picked external directory (content:// tree
/// URI) mirrored into an app-private host directory.
///
/// The mirror — not the URI — is what the filesystem engine, the model tools
/// and the proot guest see; the sync service keeps the two sides in two-way
/// mirror sync (see `docs/adr/0037-android-saf-mount-mirror-sync.md`).
class SafMountEntry {
  final String alias;
  final String uri;
  final String displayName;
  final bool readOnly;

  const SafMountEntry({
    required this.alias,
    required this.uri,
    required this.displayName,
    this.readOnly = false,
  });

  Map<String, dynamic> toJson() => {
    'alias': alias,
    'uri': uri,
    'displayName': displayName,
    'readOnly': readOnly,
  };

  factory SafMountEntry.fromJson(Map<String, dynamic> json) => SafMountEntry(
    alias: (json['alias'] as String? ?? '').trim(),
    uri: (json['uri'] as String? ?? '').trim(),
    displayName: (json['displayName'] as String? ?? '').trim(),
    readOnly: json['readOnly'] as bool? ?? false,
  );
}

enum SafMountStatus {
  /// No round running; last round succeeded (or none ran yet).
  idle,

  /// A sync round is in flight.
  syncing,

  /// The SAF grant is gone (permission revoked / storage unmounted / the URI
  /// was restored from a backup onto another device). The mirror and all
  /// local changes are preserved; nothing is deleted or pushed.
  unavailable,

  /// The last round failed with a transient error; the next trigger retries.
  error,
}

class SafMountState {
  final SafMountStatus status;
  final String? lastError;
  final DateTime? lastSyncAt;

  const SafMountState({
    this.status = SafMountStatus.idle,
    this.lastError,
    this.lastSyncAt,
  });

  SafMountState copyWith({
    SafMountStatus? status,
    String? lastError,
    bool clearError = false,
    DateTime? lastSyncAt,
  }) => SafMountState(
    status: status ?? this.status,
    lastError: clearError ? null : (lastError ?? this.lastError),
    lastSyncAt: lastSyncAt ?? this.lastSyncAt,
  );
}

/// A directory entry as reported by the native SAF bridge.
class SafEntry {
  final String name;
  final bool isDirectory;
  final int? lastModifiedMs;
  final int? size;
  final String uri;

  const SafEntry({
    required this.name,
    required this.isDirectory,
    required this.uri,
    this.lastModifiedMs,
    this.size,
  });
}

/// Native SAF bridge (`cuplivo/saf_mount`). Methods are virtual so tests can
/// substitute a fake implementation.
class SafChannel {
  SafChannel() : _channel = const MethodChannel('cuplivo/saf_mount');

  static const Duration callTimeout = Duration(seconds: 30);

  final MethodChannel _channel;

  /// Launches ACTION_OPEN_DOCUMENT_TREE and persists the read/write grant.
  /// Returns `{uri, displayName}` or null when the user cancelled.
  Future<Map<String, dynamic>?> pickTree() async {
    final map = await _channel.invokeMethod<Map>('pickTree');
    return map?.cast<String, dynamic>();
  }

  Future<List<Map<String, dynamic>>> list(String uri) async {
    final raw = await _channel.invokeMethod<List>('list', {'uri': uri});
    return (raw ?? const <dynamic>[])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
  }

  Future<Uint8List> readFile(String uri) async {
    final bytes = await _channel.invokeMethod<Uint8List>('readFile', {
      'uri': uri,
    });
    if (bytes == null) throw StateError('readFile returned null for $uri');
    return bytes;
  }

  Future<void> writeFile(String uri, Uint8List bytes) async {
    await _channel.invokeMethod<void>('writeFile', {
      'uri': uri,
      'bytes': bytes,
    });
  }

  Future<String> createFile(String parentUri, String name) async {
    final uri = await _channel.invokeMethod<String>('createFile', {
      'parentUri': parentUri,
      'name': name,
    });
    if (uri == null) throw StateError('createFile returned null');
    return uri;
  }

  Future<String> mkdir(String parentUri, String name) async {
    final uri = await _channel.invokeMethod<String>('mkdir', {
      'parentUri': parentUri,
      'name': name,
    });
    if (uri == null) throw StateError('mkdir returned null');
    return uri;
  }

  Future<bool> delete(String uri) async {
    final ok = await _channel.invokeMethod<bool>('delete', {'uri': uri});
    return ok == true;
  }

  Future<bool> checkAccess(String uri) async {
    final ok = await _channel.invokeMethod<bool>('checkAccess', {'uri': uri});
    return ok == true;
  }

  /// Wraps [action] with a bounded timeout so a hung DocumentsProvider can
  /// never wedge a sync round forever.
  Future<T> withTimeout<T>(Future<T> Function() action) =>
      action().timeout(callTimeout);
}

/// Owns Android SAF mounts: config persistence, mirror locations, the
/// bidirectional mirror-sync engine, lifecycle triggers and the guest bind
/// list for the Linux sandbox.
///
/// Sync semantics (ADR-0037):
/// - Three-state merge by mtime+size; last-writer-wins, mtime ties resolved
///   to the mirror side (deterministic, documented).
/// - Deletions propagate BOTH ways, gated by a `.state/<alias>.json` snapshot
///   (a path must have existed at the last completed round before either side
///   deleting it counts as a deletion).
/// - Whole-tree-gone guard: an empty SAF side while the snapshot and the
///   mirror both disagree never propagates deletions (unmounted SD card /
///   revoked grant) — the round is aborted instead.
/// - A failed SAF access marks the mount `unavailable`; nothing is deleted
///   or pushed while unavailable, and the mirror keeps all local changes.
class SafMountSyncService extends ChangeNotifier with WidgetsBindingObserver {
  static const String prefsKey = 'saf_mounts_v1';
  static const String errorAliasInvalid = 'alias_invalid';
  static const String errorAliasReserved = 'alias_reserved';
  static const String errorAliasDuplicate = 'alias_duplicate';

  static const Duration mutationDebounce = Duration(milliseconds: 500);
  static const Duration foregroundPollInterval = Duration(seconds: 60);
  static const Duration resumeDebounce = Duration(seconds: 1);

  /// Overridable platform gate so tests can exercise the Android code path
  /// on any host.
  static bool Function() androidProbe = () => Platform.isAndroid;

  /// mtime tolerance for the "same entry" comparison: SAF providers report
  /// second-resolution mtimes in practice, so a few hundred ms of jitter
  /// must not count as a change.
  static const Duration mtimeTolerance = Duration(milliseconds: 1500);

  final List<SafMountEntry> _entries = <SafMountEntry>[];
  final Map<String, SafMountState> _states = <String, SafMountState>{};
  final Set<String> _running = <String>{};
  final Map<String, Timer> _debounceTimers = <String, Timer>{};
  Timer? _pollTimer;
  bool _loaded = false;
  Future<void>? _initFuture;
  late String _mirrorsRoot;
  late String _stateRoot;

  /// Extra aliases that must never collide with a SAF alias (the workspace
  /// aliases). Injected by the wiring layer because the provider tree
  /// initializes both independently.
  late Set<String> Function() reservedAliasesProvider;

  SafChannel channel;

  SafMountSyncService({
    SafChannel? channel,
    Set<String> Function()? reservedAliasesProvider,
  }) : channel = channel ?? SafChannel() {
    this.reservedAliasesProvider =
        reservedAliasesProvider ?? () => const <String>{};
    unawaited(init());
  }

  bool get loaded => _loaded;

  List<SafMountEntry> get entries => List.unmodifiable(_entries);

  SafMountEntry? entryByAlias(String alias) =>
      _entries.where((e) => e.alias == alias).firstOrNull;

  /// `workspace_N` aliases are the auto-allocation scheme of the workspace
  /// provider; a SAF mount on such an alias would collide with
  /// `_isSyncedWorkspaceMount` (markers/tombstones fire for SAF deletions)
  /// and with a future workspace creation. Reserved like `default`.
  static bool _isWorkspacePatternAlias(String alias) =>
      RegExp(r'^workspace_\d+$').hasMatch(alias);

  List<FilesystemMount> get mounts {
    if (!_loaded) return const <FilesystemMount>[];
    return [
      for (final e in _entries)
        FilesystemMount(
          alias: e.alias,
          path: mirrorPathFor(e.alias),
          readOnly: e.readOnly,
          uri: e.uri,
        ),
    ];
  }

  SafMountState stateOf(String alias) =>
      _states[alias] ?? const SafMountState();

  /// proot bind payloads (`{host, guest, readOnly}`) for the Linux sandbox
  /// shell and the Workspace Terminal. Guests land under the reserved
  /// `/workspace/.mounts/<alias>` directory (ADR-0037). `readOnly` is a real
  /// boolean — the native parser compares against `true`. Empty until [init]
  /// completes (a pre-init read must never touch the late mirror root).
  List<Map<String, Object?>> get guestBinds {
    if (!_loaded) return const <Map<String, Object?>>[];
    return [
      for (final e in _entries)
        {
          'host': mirrorPathFor(e.alias),
          'guest': '/workspace/.mounts/${e.alias}',
          'readOnly': e.readOnly,
        },
    ];
  }

  String mirrorPathFor(String alias) => p.join(_mirrorsRoot, alias);

  String statePathFor(String alias) => p.join(_stateRoot, '$alias.json');

  Future<void> init() {
    if (_loaded) return Future.value();
    return _initFuture ??= _doInit();
  }

  Future<void> _doInit() async {
    try {
      WidgetsBinding.instance.addObserver(this);
    } catch (_) {
      // Headless tests without a binding: lifecycle triggers stay inert.
    }
    final mirrors = await AppDirectories.getSafMountsDirectory();
    final stateDir = await AppDirectories.getSafMountStateDirectory();
    _mirrorsRoot = mirrors.path;
    _stateRoot = stateDir.path;
    try {
      await stateDir.create(recursive: true);
    } catch (e) {
      debugPrint('SafMountSyncService: state dir create failed: $e');
    }
    final prefs = await SharedPreferences.getInstance();
    if (androidProbe()) {
      final raw = prefs.getString(prefsKey);
      if (raw != null && raw.isNotEmpty) {
        try {
          final list = (jsonDecode(raw) as List)
              .whereType<Map>()
              .map((e) => SafMountEntry.fromJson(e.cast<String, dynamic>()))
              .toList();
          for (final e in list) {
            if (!isValidMountAlias(e.alias) || e.uri.isEmpty) {
              debugPrint(
                'SafMountSyncService: skipping invalid persisted mount: '
                '${e.alias}',
              );
              continue;
            }
            if (_isWorkspacePatternAlias(e.alias) ||
                reservedAliasesProvider().contains(e.alias)) {
              debugPrint(
                'SafMountSyncService: skipping mount alias colliding with a '
                'workspace: ${e.alias}',
              );
              continue;
            }
            _entries.add(e);
          }
        } catch (e) {
          debugPrint('SafMountSyncService: failed to load mounts: $e');
        }
      }
    } else {
      // Config may ride a backup's settings.json onto desktop/iOS — keep it
      // persisted but never mounted (same pattern as desktop external
      // mounts on mobile, mirrored).
      _entries.clear();
    }
    await _ensureMirrorDirs();
    _loaded = true;
    notifyListeners();
  }

  Future<void> _ensureMirrorDirs() async {
    for (final e in _entries) {
      try {
        await Directory(mirrorPathFor(e.alias)).create(recursive: true);
      } catch (err) {
        debugPrint(
          'SafMountSyncService: failed to create mirror for '
          '${e.alias}: $err',
        );
      }
    }
  }

  /// Launches the SAF directory picker (user grants read/write). Returns
  /// `{uri, displayName}` or null when cancelled.
  ///
  /// Deliberately NOT wrapped in [SafChannel.withTimeout]: the picker is an
  /// interactive full-screen browser that can legitimately stay open for
  /// minutes; a timeout would drop the result while the native side still
  /// holds the pending reply (the grant is persisted but the UI never hears
  /// about it).
  Future<Map<String, dynamic>?> pickTree() => channel.pickTree();

  /// Returns null on success or an error code for the UI to localize.
  Future<String?> addMount({
    required String alias,
    required String uri,
    required String displayName,
    bool readOnly = false,
  }) async {
    await init();
    final trimmed = alias.trim();
    if (!isValidMountAlias(trimmed)) return errorAliasInvalid;
    if (_isWorkspacePatternAlias(trimmed) ||
        reservedAliasesProvider().contains(trimmed)) {
      return errorAliasReserved;
    }
    if (_entries.any((e) => e.alias == trimmed)) {
      return errorAliasDuplicate;
    }
    final entry = SafMountEntry(
      alias: trimmed,
      uri: uri.trim(),
      displayName: displayName.trim(),
      readOnly: readOnly,
    );
    try {
      await Directory(mirrorPathFor(trimmed)).create(recursive: true);
    } catch (e) {
      debugPrint('SafMountSyncService: mirror create failed: $e');
      return errorAliasInvalid;
    }
    _entries.add(entry);
    try {
      await _persist();
    } catch (e) {
      // The config lives in memory regardless; a failed persist only means
      // the mount may not survive a restart. Do not fail the UI flow.
      debugPrint('SafMountSyncService: persist failed after add: $e');
    }
    notifyListeners();
    // Initial full pull completes before addMount returns: the caller's UI
    // sees a converged mirror, and tests get deterministic sequencing.
    await syncNow(trimmed);
    return null;
  }

  Future<void> removeMount(String alias) async {
    await init();
    _entries.removeWhere((e) => e.alias == alias);
    _states.remove(alias);
    _debounceTimers.remove(alias)?.cancel();
    await _persist();
    notifyListeners();
    try {
      final mirror = Directory(mirrorPathFor(alias));
      if (await mirror.exists()) await mirror.delete(recursive: true);
    } catch (e) {
      debugPrint('SafMountSyncService: mirror cleanup failed for $alias: $e');
    }
    try {
      final state = File(statePathFor(alias));
      if (await state.exists()) await state.delete();
    } catch (e) {
      debugPrint('SafMountSyncService: state cleanup failed for $alias: $e');
    }
  }

  /// Called by the filesystem engine after an AI tool mutated a mount —
  /// schedules a debounced push round for SAF mounts.
  void notifyMutated(String alias) {
    if (entryByAlias(alias) == null) return;
    _debounceTimers.remove(alias)?.cancel();
    _debounceTimers[alias] = Timer(mutationDebounce, () {
      _debounceTimers.remove(alias);
      unawaited(syncNow(alias));
    });
  }

  Future<void> syncAll() async {
    await init();
    final aliases = _entries.map((e) => e.alias).toList();
    for (final alias in aliases) {
      await syncNow(alias);
    }
  }

  Future<void> syncNow(String alias) async {
    await init();
    final entry = entryByAlias(alias);
    if (entry == null || !_running.add(alias)) return;
    try {
      final state = stateOf(alias);
      _states[alias] = state.copyWith(
        status: SafMountStatus.syncing,
        clearError: true,
      );
      notifyListeners();
      try {
        final deleteFailed = await _syncRound(entry);
        if (deleteFailed) {
          // The provider persistently refused a delete (no exception): the
          // snapshot entry is retained and the next round retries — but the
          // UI must not claim "Synced" while a deletion never lands.
          _states[alias] = _states[alias]!.copyWith(
            status: SafMountStatus.error,
            lastError: 'SAF delete failed; will retry',
          );
        } else {
          _states[alias] = _states[alias]!.copyWith(
            status: SafMountStatus.idle,
            lastSyncAt: DateTime.now(),
          );
        }
      } on SafAccessException catch (e) {
        debugPrint('SafMountSyncService: $alias unavailable: $e');
        _states[alias] = _states[alias]!.copyWith(
          status: SafMountStatus.unavailable,
          lastError: e.message,
        );
      } catch (e) {
        debugPrint('SafMountSyncService: sync failed for $alias: $e');
        _states[alias] = _states[alias]!.copyWith(
          status: SafMountStatus.error,
          lastError: e.toString(),
        );
      } finally {
        notifyListeners();
      }
    } finally {
      _running.remove(alias);
    }
  }

  // =====================================================================
  // Sync engine
  // =====================================================================

  static bool _isAccessError(Object e) {
    if (e is PlatformException) {
      return e.code == 'access_denied' ||
          e.code == 'access_failed' ||
          e.code == 'uri_not_found';
    }
    return false;
  }

  /// Runs one full two-way merge round. Returns true when a SAF-side delete
  /// was persistently refused (the round completed, but a deletion never
  /// landed and the snapshot entry was retained for retry).
  Future<bool> _syncRound(SafMountEntry entry) async {
    final uri = entry.uri;
    final mirrorRoot = Directory(mirrorPathFor(entry.alias));
    // The mount may have been removed while this round was queued behind the
    // execution lock (removeMount does not cancel in-flight rounds). If it is
    // gone, abort BEFORE touching the mirror or the SAF side — the mirror
    // directory may already be deleted, and pass 3 would otherwise misread
    // the missing mirror content as "deleted in the mirror" and delete the
    // user's real files.
    if (entryByAlias(entry.alias) == null) return false;
    await mirrorRoot.create(recursive: true);

    final snapshot = await _readSnapshot(entry.alias);

    bool accessOk;
    try {
      accessOk = await channel.withTimeout(() => channel.checkAccess(uri));
    } catch (e) {
      throw SafAccessException('SAF grant unavailable: $e');
    }
    if (!accessOk) {
      throw SafAccessException('SAF grant revoked or storage unmounted');
    }

    Map<String, SafEntry> safTree;
    try {
      safTree = await channel.withTimeout(() => _listSafTree(uri));
    } on PlatformException catch (e) {
      if (_isAccessError(e)) throw SafAccessException(e.message ?? e.code);
      rethrow;
    }

    // Whole-tree-gone guard: the SAF side lists empty while the previous
    // snapshot knew content. An unmounted volume (SD card) typically reports
    // an empty tree — treating it as deletions would wipe snapshot-known
    // mirror files, INCLUDING AI edits never pushed. Abort instead; nothing
    // real is lost (files re-pull after remount), and a genuinely emptied
    // folder can be re-mounted to start fresh.
    if (snapshot.isNotEmpty && safTree.isEmpty) {
      throw SafAccessException(
        'SAF tree listed empty while the previous snapshot knew content — '
        'storage likely unmounted; aborting round',
      );
    }

    final mirrorTree = await _listMirrorTree(mirrorRoot);
    final next = <String, _StatSnapshot>{};
    var deleteFailed = false;
    // URIs of directories created on the SAF side during THIS round, so
    // child pushes find their parents without re-walking the whole tree.
    final createdSafDirs = <String, String>{};

    // Pass 1: entries present on the SAF side.
    for (final rel in safTree.keys) {
      final saf = safTree[rel]!;
      final mir = mirrorTree[rel];
      if (saf.isDirectory) {
        final target = Directory(p.join(mirrorRoot.path, rel));
        final mirrorHasFile = await File(target.path).exists();
        if (mirrorHasFile) {
          // Type conflict: mirror has a FILE where SAF has a directory. The
          // newer side wins (LWW): if the mirror file is newer, push it
          // (deletes the SAF dir, creates the file); otherwise the SAF dir
          // wins and the conflicting file is removed so the dir can exist.
          final mir = mirrorTree[rel];
          final safM = saf.lastModifiedMs ?? 0;
          final mirM = mir?.lastModifiedMs ?? 0;
          if (mirM > safM) {
            final updated = await _pushMirrorAndAlign(
              entry,
              saf,
              mirrorRoot,
              rel,
              safTree,
              createdSafDirs,
            );
            next[rel] = updated;
            continue;
          }
          try {
            await File(target.path).delete();
          } catch (e) {
            debugPrint('SafMountSyncService: conflict file delete failed: $e');
          }
        }
        if (!await target.exists()) {
          if (snapshot.containsKey(rel)) {
            // Pending mirror-side deletion (ADR-0037): pass 3 removes the
            // SAF side; never resurrect the directory here.
            continue;
          }
          await target.create(recursive: true);
        }
        next[rel] = _StatSnapshot(
          mtimeMs: saf.lastModifiedMs,
          size: 0,
          isDir: true,
        );
        continue;
      }
      if (mir == null) {
        if (snapshot.containsKey(rel)) {
          // Pending mirror-side deletion: the file was deleted in the mirror
          // after the last completed round — pass 3 propagates the deletion
          // to the SAF side. Copying it back here would resurrect it (and a
          // delete-then-recreate by the AI within the poll window would then
          // be misread as a deletion on the next round and destroyed).
          continue;
        }
        await _copySafToMirror(entry, saf, mirrorRoot, rel);
        next[rel] = _snapshotOf(saf);
        continue;
      }
      if (_sameEntry(saf, mir)) {
        next[rel] = _snapshotOf(saf);
        continue;
      }
      final safM = saf.lastModifiedMs ?? 0;
      final mirM = mir.lastModifiedMs ?? 0;
      if (safM > mirM) {
        await _copySafToMirror(entry, saf, mirrorRoot, rel);
        next[rel] = _snapshotOf(saf);
      } else {
        // Mirror side is newer or it's an mtime tie — the mirror wins (tie
        // rule, ADR-0037). The push below then re-stats the SAF side so the
        // two converge without a ping-pong pull round.
        next[rel] = await _pushMirrorAndAlign(
          entry,
          saf,
          mirrorRoot,
          rel,
          safTree,
          createdSafDirs,
        );
      }
    }

    // Pass 2: entries present only on the mirror side.
    for (final rel in mirrorTree.keys) {
      if (safTree.containsKey(rel)) continue;
      final mir = mirrorTree[rel]!;
      final existed = snapshot.containsKey(rel);
      if (existed) {
        // Propagate the deletion: the path existed at the last completed
        // round and is now gone from the SAF side while the mirror still
        // has it — the user (or AI) deleted it.
        if (await _deleteSafEntry(entry, rel, safTree)) {
          await _removeRecursive(p.join(mirrorRoot.path, rel));
        } else {
          // SAF-side delete failed (transient provider error): keep the
          // snapshot entry so the next round retries instead of treating the
          // mirror file as brand-new content and pushing it back.
          next[rel] = _snapshotOfMirror(mir);
          deleteFailed = true;
        }
        continue;
      }
      // Brand-new mirror content (AI wrote it): push to SAF.
      await _pushMirrorToSaf(
        entry,
        safTree[rel],
        mirrorRoot,
        rel,
        safTree,
        createdSafDirs,
      );
      final updated = await _statSafAfterPush(
        entry,
        null,
        rel,
        safTree,
        createdSafDirs,
      );
      next[rel] = updated;
    }

    // Pass 3: mirror-side deletions propagate to SAF. A path that existed at
    // the last completed round, still exists on the SAF side, and is gone
    // from the mirror was deleted in the mirror (AI / user) — delete it on
    // the SAF side too. (The reverse direction — SAF gone, mirror kept — is
    // pass 2.)
    if (entryByAlias(entry.alias) == null) {
      // Removed mid-round (e.g. by clearAllData or the remove dialog): skip
      // deletion propagation entirely — the mirror was already deleted and
      // pass 3 would treat its absence as deletions in the user's real dir.
      return deleteFailed;
    }
    for (final rel in snapshot.keys) {
      final safHas = safTree.containsKey(rel);
      final mirHas = mirrorTree.containsKey(rel);
      if (safHas && !mirHas) {
        if (!await _deleteSafEntry(entry, rel, safTree)) {
          deleteFailed = true;
          // Keep the snapshot entry so the next round RETRIES the deletion.
          // Pass 1 skips snapshot-known mirror-missing paths as pending
          // deletions and would otherwise drop them from `next` — the
          // failed delete would then be forgotten forever.
          final saf = safTree[rel];
          if (saf != null) {
            next[rel] = _snapshotOf(saf);
          }
        }
      }
    }

    await _writeSnapshot(entry.alias, next);
    return deleteFailed;
  }

  bool _sameEntry(SafEntry saf, _MirrorEntry mir) {
    // A file↔directory conflict at the same path is NEVER "same" — the
    // merge must resolve it (newer side wins) instead of silently diverging.
    if (saf.isDirectory != mir.isDirectory) return false;
    if (saf.size != mir.size) return false;
    final safM = saf.lastModifiedMs;
    final mirM = mir.lastModifiedMs;
    if (safM == null || mirM == null) return saf.size == mir.size;
    return (safM - mirM).abs() <= mtimeTolerance.inMilliseconds;
  }

  static _StatSnapshot _snapshotOf(SafEntry saf) => _StatSnapshot(
    mtimeMs: saf.lastModifiedMs,
    size: saf.size ?? 0,
    isDir: saf.isDirectory,
  );

  static _StatSnapshot _snapshotOfMirror(_MirrorEntry m) => _StatSnapshot(
    mtimeMs: m.lastModifiedMs,
    size: m.size,
    isDir: m.isDirectory,
  );

  Future<void> _copySafToMirror(
    SafMountEntry entry,
    SafEntry saf,
    Directory mirrorRoot,
    String rel,
  ) async {
    final target = File(p.join(mirrorRoot.path, rel));
    if (await Directory(target.path).exists()) {
      // Type conflict: a directory sits where the SAF file must land —
      // remove it so the file can be written (newer side wins).
      await _removeRecursive(target.path);
    }
    await target.parent.create(recursive: true);
    final bytes = await channel.withTimeout(() => channel.readFile(saf.uri));
    // Temp file lives OUTSIDE the mirror walk root (.state/): an interrupted
    // round (process death) must never leave a .saf_tmp entry inside the
    // mirror, which the next round would misread as brand-new mirror content
    // and push into the user's real directory. Same-volume rename stays
    // atomic; per-alias single-flight guarantees a fixed temp name is safe.
    final tmp = File(p.join(_stateRoot, '${entry.alias}_copy_tmp'));
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(target.path);
    final mtime = saf.lastModifiedMs;
    if (mtime != null) {
      try {
        await target.setLastModified(
          DateTime.fromMillisecondsSinceEpoch(mtime),
        );
      } catch (_) {}
    }
  }

  /// Pushes the mirror's content for [rel] to the SAF side and aligns the
  /// mirror mtime to the post-push SAF stat so the two converge without a
  /// ping-pong pull round. Returns the post-push snapshot stat.
  Future<_StatSnapshot> _pushMirrorAndAlign(
    SafMountEntry entry,
    SafEntry saf,
    Directory mirrorRoot,
    String rel,
    Map<String, SafEntry> safTree,
    Map<String, String> createdSafDirs,
  ) async {
    await _pushMirrorToSaf(
      entry,
      saf,
      mirrorRoot,
      rel,
      safTree,
      createdSafDirs,
    );
    final updated = await _statSafAfterPush(
      entry,
      saf,
      rel,
      safTree,
      createdSafDirs,
    );
    final safM = saf.lastModifiedMs ?? 0;
    if (updated.mtimeMs != null && updated.mtimeMs != safM) {
      try {
        final f = File(p.join(mirrorRoot.path, rel));
        await f.setLastModified(
          DateTime.fromMillisecondsSinceEpoch(updated.mtimeMs!),
        );
      } catch (e) {
        debugPrint('SafMountSyncService: mirror mtime align failed: $e');
      }
    }
    return updated;
  }

  /// Pushes one mirror file into the SAF side. [safEntry] may be null when
  /// the path has no SAF counterpart yet (brand-new mirror file). Parent
  /// lookups reuse the round's [safTree] plus [createdSafDirs] so pushes
  /// never re-walk the whole SAF tree.
  Future<void> _pushMirrorToSaf(
    SafMountEntry entry,
    SafEntry? safEntry,
    Directory mirrorRoot,
    String rel,
    Map<String, SafEntry> safTree,
    Map<String, String> createdSafDirs,
  ) async {
    final file = File(p.join(mirrorRoot.path, rel));
    if (await Directory(file.path).exists()) {
      if (safEntry != null && !safEntry.isDirectory) {
        // Type conflict: SAF has a file where the mirror has a directory —
        // delete the SAF file so the directory can be created (newer side
        // wins).
        try {
          await channel.withTimeout(() => channel.delete(safEntry.uri));
        } catch (e) {
          debugPrint('SafMountSyncService: conflict SAF delete failed: $e');
        }
      }
      if (safEntry == null || !safEntry.isDirectory) {
        final parentUri = await _ensureParentSafDir(
          entry,
          rel,
          safTree,
          createdSafDirs,
        );
        final created = await channel.withTimeout(
          () => channel.mkdir(parentUri, p.basename(rel)),
        );
        createdSafDirs[rel] = created;
      }
      return;
    }
    final bytes = await file.readAsBytes();
    if (safEntry != null) {
      if (!safEntry.isDirectory) {
        await channel.withTimeout(() => channel.writeFile(safEntry.uri, bytes));
        return;
      }
      // Type conflict: SAF has a directory where the mirror has a file —
      // delete it, then fall through to create the file.
      await channel.withTimeout(() => channel.delete(safEntry.uri));
    }
    // New file (or post-conflict): create in the SAF parent directory, then
    // write.
    final parentUri = await _ensureParentSafDir(
      entry,
      rel,
      safTree,
      createdSafDirs,
    );
    final created = await channel.withTimeout(
      () => channel.createFile(parentUri, p.basename(rel)),
    );
    await channel.withTimeout(() => channel.writeFile(created, bytes));
  }

  /// Resolves the SAF URI of the parent directory of [rel], creating any
  /// missing ancestor directories top-down on the SAF side. Created
  /// directories are memoized in [createdSafDirs] so siblings reuse them
  /// without extra channel round-trips.
  Future<String> _ensureParentSafDir(
    SafMountEntry entry,
    String rel,
    Map<String, SafEntry> safTree,
    Map<String, String> createdSafDirs,
  ) async {
    final parentRel = p.dirname(rel);
    if (parentRel == '.') return entry.uri;
    final cached = createdSafDirs[parentRel];
    if (cached != null) return cached;
    var currentUri = entry.uri;
    final prefix = <String>[];
    for (final part in parentRel.split('/')) {
      prefix.add(part);
      final key = prefix.join('/');
      final cachedChild = createdSafDirs[key];
      if (cachedChild != null) {
        currentUri = cachedChild;
        continue;
      }
      final existing = safTree[key];
      if (existing != null) {
        currentUri = existing.uri;
        continue;
      }
      final created = await channel.withTimeout(
        () => channel.mkdir(currentUri, part),
      );
      createdSafDirs[key] = created;
      currentUri = created;
    }
    return currentUri;
  }

  /// Re-stats the just-written SAF entry so the mirror mtime can be aligned
  /// and the snapshot records the post-push truth (prevents a pull-back
  /// round on the next sync). Only the PARENT directory is re-listed — one
  /// channel round-trip instead of a full-tree walk. Falls back to the
  /// pre-push [safEntry] stat when the re-stat fails (the mtime tolerance
  /// absorbs the provider-side rewrite and the next round converges).
  Future<_StatSnapshot> _statSafAfterPush(
    SafMountEntry entry,
    SafEntry? safEntry,
    String rel,
    Map<String, SafEntry> safTree,
    Map<String, String> createdSafDirs,
  ) async {
    try {
      final parentRel = p.dirname(rel);
      final parentUri = parentRel == '.'
          ? entry.uri
          // createdSafDirs first: a type-conflict may have REPLACED the SAF
          // entry during this round, leaving a stale URI in safTree.
          : (createdSafDirs[parentRel] ?? safTree[parentRel]?.uri);
      if (parentUri != null) {
        final raw = await channel.withTimeout(() => channel.list(parentUri));
        final name = p.basename(rel);
        for (final m in raw) {
          if ((m['name'] ?? '').toString() == name) {
            return _StatSnapshot(
              mtimeMs: (m['lastModified'] as num?)?.toInt(),
              size: (m['size'] as num?)?.toInt() ?? 0,
              isDir: m['isDirectory'] == true,
            );
          }
        }
      }
    } catch (e) {
      debugPrint('SafMountSyncService: post-push stat failed: $e');
    }
    if (safEntry != null) return _snapshotOf(safEntry);
    return const _StatSnapshot(mtimeMs: null, size: 0, isDir: false);
  }

  Future<bool> _deleteSafEntry(
    SafMountEntry entry,
    String rel,
    Map<String, SafEntry> safTree,
  ) async {
    final saf = safTree[rel];
    if (saf == null) return true;
    try {
      return await channel.withTimeout(() => channel.delete(saf.uri));
    } catch (e) {
      debugPrint('SafMountSyncService: SAF delete failed for $rel: $e');
      return false;
    }
  }

  Future<void> _removeRecursive(String path) async {
    final f = File(path);
    try {
      if (await f.exists()) {
        await f.delete();
        return;
      }
    } catch (_) {}
    try {
      final d = Directory(path);
      if (await d.exists()) await d.delete(recursive: true);
    } catch (e) {
      debugPrint('SafMountSyncService: mirror delete failed for $path: $e');
    }
  }

  Future<Map<String, SafEntry>> _listSafTree(String rootUri) async {
    final out = <String, SafEntry>{};
    await _walkSaf(rootUri, '.', out);
    return out;
  }

  Future<void> _walkSaf(
    String uri,
    String relPrefix,
    Map<String, SafEntry> out,
  ) async {
    final raw = await channel.list(uri);
    final entries = <SafEntry>[];
    for (final m in raw) {
      final name = (m['name'] ?? '').toString();
      if (name.isEmpty) continue;
      if (name == '.' || name == '..') continue;
      final childUri = (m['uri'] ?? '').toString();
      if (childUri.isEmpty) continue;
      final entry = SafEntry(
        name: name,
        isDirectory: m['isDirectory'] == true,
        uri: childUri,
        lastModifiedMs: (m['lastModified'] as num?)?.toInt(),
        size: (m['size'] as num?)?.toInt(),
      );
      entries.add(entry);
    }
    entries.sort((a, b) => a.name.compareTo(b.name));
    for (final e in entries) {
      final rel = relPrefix == '.' ? e.name : '$relPrefix/${e.name}';
      out[rel] = e;
      if (e.isDirectory) {
        await _walkSaf(e.uri, rel, out);
      }
    }
  }

  Future<Map<String, _MirrorEntry>> _listMirrorTree(Directory root) async {
    final out = <String, _MirrorEntry>{};
    await _walkMirror(root, root.path, '.', out);
    return out;
  }

  Future<void> _walkMirror(
    Directory root,
    String dirPath,
    String relPrefix,
    Map<String, _MirrorEntry> out,
  ) async {
    List<FileSystemEntity> children;
    try {
      children = await Directory(dirPath).list(followLinks: false).toList();
    } catch (e) {
      // A failed mirror walk must ABORT the round instead of silently
      // dropping the subtree: pass 3 would misread the missing paths as
      // mirror-side deletions and delete the corresponding files in the
      // user's real directory (ADR-0037 removal race).
      debugPrint('SafMountSyncService: mirror walk failed at $dirPath: $e');
      rethrow;
    }
    children.sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
    for (final child in children) {
      final name = p.basename(child.path);
      final rel = relPrefix == '.' ? name : '$relPrefix/$name';
      if (name.endsWith('.saf_tmp')) {
        // Stale copy temp from a pre-ADR-0037-build interruption (older
        // versions wrote temps inside the mirror). Prune instead of
        // treating it as brand-new mirror content (which would push it into
        // the user's real directory).
        try {
          if (child is Directory) {
            await child.delete(recursive: true);
          } else {
            await child.delete();
          }
        } catch (e) {
          debugPrint('SafMountSyncService: stale tmp prune failed: $e');
        }
        continue;
      }
      if (child is Directory) {
        out[rel] = _MirrorEntry(
          isDirectory: true,
          size: 0,
          lastModifiedMs: _safeMtime(child),
        );
        await _walkMirror(root, child.path, rel, out);
      } else if (child is File) {
        int size;
        int? mtime;
        try {
          size = await child.length();
        } catch (_) {
          size = 0;
        }
        mtime = _safeMtime(child);
        out[rel] = _MirrorEntry(
          isDirectory: false,
          size: size,
          lastModifiedMs: mtime,
        );
      } else if (child is Link) {
        // A symlink in the mirror (e.g. created inside the proot guest at
        // /workspace/.mounts/<alias>) cannot be mirrored to SAF and must
        // never be misread as a deletion — abort the round loudly instead;
        // the mount resumes once the link is removed.
        debugPrint(
          'SafMountSyncService: mirror contains a symbolic link at '
          '${child.path}; aborting round — remove the link to resume sync',
        );
        throw StateError('Mirror contains a symbolic link: ${child.path}');
      }
    }
  }

  static int? _safeMtime(FileSystemEntity entity) {
    try {
      return entity.statSync().modified.millisecondsSinceEpoch;
    } catch (_) {
      return null;
    }
  }

  // =====================================================================
  // Snapshot persistence
  // =====================================================================

  Future<Map<String, _StatSnapshot>> _readSnapshot(String alias) async {
    final f = File(statePathFor(alias));
    try {
      if (!await f.exists()) return <String, _StatSnapshot>{};
      final raw = await f.readAsString();
      final map = (jsonDecode(raw) as Map).cast<String, dynamic>();
      return {
        for (final e in map.entries)
          e.key: _StatSnapshot.fromJson(
            (e.value as Map).cast<String, dynamic>(),
          ),
      };
    } catch (e) {
      debugPrint('SafMountSyncService: snapshot read failed for $alias: $e');
      return <String, _StatSnapshot>{};
    }
  }

  Future<void> _writeSnapshot(
    String alias,
    Map<String, _StatSnapshot> snapshot,
  ) async {
    try {
      await Directory(_stateRoot).create(recursive: true);
      final f = File(statePathFor(alias));
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(
        jsonEncode({for (final e in snapshot.entries) e.key: e.value.toJson()}),
        flush: true,
      );
      await tmp.rename(f.path);
    } catch (e) {
      debugPrint('SafMountSyncService: snapshot write failed for $alias: $e');
    }
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      prefsKey,
      jsonEncode(_entries.map((e) => e.toJson()).toList()),
    );
  }

  // =====================================================================
  // Lifecycle: resume sync + foreground polling
  // =====================================================================

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _setForeground(true);
      Timer(resumeDebounce, () => unawaited(syncAll()));
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _setForeground(false);
    }
  }

  void _setForeground(bool foreground) {
    if (foreground) {
      _pollTimer ??= Timer.periodic(
        foregroundPollInterval,
        (_) => unawaited(syncAll()),
      );
    } else {
      _pollTimer?.cancel();
      _pollTimer = null;
    }
  }
}

/// Raised when the SAF grant is missing or the provider rejects access.
/// The round aborts without deleting or pushing anything.
class SafAccessException implements Exception {
  final String message;
  SafAccessException(this.message);
  @override
  String toString() => message;
}

/// Mirrored-entry stat for the three-state comparison.
class _MirrorEntry {
  final bool isDirectory;
  final int size;
  final int? lastModifiedMs;

  const _MirrorEntry({
    required this.isDirectory,
    required this.size,
    this.lastModifiedMs,
  });
}

/// Snapshot stat for deletion gating. `mtimeMs: null` means "unknown" (the
/// entry then matches any mtime — never triggers a change by itself).
class _StatSnapshot {
  final int? mtimeMs;
  final int size;
  final bool isDir;

  const _StatSnapshot({
    required this.mtimeMs,
    required this.size,
    required this.isDir,
  });

  Map<String, dynamic> toJson() => {'m': mtimeMs, 's': size, 'd': isDir};

  factory _StatSnapshot.fromJson(Map<String, dynamic> json) => _StatSnapshot(
    mtimeMs: (json['m'] as num?)?.toInt(),
    size: (json['s'] as num?)?.toInt() ?? 0,
    isDir: json['d'] as bool? ?? false,
  );
}
