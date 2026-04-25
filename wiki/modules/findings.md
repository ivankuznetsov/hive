---
title: Hive::Findings
type: module
source: lib/hive/findings.rb
created: 2026-04-25
updated: 2026-04-25
tags: [module, findings, parser]
---

**TLDR**: Parser + writer for the GFM-checkbox finding files written by the execute-stage reviewer at `<task>/reviews/ce-review-NN.md`. `Hive::Findings::Document` reads the file, exposes a list of `Finding` value objects with stable 1-based IDs in document order, and supports a single-checkbox `toggle!` that round-trips byte-for-byte (including `\r\n` line endings and missing trailing newlines). Atomic write via tempfile + `File.rename`.

## Public surface

- `Hive::Findings::Document.new(path)` — load + parse. Raises `Hive::NoReviewFile` if the path doesn't exist.
- `#findings` — array of `Finding(id, severity, accepted, title, justification, line_index)` records.
- `#summary` — `{ "total", "accepted", "by_severity" }`.
- `#toggle!(id, accepted:)` — flip a checkbox. Idempotent on a no-op (returns nil); raises `Hive::UnknownFinding` for unknown IDs. Preserves the original line ending and surrounding bytes.
- `#write!` — atomic tempfile + rename.
- `Hive::Findings.review_path_for(task, pass: nil)` — module function. Returns the absolute path to the latest (or named-pass) review file, or raises `Hive::NoReviewFile`.
- `Hive::Findings.pass_from_path(path)` — extract integer pass from a `ce-review-NN.md` filename (or nil).

## Parsing rules

- **Severity heading**: any `## …` heading. The first whitespace-separated word is lowercased; if it matches the `KNOWN_SEVERITIES` allow-list (`high`, `medium`, `low`, `nit`), `current_severity` is set to it. Otherwise `current_severity` is **cleared to nil**, so multi-word headings like `## Detailed Analysis` and meta-headings like `## Notes` don't leak the previous section's severity into subsequent findings.
- **Finding line**: matches `\A(\s*-\s+)\[([ xX])\]\s+(.*?)([\r\n]*)\z`. The four capture groups are the leading prefix, checkbox state, body, and trailing line ending — kept separately so `toggle!` can rebuild the line without flattening CRLF or adding an extra newline to the last line.
- **Title vs justification**: split on the first `: ` (colon + space). Titles can therefore contain colons (e.g. `lib/foo.rb:12`) without being misparsed.
- **IDs**: 1-based, in document order. Stable as long as findings aren't reordered or removed (the reviewer prompt writes append-only, so this holds in normal use).

## Round-trip guarantees

`toggle!` followed by `write!` preserves every byte of the file except the single checkbox character on the target line. Pinned by:

- `test/unit/findings_test.rb#test_toggle_preserves_surrounding_lines_byte_for_byte` — LF input.
- `test/unit/findings_test.rb#test_toggle_preserves_crlf_line_endings` — `\r\n` line endings stay `\r\n`.
- `test/unit/findings_test.rb#test_toggle_preserves_missing_trailing_newline` — last line without a final `\n` stays without one.

## Consumers

| File | Use |
|------|-----|
| `lib/hive/commands/findings.rb` | Reads the file via `Document.new`; emits the parsed list as text or JSON. |
| `lib/hive/commands/finding_toggle.rb` | Reads, toggles selected IDs, atomic write, slug-scoped commit. |
| `lib/hive/stages/execute.rb` | `collect_accepted_findings` greps the latest review file for `[x]` lines and re-injects them into the next implementation pass's prompt. (This consumer pre-dates the `Hive::Findings` module and uses raw string matching; it could migrate to `Document` in a future refactor.) |

## Backlinks

- [[commands/findings]] · [[stages/execute]]
- [[modules/lock]] — task lock the toggle commands hold during read + write
- [[modules/markers]] — sibling tempfile + rename atomic-write pattern
