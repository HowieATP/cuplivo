import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../animations/widgets.dart';

class LoadingDialogCard extends StatefulWidget {
  const LoadingDialogCard({super.key, this.label, this.elapsedTextBuilder});

  final String? label;

  /// When non-null, the card shows a live "elapsed seconds" line that ticks
  /// every second. Null keeps the card static (no timer).
  final String Function(int seconds)? elapsedTextBuilder;

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
    final label = widget.label;
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
                    if (hasLabel) ...[
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
