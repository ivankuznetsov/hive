# Unmapped escape sequences no longer decode as ESC + literal bytes

**Problem:** A patrol finding traced `InputDecoder.drain("\e[1;5D".b)`
(Ctrl+Left) to `[KEY_ESC, RawTextInput("[1;5D")]`, and
`drain("\eb".b)` (Alt+b) to `[KEY_ESC, KEY_RUNES('b')]`. In `:new_idea`
the leaked ESC mapped to `:cancel_new_idea`, silently discarding the
typed buffer; in `:grid` the leaked `b` rune dispatched `:brainstorm`.
Any complete escape sequence outside the fixed `SEQUENCES` table hit
the same split.

**Cause:** `drain_escape` had no grammar for unknown sequences.
`sequence_match` only resolves exact table entries and
`escape_prefix?` only recognizes prefixes of table entries plus the
paste markers, so a complete unmapped sequence matched neither guard
and fell through to the lone-ESC fallback: consume 1 byte, emit
KEY_ESC, decode the tail as text/runes.

**Fix:** After the table and prefix guards, `drain_escape` now tries
three generic grammars and swallows well-formed matches atomically:

- ECMA-48 CSI (`ESC [` + parameter 0x30–0x3F, intermediate 0x20–0x2F,
  final 0x40–0x7E), e.g. `\e[1;5D`;
- SS3 (`ESC O` + final byte), e.g. `\eOP` for F1;
- Alt-chords (`ESC` + one printable byte, excluding `[` / `O`
  leaders and control bytes).

Partial sequences that could still complete hold the buffer open
(`INCOMPLETE_SEQUENCE`) instead of emitting a premature KEY_ESC; the
lone-ESC fallback plus ESC+CR/LF cancel-gesture absorption is
unchanged for control-byte continuations.

**Tests:** `test/unit/tui/input_decoder_test.rb` gains atomic-swallow,
split-across-chunks, trailing-input, and ESC+C0 fallback pins
("Fix 12" section).
