# ADR-0004: Subsequence Matching for "Copy as Markdown"

**Status:** Accepted (2026-07-26)

## Context

Users selecting rendered text in assistant messages get plain text on the
clipboard. The raw markdown source contains syntax characters (`**`, `##`, `- `,
`[text](url)`, fences) that are invisible in the rendered output. We want a
"Copy as Markdown" context menu item that returns the corresponding source
fragment, and a "Quote" button that inserts selected text into the chat input
as a blockquote.

Two algorithms were considered for the reverse-mapping from rendered plain text
back to markdown source:

1. **Stripped projection** — enumerate markdown syntax patterns, strip them to
   produce a "simulated plain text," do substring search, reverse-map via a
   position table. Fragile: must exhaustively handle `##`, `**`, `- `, `> `,
   fences, links, images, HTML entities, tables. Missing one pattern causes
   offset drift and wrong results.

2. **Subsequence matching** — treat the selected plain text as a subsequence of
   the raw source. Syntax characters are naturally skipped (they don't appear in
   rendered text). Score matches by span length; return the tightest. No pattern
   enumeration required.

## Decision

Use subsequence matching (option 2).

- Simpler implementation, fewer assumptions about markdown syntax.
- Tolerant of visual-only regex transforms (skipped chars widen span slightly
  but don't break the match).
- Bundled with "Quote" in the same PR due to shared `SelectionArea`
  infrastructure (`onSelectionChanged`, `contextMenuBuilder`,
  `_selectedPlainText`).

## Rationale

- The existing `SelectionArea` at `chat_message_widget.dart:1909` already wraps
  assistant content. Adding `onSelectionChanged` and `contextMenuBuilder` is
  purely additive — no breaking change.
- Workflow: user selects rendered text → long-press/right-click → context menu
  has "Copy as Markdown" and/or "Quote". No new gesture handlers or UI surfaces.
- Visible text is sourced from `visualContent` (after `<think>` removal and
  visual regex transforms), which is the same string the renderer consumes. The
  subsequence match is built against this string for 100% alignment.

## Consequences

- The algorithm is a pure function in
  `lib/utils/markdown_subsequence_match.dart`, trivially unit-testable.
- If ambiguity becomes a user-facing problem (repeated text → wrong match),
  upgrade path is to use `TextSelection.baseOffset` as a proximity hint.
- Silent fallback to plain text on match failure — never worse than status quo.

## Known Limitations (v1)

1. Repeated text → first tightest match (may be wrong occurrence).
2. Orphaned inline delimiters at selection boundaries.
3. Multi-line prefix inconsistency (`> ` on intermediate lines).
4. Table pipes included in source range.
5. Reasoning section selections → silent fallback (match runs against
   `visualContent`, which excludes thinking text).
