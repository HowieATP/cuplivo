import 'package:flutter/material.dart';

import '../../theme/app_font_weights.dart';
import 'ios_switch.dart';
import 'ios_tactile.dart';

/// A toggle row for tool-like list entries: icon + title (+ optional subtitle)
/// + [IosSwitch]. Shared by the skills sheet and the Tools Hub.
class ToolToggleRow extends StatelessWidget {
  const ToolToggleRow({
    super.key,
    required this.icon,
    required this.title,
    required this.enabled,
    required this.onChanged,
    this.subtitle,
    this.iconColor,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final bool enabled;
  final ValueChanged<bool> onChanged;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final resolvedIconColor =
        iconColor ??
        (enabled ? cs.primary : cs.onSurface.withValues(alpha: 0.7));
    return IosCardPress(
      borderRadius: BorderRadius.circular(14),
      baseColor: cs.surface,
      duration: const Duration(milliseconds: 260),
      onTap: () => onChanged(!enabled),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 18, color: resolvedIconColor),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: AppFontWeights.medium,
                    color: cs.onSurface,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: cs.onSurface.withValues(alpha: 0.55),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          IosSwitch(value: enabled, onChanged: onChanged),
        ],
      ),
    );
  }
}
