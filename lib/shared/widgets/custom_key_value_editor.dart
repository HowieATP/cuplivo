import 'package:flutter/material.dart';
import '../../icons/lucide_adapter.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/app_font_weights.dart';
import '../../theme/design_tokens.dart';
import 'ios_tactile.dart';

/// A reusable editor for a list of key-value string pairs.
///
/// Two modes:
/// - [keyMode] = `KeyMode.header` → fields use "name"/"value" labels, single-line value.
/// - [keyMode] = `KeyMode.body`   → fields use "key"/"value" labels, multi-line value.
///
/// Each row is a [StatefulWidget] that manages its own controllers to prevent
/// cursor jump during list rebuilds.
///
/// Currently consumed by:
/// - Provider-level custom request pages (new).
///
/// Future consumers (not yet refactored, see AGENTS.md §3.9):
/// - Model-level headers/body in [model_edit_dialog.dart] and [model_detail_sheet.dart].
/// - Assistant-level custom request in [assistant_settings_edit_custom_request_tab.dart].
enum KeyMode { header, body }

class CustomKeyValueEditor extends StatelessWidget {
  const CustomKeyValueEditor({
    super.key,
    required this.title,
    required this.keyMode,
    required this.entries,
    required this.onAdd,
    required this.onRemove,
    required this.onUpdate,
    this.showCard = true,
  });

  final String title;
  final KeyMode keyMode;
  final List<Map<String, String>> entries;
  final VoidCallback onAdd;
  final void Function(int index) onRemove;
  final void Function(int index, String key, String value) onUpdate;
  final bool showCard;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: AppFontWeights.emphasis,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: _AddButton(
                onTap: onAdd,
                label: keyMode == KeyMode.header
                    ? l10n.assistantEditCustomHeadersAdd
                    : l10n.assistantEditCustomBodyAdd,
                cs: cs,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        for (int i = 0; i < entries.length; i++) ...[
          _KeyValueRow(
            index: i,
            keyMode: keyMode,
            keyName:
                entries[i][keyMode == KeyMode.header ? 'name' : 'key'] ?? '',
            value: entries[i]['value'] ?? '',
            onChanged: (k, v) => onUpdate(i, k, v),
            onDelete: () => onRemove(i),
          ),
          const SizedBox(height: 10),
        ],
        if (entries.isEmpty)
          Text(
            keyMode == KeyMode.header
                ? l10n.assistantEditCustomHeadersEmpty
                : l10n.assistantEditCustomBodyEmpty,
            style: TextStyle(
              color: cs.onSurface.withValues(alpha: 0.6),
              fontSize: 12,
            ),
          ),
      ],
    );

    if (showCard) {
      return Container(
        decoration: BoxDecoration(
          color: isDark ? Colors.white10 : cs.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.25)),
          boxShadow: isDark ? [] : AppShadows.soft,
        ),
        child: Padding(padding: const EdgeInsets.all(12), child: body),
      );
    }
    return body;
  }
}

class _AddButton extends StatelessWidget {
  const _AddButton({
    required this.onTap,
    required this.label,
    required this.cs,
  });

  final VoidCallback onTap;
  final String label;
  final ColorScheme cs;

  @override
  Widget build(BuildContext context) {
    return IosCardPress(
      onTap: onTap,
      pressedScale: 0.97,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Lucide.Plus, size: 16, color: cs.primary),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: cs.primary,
              fontWeight: AppFontWeights.semibold,
            ),
          ),
        ],
      ),
    );
  }
}

class _KeyValueRow extends StatefulWidget {
  const _KeyValueRow({
    required this.index,
    required this.keyMode,
    required this.keyName,
    required this.value,
    required this.onChanged,
    required this.onDelete,
  });

  final int index;
  final KeyMode keyMode;
  final String keyName;
  final String value;
  final void Function(String key, String value) onChanged;
  final VoidCallback onDelete;

  @override
  State<_KeyValueRow> createState() => _KeyValueRowState();
}

class _KeyValueRowState extends State<_KeyValueRow> {
  late final TextEditingController _keyCtrl;
  late final TextEditingController _valCtrl;
  late final FocusNode _keyFocus;
  late final FocusNode _valFocus;

  @override
  void initState() {
    super.initState();
    _keyCtrl = TextEditingController(text: widget.keyName);
    _valCtrl = TextEditingController(text: widget.value);
    _keyFocus = FocusNode();
    _valFocus = FocusNode();
  }

  @override
  void didUpdateWidget(covariant _KeyValueRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.keyName != widget.keyName && !_keyFocus.hasFocus) {
      _keyCtrl.text = widget.keyName;
    }
    if (oldWidget.value != widget.value && !_valFocus.hasFocus) {
      _valCtrl.text = widget.value;
    }
  }

  @override
  void dispose() {
    _keyCtrl.dispose();
    _valCtrl.dispose();
    _keyFocus.dispose();
    _valFocus.dispose();
    super.dispose();
  }

  InputDecoration _dec(BuildContext context, String label) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return InputDecoration(
      labelText: label,
      filled: true,
      fillColor: isDark ? Colors.white10 : const Color(0xFFF2F3F5),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Colors.transparent),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: cs.primary.withValues(alpha: 0.4)),
      ),
      alignLabelWithHint: widget.keyMode == KeyMode.body,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final label = widget.keyMode == KeyMode.header
        ? l10n.assistantEditHeaderNameLabel
        : l10n.assistantEditBodyKeyLabel;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _keyCtrl,
                focusNode: _keyFocus,
                decoration: _dec(context, label),
                onChanged: (v) => widget.onChanged(v, _valCtrl.text),
              ),
            ),
            const SizedBox(width: 8),
            IosIconButton(
              icon: Lucide.Trash2,
              color: cs.error,
              size: 20,
              onTap: widget.onDelete,
            ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _valCtrl,
          focusNode: _valFocus,
          minLines: widget.keyMode == KeyMode.body ? 3 : 1,
          maxLines: widget.keyMode == KeyMode.body ? 6 : 1,
          decoration: _dec(
            context,
            widget.keyMode == KeyMode.header
                ? l10n.assistantEditHeaderValueLabel
                : l10n.assistantEditBodyValueLabel,
          ),
          onChanged: (v) => widget.onChanged(_keyCtrl.text, v),
        ),
      ],
    );
  }
}
