import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:Cuplivo/theme/app_font_weights.dart';

import '../../../core/services/chat/chat_service.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../utils/app_directories.dart';
import '../../../utils/format.dart';

/// A single workspace file shown in [WorkspaceFilesPage].
class WorkspaceFileEntry {
  final String wirePath;
  final String hostPath;
  final int size;
  final DateTime modifiedAt;

  const WorkspaceFileEntry({
    required this.wirePath,
    required this.hostPath,
    required this.size,
    required this.modifiedAt,
  });
}

enum _SortMode { time, size, name }

/// Standalone listing of the `@workspaces` sandbox: pure path + size + mtime.
///
/// Deliberately independent of the images/files category pages: workspace
/// files are never referenced via `[image:]`/`[file:]` markers, so no
/// refCount / orphan machinery applies (see CONTEXT.md "Filesystem MCP").
/// Deleting from this page goes through the same marker protocol as the
/// `kelivo_delete` tool (physical delete + origin='local' marker).
class WorkspaceFilesPage extends StatefulWidget {
  const WorkspaceFilesPage({super.key});

  @override
  State<WorkspaceFilesPage> createState() => _WorkspaceFilesPageState();
}

class _WorkspaceFilesPageState extends State<WorkspaceFilesPage> {
  List<WorkspaceFileEntry> _entries = const [];
  bool _loading = true;
  _SortMode _sortMode = _SortMode.time;
  bool _sortAsc = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final dir = await AppDirectories.getWorkspacesDirectory();
      final entries = <WorkspaceFileEntry>[];
      if (await dir.exists()) {
        // followLinks: false — symlinks are never followed in scans.
        await for (final ent in dir.list(recursive: true, followLinks: false)) {
          if (ent is! File) continue;
          final rel = ent.path.substring(dir.path.length + 1);
          if (rel.split(RegExp(r'[\\/]')).any((s) => s.startsWith('.'))) {
            continue;
          }
          try {
            final stat = await ent.stat();
            entries.add(
              WorkspaceFileEntry(
                wirePath: '@workspaces/${rel.replaceAll('\\', '/')}',
                hostPath: ent.path,
                size: stat.size,
                modifiedAt: stat.modified,
              ),
            );
          } catch (_) {
            // unreadable entry — skip
          }
        }
      }
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      showAppSnackBar(
        context,
        message: l10n.workspaceFilesLoadFailed(e.toString()),
        type: NotificationType.error,
      );
    }
  }

  AppLocalizations get l10n => AppLocalizations.of(context)!;

  List<WorkspaceFileEntry> get _sorted {
    final list = List<WorkspaceFileEntry>.of(_entries);
    int compare(WorkspaceFileEntry a, WorkspaceFileEntry b) {
      switch (_sortMode) {
        case _SortMode.size:
          return a.size.compareTo(b.size);
        case _SortMode.name:
          return a.wirePath.toLowerCase().compareTo(b.wirePath.toLowerCase());
        case _SortMode.time:
          return a.modifiedAt.compareTo(b.modifiedAt);
      }
    }

    list.sort((a, b) => _sortAsc ? compare(a, b) : compare(b, a));
    return list;
  }

  Future<void> _confirmDelete(WorkspaceFileEntry entry) async {
    final l10n = this.l10n;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.workspaceFilesDeleteConfirmTitle),
        content: Text(l10n.workspaceFilesDeleteConfirmMessage(entry.wirePath)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.homePageCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.workspaceFilesDeleteButton),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final f = File(entry.hostPath);
      if (await f.exists()) await f.delete();
      if (!mounted) return;
      final store = context.read<ChatService>().deletedRecordsStore;
      if (store != null) {
        await store.recordFileDeletion(
          id: entry.wirePath,
          deletedAt: DateTime.now(),
        );
      }
      await _load();
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: l10n.workspaceFilesDeleted(entry.wirePath),
        type: NotificationType.success,
      );
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: l10n.workspaceFilesDeleteFailed(e.toString()),
        type: NotificationType.error,
      );
    }
  }

  void _toggleSort(_SortMode mode) {
    setState(() {
      if (_sortMode == mode) {
        _sortAsc = !_sortAsc;
      } else {
        _sortMode = mode;
        _sortAsc = false;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = this.l10n;

    final sortBar = Row(
      children: [
        _SortChip(
          label: l10n.storageSpaceSortByTime,
          active: _sortMode == _SortMode.time,
          onTap: () => _toggleSort(_SortMode.time),
        ),
        const SizedBox(width: 8),
        _SortChip(
          label: l10n.storageSpaceSortBySize,
          active: _sortMode == _SortMode.size,
          onTap: () => _toggleSort(_SortMode.size),
        ),
        const SizedBox(width: 8),
        _SortChip(
          label: l10n.workspaceFilesSortName,
          active: _sortMode == _SortMode.name,
          onTap: () => _toggleSort(_SortMode.name),
        ),
        if (_sortAsc)
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: Icon(
              Lucide.ArrowUp,
              size: 14,
              color: cs.onSurface.withValues(alpha: 0.5),
            ),
          ),
      ],
    );

    final content = _loading
        ? const Center(child: CircularProgressIndicator())
        : _entries.isEmpty
        ? Center(
            child: Text(
              l10n.workspaceFilesEmpty,
              style: TextStyle(color: cs.onSurface.withValues(alpha: 0.6)),
            ),
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: sortBar,
              ),
              Expanded(
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  itemCount: _sorted.length,
                  separatorBuilder: (_, __) => Divider(
                    height: 1,
                    color: cs.onSurface.withValues(alpha: 0.06),
                  ),
                  itemBuilder: (context, i) {
                    final e = _sorted[i];
                    return _FileRow(
                      entry: e,
                      onDelete: () => _confirmDelete(e),
                    );
                  },
                ),
              ),
            ],
          );

    return Scaffold(
      appBar: AppBar(
        leading: IosIconButton(
          icon: Lucide.ArrowLeft,
          color: cs.onSurface,
          size: 22,
          onTap: () => Navigator.of(context).maybePop(),
        ),
        title: Text(l10n.workspaceFilesPageTitle),
      ),
      body: content,
    );
  }
}

class _SortChip extends StatelessWidget {
  const _SortChip({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: active
              ? cs.primary.withValues(alpha: 0.14)
              : cs.onSurface.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: active
                ? AppFontWeights.semibold
                : AppFontWeights.regular,
            color: active ? cs.primary : cs.onSurface.withValues(alpha: 0.8),
          ),
        ),
      ),
    );
  }
}

class _FileRow extends StatelessWidget {
  const _FileRow({required this.entry, required this.onDelete});

  final WorkspaceFileEntry entry;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(
            Lucide.FileText,
            size: 18,
            color: cs.onSurface.withValues(alpha: 0.55),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.wirePath,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontFamily: 'monospace',
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 3),
                Text(
                  '${formatBytes(entry.size)} · ${_formatTime(entry.modifiedAt, l10n)}',
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurface.withValues(alpha: 0.55),
                  ),
                ),
              ],
            ),
          ),
          IosIconButton(
            icon: Lucide.Trash2,
            size: 17,
            color: cs.error.withValues(alpha: 0.85),
            minSize: 36,
            semanticLabel: l10n.workspaceFilesDeleteButton,
            onTap: onDelete,
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime t, AppLocalizations l10n) {
    final local = t.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}
