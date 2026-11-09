---
title: TUI idea preview wraps body text losslessly by cells
type: fix
date: 2026-11-09
---

The read-only idea preview previously sliced body text by character count and
then truncated each slice by display cells, so a grapheme that filled its
character slice but overran the cell budget was silently dropped (a two-cell
grapheme at a one-cell budget vanished). `Views::Format.cell_chunks` now owns
fixed-row, terminal-cell-aware, grapheme-preserving wrapping: it accepts one
logical line, raises `ArgumentError` on embedded CR/LF, keeps ANSI tokens atomic
and zero-width, splits only at grapheme boundaries, and reconstructs the source
line byte-for-byte from its rows. A grapheme wider than the whole row budget is
emitted intact on its own over-budget logical row rather than split or dropped.

`Views::IdeaPreview` consumes those rows without horizontal truncation, so every
supplied grapheme in `original_text` and the stage extra survives in source
order. Only vertical capacity omits body text, and each omission is signalled: an
overflowing block allotted at least two rows ends with a standalone `…` marker,
a one-row allocation keeps today's inline `…` on chrome, a zero-row block adds
none, and zero content capacity replaces the dismiss hint with one global marker.
The composer keeps its character-indexed `character_chunks`; the two surfaces no
longer share one slicer. See [[20260718T235041Z-shared-tui-character-chunks]].

Focused coverage: `test/unit/tui/views/format_test.rb`,
`test/unit/tui/views/idea_preview_test.rb`, and
`test/unit/tui/bubble_model_test.rb` (the two-column frame carries the width-one
and the wide-ZWJ `:none` over-budget body contracts).
