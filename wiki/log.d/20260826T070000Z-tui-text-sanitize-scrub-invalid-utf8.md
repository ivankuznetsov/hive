---
title: Scrub invalid UTF-8 before TUI text sanitisation
type: fix
date: 2026-08-26
tags: [tui, text, encoding, patrol-fix]
---

`Hive::Tui::Text.sanitize` gsub'd the ANSI CSI and control-char patterns
without first validating encoding. Ruby regexp matching validates the
receiver's encoding, so any subprocess-derived string (captured stderr,
exception messages) tagged UTF-8 while carrying invalid bytes raised
`ArgumentError: invalid byte sequence in UTF-8` before sanitisation could
happen — turning a display-safety guard into a crash path for exactly the
inputs it exists to protect.

`sanitize` now calls `String#scrub` first: invalid sequences become the
replacement character, then CSI/control bytes are stripped/replaced as
before. The method stays idempotent and keeps its nil/non-string → `""`
contract. Unit regression coverage in `test/unit/tui/text_test.rb` pins
the invalid-UTF-8 input alongside the existing guarantees.
