import 'package:flutter/material.dart';

import '../../icons/lucide_adapter.dart';
import '../../theme/app_font_weights.dart';

/// Reusable collapsible group header with tap-to-expand/collapse and an
/// animated chevron. Used by grouped lists (e.g. skills by category).
class CollapsibleGroupHeader extends StatelessWidget {
  const CollapsibleGroupHeader({
    super.key,
    required this.groupName,
    required this.skillCount,
    required this.expanded,
    required this.onTap,
    this.fontSize = 12,
    this.fontWeight,
    this.padding = const EdgeInsets.fromLTRB(4, 12, 4, 6),
    this.trailing,
  });

  final String groupName;
  final int skillCount;
  final bool expanded;
  final VoidCallback onTap;
  final double fontSize;
  final FontWeight? fontWeight;
  final EdgeInsetsGeometry padding;

  /// Optional widget pinned to the right end of the header row (e.g. a
  /// per-group manage action).
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: padding,
        child: Row(
          children: [
            AnimatedRotation(
              turns: expanded ? 0.25 : 0.0,
              duration: const Duration(milliseconds: 200),
              child: Icon(
                Lucide.ChevronRight,
                size: 14,
                color: cs.onSurface.withValues(alpha: 0.55),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              groupName,
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: fontWeight ?? AppFontWeights.semibold,
                color: cs.onSurface.withValues(alpha: 0.55),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '($skillCount)',
              style: TextStyle(
                fontSize: 11,
                color: cs.onSurface.withValues(alpha: 0.38),
              ),
            ),
            const Spacer(),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }
}

/// Animated body for a collapsible group: folds/unfolds with a
/// [SizeTransition] height animation. Unlike `AnimatedSize`, the child is
/// never re-laid-out per animation frame — only painted/clipped — so the
/// collapse stays smooth regardless of content length.
class CollapsibleGroupBody extends StatefulWidget {
  const CollapsibleGroupBody({
    super.key,
    required this.expanded,
    required this.child,
  });

  final bool expanded;
  final Widget child;

  @override
  State<CollapsibleGroupBody> createState() => _CollapsibleGroupBodyState();
}

class _CollapsibleGroupBodyState extends State<CollapsibleGroupBody>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
    value: widget.expanded ? 1.0 : 0.0,
  );
  late final Animation<double> _curve = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeInOutCubic,
  );

  @override
  void didUpdateWidget(CollapsibleGroupBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.expanded == oldWidget.expanded) return;
    if (widget.expanded) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizeTransition(
      sizeFactor: _curve,
      alignment: Alignment.topCenter,
      child: widget.child,
    );
  }
}

/// Collapsible-group state shared by grouped list pages: tracks which category
/// groups are collapsed and toggles them via [State.setState]. All groups
/// start expanded by default unless [initialCollapsedGroups] is overridden.
mixin CollapsibleGroupsMixin<T extends StatefulWidget> on State<T> {
  final Set<String> _collapsedGroups = {};

  /// Group keys (see [toggleGroup]) that start collapsed. Override to set the
  /// default expansion state per page.
  Set<String> get initialCollapsedGroups => const {};

  @override
  void initState() {
    super.initState();
    _collapsedGroups.addAll(initialCollapsedGroups);
  }

  /// A stable key for a group, used to track collapsed state.
  String _groupKey(String? group) => group ?? '__uncategorized__';

  void toggleGroup(String? group) {
    setState(() {
      final key = _groupKey(group);
      if (_collapsedGroups.contains(key)) {
        _collapsedGroups.remove(key);
      } else {
        _collapsedGroups.add(key);
      }
    });
  }

  bool isGroupExpanded(String? group) =>
      !_collapsedGroups.contains(_groupKey(group));
}
