import 'package:flutter/material.dart';

import '../../theme/app_font_weights.dart';

/// An [ExpansionTile] with a [Wrap] of selectable chips.
///
/// Mirrors the log-max-size pattern in [log_viewer_page.dart]. Use wherever a
/// discrete setting with a short list of options needs an expandable tile UI.
class ExpansionSettingTile extends StatelessWidget {
  const ExpansionSettingTile({
    super.key,
    required this.tileBg,
    required this.border,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.options,
    required this.selectedIndex,
    required this.onSelected,
  });

  final Color tileBg;
  final Color border;
  final String title;
  final String subtitle;
  final String value;
  final List<String> options;
  final int selectedIndex;
  final void Function(int index) onSelected;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: border),
      ),
      child: Material(
        color: tileBg,
        borderRadius: BorderRadius.circular(14),
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: 14),
            childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
            title: Text(
              title,
              style: TextStyle(
                fontWeight: AppFontWeights.semibold,
                color: cs.onSurface.withValues(alpha: 0.92),
                fontSize: 14,
              ),
            ),
            subtitle: Text(
              subtitle,
              style: TextStyle(
                fontSize: 12,
                color: cs.onSurface.withValues(alpha: 0.55),
              ),
            ),
            trailing: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: cs.primary.withValues(alpha: isDark ? 0.18 : 0.10),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                value,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: AppFontWeights.emphasis,
                  color: cs.primary,
                ),
              ),
            ),
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: List.generate(options.length, (i) {
                  final bool selected = i == selectedIndex;
                  return GestureDetector(
                    onTap: () => onSelected(i),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: selected
                            ? cs.primary.withValues(alpha: isDark ? 0.22 : 0.14)
                            : cs.onSurface.withValues(
                                alpha: isDark ? 0.08 : 0.05,
                              ),
                        borderRadius: BorderRadius.circular(10),
                        border: selected
                            ? Border.all(
                                color: cs.primary.withValues(alpha: 0.5),
                              )
                            : null,
                      ),
                      child: Text(
                        options[i],
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: selected
                              ? AppFontWeights.emphasis
                              : AppFontWeights.medium,
                          color: selected
                              ? cs.primary
                              : cs.onSurface.withValues(alpha: 0.72),
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
