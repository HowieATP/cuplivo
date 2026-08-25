import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/services/backup/data_sync.dart';
import '../../l10n/app_localizations.dart';
import '../animations/widgets.dart';

/// Localized label for a backup [stage] (生成文件 / 整合压缩 / 上传).
String backupStageLabel(AppLocalizations l10n, BackupStage stage) =>
    switch (stage) {
      BackupStage.generating => l10n.backupStageGenerating,
      BackupStage.packing => l10n.backupStagePacking,
      BackupStage.uploading => l10n.backupStageUploading,
    };

/// Runs [task] behind a modal, un-dismissible [LoadingDialogCard] overlay and
/// pops it when the task completes or throws.
///
/// [labelListenable], when non-null, replaces the static [label] with a live
/// value (e.g. a backup stage that changes mid-flight). [elapsedTextBuilder],
/// when non-null, shows a "已耗时 Xs" line that ticks every second.
Future<T> runWithLoadingDialog<T>(
  BuildContext context,
  Future<T> Function() task, {
  String? label,
  String Function(int seconds)? elapsedTextBuilder,
  ValueListenable<String>? labelListenable,
}) async {
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => LoadingDialogCard(
      label: label,
      elapsedTextBuilder: elapsedTextBuilder,
      labelListenable: labelListenable,
    ),
  );
  try {
    return await task();
  } finally {
    if (context.mounted) {
      Navigator.of(context, rootNavigator: true).pop();
    }
  }
}

class LoadingDialogCard extends StatefulWidget {
  const LoadingDialogCard({
    super.key,
    this.label,
    this.elapsedTextBuilder,
    this.labelListenable,
  });

  final String? label;

  /// When non-null, the card shows a live "elapsed seconds" line that ticks
  /// every second. Null keeps the card static (no timer).
  final String Function(int seconds)? elapsedTextBuilder;

  /// When non-null, the rendered label follows this notifier (wins over
  /// [label]).
  final ValueListenable<String>? labelListenable;

  @override
  State<LoadingDialogCard> createState() => _LoadingDialogCardState();
}

class _LoadingDialogCardState extends State<LoadingDialogCard> {
  Timer? _timer;
  int _seconds = 0;

  @override
  void initState() {
    super.initState();
    if (widget.elapsedTextBuilder != null) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _seconds++);
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final labelListenable = widget.labelListenable;
    final label = labelListenable?.value ?? widget.label;
    final hasLabel = label != null && label.trim().isNotEmpty;

    return Center(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0.96, end: 1),
        duration: kAnimSlow,
        curve: Curves.easeOutCubic,
        builder: (context, value, child) {
          final opacity = ((value - 0.96) / 0.04).clamp(0.0, 1.0).toDouble();
          return Opacity(
            opacity: opacity,
            child: Transform.scale(scale: value, child: child),
          );
        },
        child: Material(
          color: Colors.transparent,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 96, maxWidth: 240),
            child: Container(
              decoration: BoxDecoration(
                color: cs.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: cs.outlineVariant.withValues(alpha: 0.2),
                ),
              ),
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  20,
                  hasLabel ? 16 : 18,
                  20,
                  hasLabel ? 16 : 18,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CupertinoActivityIndicator(radius: 16),
                    if (labelListenable != null && hasLabel) ...[
                      const SizedBox(height: 12),
                      ValueListenableBuilder<String>(
                        valueListenable: labelListenable,
                        builder: (context, value, _) => Text(
                          value,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 14,
                            color: cs.onSurface.withValues(alpha: 0.8),
                          ),
                        ),
                      ),
                    ] else if (hasLabel) ...[
                      const SizedBox(height: 12),
                      Text(
                        label,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 14,
                          color: cs.onSurface.withValues(alpha: 0.8),
                        ),
                      ),
                    ],
                    if (widget.elapsedTextBuilder != null) ...[
                      SizedBox(height: hasLabel ? 4 : 12),
                      Text(
                        widget.elapsedTextBuilder!(_seconds),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurface.withValues(alpha: 0.5),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
