---
timestamp: 2026-09-21T000000Z
type: fix
pages: [modules/bot, testing]
tags: [bot, brainstorm, parser, architecture]
---

# Centralize brainstorm document location in the parser

**Action:** The architecture patrol finding
`scheduled-…:centralize-brainstorm-document-location` flagged that
`Hive::BrainstormParser` returned only logical question data while
`BrainstormAnswerWriter` reconstructed physical identity from raw lines:
`target_question_line_index` re-scanned raw lines to map the parser's
"first unanswered Q{n}" back to a line index,
`question_line_index_for_ordinal` re-scanned for the ordinal-position Q
header, and `block_boundary?` re-derived the Q/Round/marker boundary rule
the parser also encodes. Three parallel location rules made every future
format change a synchronized cross-boundary edit, and the raw-line re-scan
indexed a different line array than the parser used (a lone-`\r` file
yields more parser lines than `content.lines`).

Fixed by making the parser the single source of truth for document
location (`lib/hive/brainstorm_parser.rb`,
`lib/hive/bot/brainstorm_answer_writer.rb`):

1. `Question` now carries `question_line_index`, `block_end_index` (first
   Q/Round/marker boundary at-or-after the Q header, or EOF), and
   `answer_line_index`, all indexed against `document_lines(text)` — the
   parser's newline-normalized line array, newly exposed as a public
   helper.
2. `find_empty_answer_slot` takes the parser-identified unanswered target
   and returns the empty-slot envelope from `answer_line_index` /
   `block_end_index`; slot creation inserts at `block_end_index`. The
   writer-side re-scan helpers and `block_boundary?` are gone.
3. Writer line surgery operates on the parser's `document_lines` array
   (re-terminated with `\n`), so parser indices and raw lines can never
   disagree; the written document keeps the pre-write line-ending style
   (CRLF stays CRLF, decided once by `join_document` instead of
   per-inserted-line `newline_for`).

Behavioral consequences: lone-`\r` documents now land answers through
`append!` instead of dead-ending in `:answer_slot_missing` (the parser and
the writer finally share one line array), while the lone-`\r` exact-writer
path keeps working; EOF-final questions keep their terminator. The
Q-context anchoring that fixed the earlier cross-round slot leak is now
structural rather than scan-based.

**Tests:** focused suites `test/unit/bot/brainstorm_parser_test.rb`,
`test/unit/bot/brainstorm_answer_writer_test.rb`,
`test/integration/bot/brainstorm_round_trip_test.rb`,
`test/eval/scenarios/s6_brainstorm_round_trip_test.rb`,
`test/eval/scenarios/s2_agent_question_test.rb`,
`test/integration/bot/scenarios/s1_brainstorm_test.rb`,
`test/integration/brainstorm_answering_skill_contract_test.rb`,
`test/unit/commands/answer_test.rb`, plus
`brainstorm_runtime`/`brainstorm_artifact`/`tui/brainstorm_answers`/
`auto_retry_safety`/`answer_digest`/`bot/supervisor` — all green.
Added parser location-field tests (`test_exposes_document_location_fields`,
`test_block_end_index_points_at_eof_for_a_trailing_question`), a
writer-anchoring regression test, and full-file CRLF and lone-CR
append-round-trip coverage. The obsolete
`target_question_line_index`/`question_line_index_for_ordinal` test hooks
were replaced.

**Pages:** updated [[modules/bot]] (`BrainstormParser` location-source row,
`BrainstormAnswerWriter` anchoring row).
