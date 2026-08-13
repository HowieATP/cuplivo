# ADR-0030: Math formula export is display-only, copies raw TeX, and reuses the table PNG capture pipeline

Long-press (mobile) / right-click (desktop) on a rendered display formula opens a 3-item menu — copy LaTeX, copy PNG, download PNG — instead of the surrounding message's context menu.

## Context

`MarkdownWithCodeHighlight` renders display math (`$$…$$` / `\[…\]`) via `LatexBlockScrollableMd`, which normalizes the TeX (`_normalizeMathTex`) before handing it to `Math.tex` (flutter_math_fork). The rendered formula lives *inside* the assistant message's `SelectionArea` (which owns its own context menu) and inside the user bubble's `GestureDetector`. There was previously no way to copy a formula's source or image.

## Decisions

1. **Display math only.** Inline math (`$…$`, `\(…\)`) gets no gesture in v1. Inline math is a `WidgetSpan` inside rich text: baseline-anchored, horizontally scrollable, and a per-span `RepaintBoundary` capture is unreliable (glyph bleed) while span hit-testing collides with the parent text's selection/gesture handling. Display math is a standalone block widget — near-zero-risk to wrap in a gesture + boundary. Inline can be added later without touching the vendored `gpt_markdown` dependency.

2. **复制 LaTeX copies the raw body, not the normalized render input.** `_normalizeMathTex` rewrites `\tag{X}` → `\qquad\text{(X)}` and strips `\notag` (ADR-0023) so the *rendering* doesn't throw. Copying that string would hand the user an approximated/corrupted TeX. The clipboard gets the trimmed content between the delimiters, with no delimiters — what pastes cleanly into Overleaf/KaTeX. Fidelity over WYSIWYG.

3. **PNG capture reuses the table block's pipeline.** The markdown table block already had the correct primitive: `RepaintBoundary.toImage(pixelRatio: 3.0)` → `rawStraightRgba` readback → `image_lib.encodePng` (8-bit — `ImageByteFormat.png` embeds wide-gamut bytes on iOS Impeller that downstream consumers misinterpret). This is extracted into a shared `_captureRepaintBoundaryPng` / `_copyPngToClipboard` / `_savePngFile` so table and math use one implementation. Copy-PNG uses super_clipboard `SystemClipboard` with a `ClipboardImages.setImagePath` desktop fallback; download-PNG uses `FilePicker.saveFile` (desktop) / bytes (mobile).

4. **Theme-matched background.** `Math.tex` paints glyphs on a transparent canvas; a transparent capture leaves dark glyphs invisible on a dark viewer. The formula is wrapped in a `cs.surface` container so the PNG matches what the user sees.

5. **Leaf-wins gesture, with a capture-order caveat.** The formula's `GestureDetector` (`onLongPressStart` mobile / `onSecondaryTapDown` desktop) is the deepest hit target, so it enters the gesture arena before the `SelectionArea`'s and the bubble's recognizers and wins. `onSecondaryTapDown` can fire eagerly on pointer-down, so an ancestor `SelectionArea` right-click handler may co-fire in some Flutter versions; the fallback is a `RawGestureDetector`/`Listener` that resolves `GestureDisposition.accepted` before the `SelectionArea` sees it. This is pinned by a widget test (formula menu opens; the SelectionArea toolbar does not).

6. **Menu always available.** The gesture + boundary wrap whatever `_renderMath` returned, so 复制 LaTeX works on parse-fallback `Text` and during streaming. No `ExportCaptureScope` gating — math has no WebView, so offscreen export captures it normally.

## Considered Options

1. **Reuse the table capture pipeline (chosen).** One shared implementation, no new plugin, no duplicated ~50 lines.
2. **New dedicated capture utility / plugin.** Rejected — the table block already proved the path; a new abstraction is YAGNI.
3. **Include inline math in v1.** Rejected — disproportionate capture + gesture-correctness cost for the value; cleanly deferrable.
4. **Copy normalized TeX.** Rejected — corrupts `\tag`/`\notag` formulas (ADR-0023 approximation would leak into user output).

## Consequences

- A visible `cs.surface` box now sits behind each display formula in chat (nearly invisible — it matches the chat surface). Acceptable; consistent with the table/Mermaid/SVG/HTML preview-block visual language.
- Wide formulas still export in full: the `RepaintBoundary` is inside the horizontal `SingleChildScrollView`, and `toImage` captures the whole layer, not the visible slice.
- The shared helper change is behavior-preserving for the table block (the table methods now delegate to it).
- Future: if inline math export is added, it lands in `markdown_with_highlight.dart` only; the vendored `gpt_markdown` stays untouched.
