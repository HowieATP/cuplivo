import 'package:flutter/material.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/models/message_quote.dart';
import '../../../l10n/app_localizations.dart';
import '../../../utils/quote_plain_text.dart';

/// QQ-style one-line reply citation (issue #312, docs/adr/0042-draft).
///
/// [target] is the resolved quoted message row; null renders the localized
/// stub (deleted / restore-mismatched target). Display extracts via the
/// shared [quotePlainText] core:
/// - id-only: clipped leading text + `…`
/// - ranged: center-window `…pre + highlighted span (never clipped) + post…`;
///   relocation failure degrades to span-only, no highlight.
class QuoteBlock extends StatelessWidget {
  const QuoteBlock({super.key, required this.quote, this.target});

  final MessageQuote quote;
  final ChatMessage? target;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final target = this.target;

    String text;
    int? spanStart;
    int? spanEnd;
    if (target == null) {
      text = l10n.messageQuoteDeletedErrorMessage;
    } else {
      final full = quotePlainText(target.content);
      final start = quote.start;
      final end = quote.end;
      if (start != null && end != null) {
        final s = start < 0 ? 0 : start;
        final e = end > target.content.length ? target.content.length : end;
        if (s >= e) {
          text = quoteClipText(full);
        } else {
          final spanPlain = quotePlainText(target.content.substring(s, e));
          final win = quoteWindowText(fullPlain: full, spanPlain: spanPlain);
          if (win != null) {
            text = win.text;
            spanStart = win.spanStart;
            spanEnd = win.spanEnd;
          } else {
            text = quoteClipText(spanPlain);
          }
        }
      } else {
        text = quoteClipText(full);
      }
    }

    Widget label = Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 12.5,
        height: 1.35,
        color: cs.onSurface.withValues(alpha: 0.7),
      ),
    );
    if (spanStart != null && spanEnd != null && spanStart < spanEnd) {
      final pre = spanStart > 0 ? text.substring(0, spanStart) : '';
      final span = text.substring(spanStart, spanEnd);
      final post = spanEnd < text.length ? text.substring(spanEnd) : '';
      label = Text.rich(
        TextSpan(
          children: [
            TextSpan(text: pre),
            TextSpan(
              text: span,
              style: TextStyle(
                backgroundColor: cs.primary.withValues(alpha: 0.16),
              ),
            ),
            TextSpan(text: post),
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12.5,
          height: 1.35,
          color: cs.onSurface.withValues(alpha: 0.7),
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.only(left: 8),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(
            color: cs.onSurface.withValues(alpha: 0.25),
            width: 2,
          ),
        ),
      ),
      child: Align(alignment: Alignment.centerLeft, child: label),
    );
  }
}
